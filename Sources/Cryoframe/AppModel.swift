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

    @Published var jobs: [BackupJob] = []
    @Published var targets: [Target] = []
    @Published var activity: [String] = []
    @Published var lastResults: [String: RunResult] = [:]
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
    private var maxConcurrent: Int {
        let n = UserDefaults.standard.integer(forKey: Prefs.maxConcurrent)
        return n > 0 ? n : 2
    }

    enum RunResult: Equatable { case verified(String), completed(String), deferred(String), failed(String), cancelled(String) }

    init() {
        let pref = UserDefaults.standard.string(forKey: Prefs.archiveDir)
        let dir = (pref.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) })
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Cryoframe Archives", isDirectory: true)
        targets = [.localVolume(id: "local-default", name: dir.lastPathComponent, dir: dir)]
        jobs = store.load().jobs
        refreshDiskAccess()
        revalidate()
        Task { await helper.reloadIfStale() }   // pick up a new helper binary after an app update
        resumeTransfers()
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

    func addJob(_ job: BackupJob) { store.upsert(job); jobs = store.load().jobs; revalidate() }
    func deleteJob(_ id: String) { stopJob(id); store.remove(id: id); jobs = store.load().jobs; lastResults[id] = nil; revalidate() }
    func addTarget(_ target: Target) { targets.removeAll { $0.id == target.id }; targets.append(target) }

    func setEnabled(_ job: BackupJob, _ enabled: Bool) {
        var j = job; j.enabled = enabled; store.upsert(j); jobs = store.load().jobs
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
        lastResults[job.id] = nil
        queue.append(job.id)
        pump()
    }

    func stopJob(_ id: String) {
        queue.removeAll { $0 == id }
        controls[id]?.cancel()
        pausedJobIDs.remove(id)
    }

    func pauseJob(_ id: String) { if controls[id]?.pause() == true { pausedJobIDs.insert(id) } }
    func resumeJob(_ id: String) { controls[id]?.resume(); pausedJobIDs.remove(id) }
    func isPaused(_ id: String) -> Bool { pausedJobIDs.contains(id) }

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
        runningJobIDs.insert(id)
        let control = RunControl(); controls[id] = control
        jobStage[id] = .preparing
        log("▶ \(job.name)")
        let resolved = job.resolvingLibraries(in: registry)
        let executor = TransferConfig.makeExecutor(detector: detector, store: store)
        Task {
            do {
                let outcome = try await executor.run(resolved, ownerUID: getuid(), now: Date(), control: control,
                    onStage: { s in Task { @MainActor in self.jobStage[id] = s } },
                    onLibrary: { lib in Task { @MainActor in self.jobLibrary[id] = lib } },
                    onProgress: { p in Task { @MainActor in self.jobProgress[id] = p } })
                handle(job, outcome)
            } catch {
                log("✗ \(job.name): \(error.localizedDescription)")
                lastResults[id] = .failed(error.localizedDescription)
            }
            runningJobIDs.remove(id); controls[id] = nil; jobStage[id] = nil; jobLibrary[id] = nil; jobProgress[id] = nil
            jobs = store.load().jobs
            revalidate()
            pump()                                  // give the next queued job its slot
        }
    }

    private func handle(_ job: BackupJob, _ outcome: JobOutcome) {
        switch outcome {
        case .deferred(let r):
            log("⏸ \(job.name): \(r)"); lastResults[job.id] = .deferred(r)
        case .cancelled:
            log("⏹ \(job.name): stopped"); lastResults[job.id] = .cancelled("stopped")
        case .finished(let results, let warning):
            if let warning { log("⚠︎ \(warning)") }
            let s = Self.summarize(results)
            lastResults[job.id] = s.result
            log("\(s.symbol) \(job.name): \(s.text)")
        }
    }

    static func summarize(_ results: [LibraryRunResult]) -> (result: RunResult, symbol: String, text: String) {
        var done = 0, verified = 0, failed = 0, notFound = 0
        for r in results {
            switch r {
            case .completed(_, _, let v): if v == false { failed += 1 } else { done += 1; if v == true { verified += 1 } }
            case .notFound: notFound += 1
            case .failed: failed += 1
            }
        }
        let total = results.count
        func plural(_ n: Int) -> String { n == 1 ? "library" : "libraries" }
        if failed > 0 || notFound > 0 {
            var parts = ["\(done)/\(total) archived"]
            if notFound > 0 { parts.append("\(notFound) not found") }
            if failed > 0 { parts.append("\(failed) failed") }
            let text = parts.joined(separator: ", ")
            return (.failed(text), "✗", text)
        }
        if total > 0, verified == total {
            let text = "\(total) \(plural(total)) verified"
            return (.verified(text), "✓", text)
        }
        let text = "\(total) \(plural(total)) archived"
        return (.completed(text), "✓", text)
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
        case .liveMirror(let g): return "Live mirror · \(g)GB"
        }
    }
}
