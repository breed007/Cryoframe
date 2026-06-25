//
//  AppModel.swift
//  Cryoframe (app)
//
//  Central state for the GUI: jobs (persisted), targets, system services, and
//  the live run/verification status. Runs jobs through the same JobRunner the
//  scheduled agent uses.
//

import Foundation
import SwiftUI
import AppKit
import CryoframeKit

@MainActor
final class AppModel: ObservableObject {
    let helper = HelperManager()
    let schedule = ScheduleManager()
    private let detector = WorkspaceProcessDetector()

    /// built-ins with any user path overrides applied (read fresh so the New Job
    /// sheet reflects changes made in Settings).
    var registry: ContentTypeRegistry { ContentTypeRegistry.withOverrides(LibraryOverrides.load()) }
    private let store = JobStore.standard()
    private let history = RunHistoryStore.standard()

    @Published var jobs: [BackupJob] = []
    @Published var targets: [Target] = []
    @Published var activity: [String] = []
    @Published var lastRecords: [String: RunRecord] = [:]   // latest run per job (persisted)
    @Published var runningJobIDs: Set<String> = []      // jobs currently executing
    @Published var pausedJobIDs: Set<String> = []       // running jobs whose tool is suspended
    @Published var jobStage: [String: BackupStage] = [:]
    @Published var jobLibrary: [String: String] = [:]   // job id -> library being archived
    @Published var jobProgress: [String: RunProgress] = [:]
    @Published var fullDiskAccess = false
    @Published var libraryValid: [String: Bool] = [:]   // built-in id  -> resolved path exists
    @Published var jobValid: [String: Bool] = [:]       // job id       -> all libraries resolve

    private var queue: [String] = []                    // job ids waiting for a run slot
    private var controls: [String: RunControl] = [:]
    private let sleepGuard = SleepGuard()
    private var notifiedIDs = Set<String>()             // run records already notified this session
    private var historyWatcher: DirWatcher?
    private var maxConcurrent: Int {
        let n = UserDefaults.standard.integer(forKey: Prefs.maxConcurrent)
        return n > 0 ? n : 2
    }

    init() {
        let pref = UserDefaults.standard.string(forKey: Prefs.archiveDir)
        let dir = (pref.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) })
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Cryoframe Archives", isDirectory: true)
        targets = [.localVolume(id: "local-default", name: dir.lastPathComponent, dir: dir)]
        jobs = store.load().jobs
        reloadHistory()                         // last-run badges, persisted across launches
        for r in history.all().prefix(8).reversed() { log(Self.historyLine(r)) }   // seed the activity log
        notifiedIDs = Set(history.all().map(\.id))   // don't notify for runs that predate this launch
        Notifier.requestAuthorization()
        startHistoryWatch()                     // catch scheduled runs while resident in the menu bar
        refreshDiskAccess()
        revalidate()
        Task { await helper.reloadIfStale() }   // pick up a new helper binary after an app update
        resumeTransfers()
        armWake()                               // align the optional pmset wake with the schedule
    }

    /// rebuild the per-job latest-run map from the durable history (also picks up
    /// runs the scheduled agent recorded while the GUI was closed).
    func reloadHistory() {
        var latest: [String: RunRecord] = [:]
        for r in history.all() where latest[r.jobID] == nil { latest[r.jobID] = r }   // newest-first → first wins
        lastRecords = latest
    }

    /// recent runs across all jobs, newest first, for the History view.
    func runHistory() -> [RunRecord] { history.all() }

    /// watch the data directory so a scheduled run the agent records shows up (and
    /// notifies) while the GUI is resident in the menu bar.
    private func startHistoryWatch() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.cryoframe", isDirectory: true)
        historyWatcher = DirWatcher(url: dir) { [weak self] in self?.historyChanged() }
    }

    private func historyChanged() {
        reloadHistory()
        for r in history.all() { maybeNotify(r) }
    }

    /// post a notification for a record once per session (policy is applied inside).
    private func maybeNotify(_ record: RunRecord) {
        guard !notifiedIDs.contains(record.id) else { return }
        notifiedIDs.insert(record.id)
        Notifier.notify(record)
    }

    /// the menu-bar glyph reflecting overall backup health.
    var menuBarSymbol: String {
        if !runningJobIDs.isEmpty { return "arrow.triangle.2.circlepath" }
        if jobs.contains(where: { lastRecords[$0.id]?.outcome == .failed }) { return "exclamationmark.triangle.fill" }
        return "checkmark.circle"
    }

    func refreshDiskAccess() { fullDiskAccess = DiskAccess.hasFullDiskAccess() }

    /// re-check that built-in and job library paths resolve. Needs Full Disk
    /// Access to see protected libraries; without it, validity is left unknown.
    func revalidate() {
        guard fullDiskAccess else { libraryValid = [:]; jobValid = [:]; return }
        let reg = registry
        let locator = ContentLocator()
        libraryValid = Dictionary(uniqueKeysWithValues:
            reg.types.map { ($0.id, !locator.liveRoots(of: $0).isEmpty) })
        jobValid = Dictionary(uniqueKeysWithValues:
            jobs.map { job in
                (job.id, job.resolvingLibraries(in: reg).libraries.allSatisfy { !locator.liveRoots(of: $0).isEmpty })
            })
    }

    /// whether any of a job's libraries is a built-in (so a broken path is fixable in Settings).
    func isBuiltInLibrary(_ job: BackupJob) -> Bool {
        let reg = registry
        return job.libraries.contains { reg.type(id: $0.id) != nil }
    }

    /// open Settings straight to the Libraries tab.
    func openLibrarySettings() {
        UserDefaults.standard.set("Libraries", forKey: "settings.selectedTab")
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    /// resume any transfer interrupted by a disconnect, once its target is back.
    func resumeTransfers() {
        guard runningJobIDs.isEmpty else { return }
        Task.detached {
            let resumed = TransferResumer.resumeAll(store: PendingTransferStore.standard())
            if !resumed.isEmpty {
                await MainActor.run { self.activity.insert("resumed \(resumed.count) interrupted transfer(s)", at: 0) }
            }
        }
    }

    // MARK: jobs / targets

    func addJob(_ job: BackupJob) { store.upsert(job); jobs = store.load().jobs; revalidate(); armWake() }
    func deleteJob(_ id: String) { stopJob(id); KeychainArchiveKey.delete(jobID: id); store.remove(id: id); jobs = store.load().jobs; lastRecords[id] = nil; revalidate(); armWake() }
    func addTarget(_ target: Target) { targets.removeAll { $0.id == target.id }; targets.append(target) }

    func setEnabled(_ job: BackupJob, _ enabled: Bool) {
        var j = job; j.enabled = enabled; store.upsert(j); jobs = store.load().jobs; armWake()
    }

    func owningAppRunning(_ type: ContentType) -> Bool { type.owningProcessRunning(detector) }
    func openOwners(_ job: BackupJob) -> [String] {
        job.libraries.compactMap(\.owningProcess).filter(detector.isRunning).map(\.displayName)
    }
    func isRunning(_ id: String) -> Bool { runningJobIDs.contains(id) }
    func isQueued(_ id: String) -> Bool { queue.contains(id) }

    func nextDue(_ job: BackupJob) -> Date? {
        let ref = store.load().lastRun[job.id] ?? job.createdAt
        return job.frequency.nextFireDate(after: ref)
    }

    // MARK: running

    func runNow(_ job: BackupJob) {
        guard !runningJobIDs.contains(job.id), !queue.contains(job.id) else { return }
        queue.append(job.id)
        pump()
    }

    func stopJob(_ id: String) {
        queue.removeAll { $0 == id }
        controls[id]?.cancel()
        pausedJobIDs.remove(id)
    }

    func pauseJob(_ id: String) { if controls[id]?.pause() == true { pausedJobIDs.insert(id); refreshSleepGuard() } }
    func resumeJob(_ id: String) { controls[id]?.resume(); pausedJobIDs.remove(id); refreshSleepGuard() }
    func isPaused(_ id: String) -> Bool { pausedJobIDs.contains(id) }

    /// keep the Mac awake while a job is actively running (not while merely paused).
    private func refreshSleepGuard() {
        if runningJobIDs.subtracting(pausedJobIDs).isEmpty { sleepGuard.end() } else { sleepGuard.begin() }
    }

    /// re-point the optional pmset wake at the next due job (no-op unless enabled).
    func armWake() { Task { await WakeScheduler.arm() } }

    /// Whether the running job can be paused right now. hdiutil's DMG imaging can't
    /// be safely suspended (its diskimages-helper child segfaults), so Pause is only
    /// offered while a pausable tool runs: ditto/rsync archives and our transfer loop.
    func canPause(_ job: BackupJob) -> Bool {
        guard isRunning(job.id), !isPaused(job.id) else { return false }
        switch jobStage[job.id] {
        case .transferring:           return true
        case .archiving:              return job.format != .sealedDMG   // ditto/rsync ok, hdiutil not
        default:                      return false                      // preparing/verify/checksum
        }
    }

    /// start queued jobs up to the concurrency limit.
    private func pump() {
        while runningJobIDs.count < maxConcurrent, let next = queue.first {
            queue.removeFirst()
            guard let job = jobs.first(where: { $0.id == next }) else { continue }
            startRun(job)
        }
    }

    private func startRun(_ job: BackupJob) {
        let id = job.id
        let startedAt = Date()
        runningJobIDs.insert(id)
        refreshSleepGuard()
        let control = RunControl(); controls[id] = control
        jobStage[id] = .preparing
        log("▶ \(job.name)")
        let resolved = job.resolvingLibraries(in: registry)
        let executor = TransferConfig.makeExecutor(detector: detector, store: store)
        Task {
            do {
                let outcome = try await executor.run(resolved, ownerUID: getuid(), now: Date(), control: control,
                    onStage: { s in Task { @MainActor in self.jobStage[id] = s } },
                    onLibrary: { lib in Task { @MainActor in self.jobLibrary[id] = lib; self.log("  ▸ \(lib)") } },
                    onProgress: { p in Task { @MainActor in self.jobProgress[id] = p } })
                apply(RunRecord.make(job: job, outcome: outcome, startedAt: startedAt, finishedAt: Date(), trigger: "manual"))
            } catch {
                apply(RunRecord.failure(job: job, error: error.localizedDescription,
                                        startedAt: startedAt, finishedAt: Date(), trigger: "manual"))
            }
            runningJobIDs.remove(id); controls[id] = nil; jobStage[id] = nil; jobLibrary[id] = nil; jobProgress[id] = nil
            pausedJobIDs.remove(id)
            refreshSleepGuard()
            jobs = store.load().jobs
            revalidate()
            armWake()                               // lastRun changed — re-point the wake
            pump()                                  // give the next queued job its slot
        }
    }

    /// persist a finished run, update its badge, and narrate the result.
    private func apply(_ record: RunRecord) {
        history.append(record)
        lastRecords[record.jobID] = record
        if let w = record.warning { log("⚠︎ \(w)") }
        log(Self.historyLine(record))
        maybeNotify(record)
    }

    static func symbol(_ kind: RunOutcomeKind) -> String {
        switch kind {
        case .verified, .completed: return "✓"
        case .failed:               return "✗"
        case .deferred:             return "⏸"
        case .cancelled:            return "⏹"
        }
    }

    static func historyLine(_ r: RunRecord) -> String {
        let when = r.finishedAt.formatted(date: .abbreviated, time: .shortened)
        let tag = r.trigger == "scheduled" ? " (scheduled)" : ""
        return "\(symbol(r.outcome)) \(r.jobName)\(tag): \(r.summary) · \(when)"
    }

    private func log(_ line: String) {
        activity.insert(line, at: 0)
        if activity.count > 60 { activity.removeLast() }
    }
}

// MARK: - display helpers

extension BackupFrequency {
    var label: String {
        switch self {
        case .manual: return "Manual"
        case .oneTime(let d): return "Once · \(d.formatted(date: .abbreviated, time: .shortened))"
        case .everyHours(let h): return "Every \(h)h"
        case .daily(let h, let m): return String(format: "Daily · %02d:%02d", h, m)
        }
    }
}

extension FormatChoice {
    var label: String {
        switch self {
        case .sealedDMG: return "Sealed DMG"
        case .sealedZip: return "Sealed zip"
        case .liveMirror(let g):
            return "Live mirror · " + ((g >= 1000 && g % 1000 == 0) ? "\(g / 1000) TB" : "\(g) GB")
        }
    }
}
