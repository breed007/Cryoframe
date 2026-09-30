//
//  AppModel.swift
//  Cryoframe (app)
//
//  Central state for the GUI: jobs (persisted), targets, system services, and
//  the live run/verification status. Runs jobs through the same JobRunner the
//  scheduled agent uses, under the same per-job run lock, and shows (and can stop)
//  the runs the agent is doing.
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
    private let healthStore = HealthStore.standard()
    private let runLocks = RunLocks.standard()

    @Published var jobs: [BackupJob] = []
    @Published var targets: [Target] = []
    @Published var activity: [String] = []
    @Published var lastRecords: [String: RunRecord] = [:]   // latest run per job (persisted)
    @Published var lastGood: [String: Date] = [:]           // when each job last finished a good run
    @Published var unrecordedRuns: [String: Date] = [:]     // runs the job store saw that the history no longer holds
    @Published var clock = Date()                           // moves every few minutes, so "overdue" arrives on its own
    @Published var scheduleOn = true                        // the scheduled agent is switched on
    @Published var lastHealth: [String: HealthRecord] = [:] // latest archive health check per job
    @Published var healthRecords: [HealthRecord] = []       // full history, newest first — drives per-version "verified" badges
    @Published var verifyingJobIDs: Set<String> = []        // jobs whose archives are being re-verified
    @Published var runningJobIDs: Set<String> = []      // jobs this app is running
    @Published var externalRuns: [String: RunHolder] = [:]   // jobs another process (the agent) is running
    @Published var stoppingJobIDs: Set<String> = []     // external runs asked to stop, not yet ended
    @Published var pausedJobIDs: Set<String> = []       // running jobs whose tool is suspended
    @Published var jobStage: [String: BackupStage] = [:]
    @Published var jobLibrary: [String: String] = [:]   // job id -> library being archived
    @Published var jobProgress: [String: RunProgress] = [:]
    @Published var fullDiskAccess = false
    @Published var libraryValid: [String: Bool] = [:]   // built-in id  -> resolved path exists
    @Published var jobValid: [String: Bool] = [:]       // job id       -> all libraries resolve
    @Published var showHelp = false                     // drives the Help sheet from the in-window button AND the Help menu
    // window sheets live here too, so File-menu commands and keyboard shortcuts
    // can drive the same state the toolbar buttons do.
    @Published var showNewJob = false
    @Published var showRestore = false
    @Published var showRecovery = false
    @Published var newJobLibraryID: String?   // preselect this library when the wizard opens
    @Published var showStorage = false
    @Published var showHistory = false
    @Published var protectedBytes: UInt64?              // total on-disk footprint across all destinations (dashboard)

    private var queue: [String] = []                    // job ids waiting for a run slot
    private var controls: [String: RunControl] = [:]
    private let sleepGuard = SleepGuard()
    private var notifiedIDs = Set<String>()             // run records already notified this session
    private var notifiedHealthIDs = Set<String>()       // health records already notified this session
    private var historyWatcher: DirWatcher?
    private var runWatch: Task<Void, Never>?
    private var maxConcurrent: Int {
        let n = UserDefaults.standard.integer(forKey: Prefs.maxConcurrent)
        return n > 0 ? n : 2
    }

    init() {
        // No default destination. Seeding one put a backup of the boot disk ON the
        // boot disk, pre-selected — the path of least resistance produced a copy that
        // survives nothing but an accidental delete. Choosing is the whole point.
        // The destinations you do choose are remembered, so choosing happens once.
        targets = Self.loadKnownTargets()
        let loaded = store.load()
        jobs = loaded.jobs
        reloadHistory()                         // last-run badges, persisted across launches
        if loaded.droppedJobs > 0 {             // a partial decode shouldn't be silent
            log("⚠︎ \(loaded.droppedJobs) job\(loaded.droppedJobs == 1 ? "" : "s") couldn't be read and were skipped — they may have been written by a newer version.")
        }
        for r in history.all().prefix(8).reversed() { log(Self.historyLine(r)) }   // seed the activity log
        reloadHealth()
        notifiedIDs = Set(history.all().map(\.id))   // don't notify for runs that predate this launch
        notifiedHealthIDs = Set(healthStore.all().map(\.id))
        Notifier.requestAuthorization()
        startHistoryWatch()                     // catch scheduled runs while resident in the menu bar
        refreshDiskAccess()
        revalidate()
        Task {
            await helper.reloadIfStale()        // pick up a new helper binary after an app update
            await cleanUpLeftovers()            // then snapshots and mounts a crashed run left behind
        }
        Task.detached { ArchiveReader.sweepStaleOpens() }   // clean any browse mounts a crash left attached
        let locks = runLocks
        Task.detached { JobExecutor.sweepOrphanedScratch(scratchBase: TransferConfig.scratchBase(),
                                                         pendingStore: .standard(), locks: locks) }   // clean leftover build artifacts
        watchOtherRuns()
        resumeTransfers()
        armWake()                               // align the optional pmset wake with the schedule
        refreshProtectedSize()                  // dashboard "backed up" total
    }

    /// rebuild the per-job latest-run map from the durable history (also picks up
    /// runs the scheduled agent recorded while the GUI was closed).
    func reloadHistory() {
        var latest: [String: RunRecord] = [:]
        for r in history.all() where latest[r.jobID] == nil { latest[r.jobID] = r }   // newest-first → first wins
        lastRecords = latest
        lastGood = history.lastGood()
        let all = history.all(), ran = store.load().lastRun
        var unrecorded: [String: Date] = [:]
        for job in jobs {
            unrecorded[job.id] = ProtectionVerdict.unrecordedRun(lastRun: ran[job.id], records: all.filter { $0.jobID == job.id })
        }
        unrecordedRuns = unrecorded
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
        reloadHealth()
        for r in history.all() { maybeNotify(r) }
        for h in healthStore.all() { maybeNotifyHealth(h) }
    }

    // MARK: - storage pressure

    @Published var storageFindings: [StoragePressure.Finding] = []

    /// measure the destinations and work out what is going to run out. Off the main
    /// thread: it walks the archive folders.
    func refreshStoragePressure() {
        let jobs = self.jobs
        guard !jobs.isEmpty else { storageFindings = []; return }
        let retention = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0.retention) })
        Task.detached {
            let report = StorageReporter.report(jobs)
            let found = StoragePressure.findings(storage: report, retention: retention)
            await MainActor.run { self.storageFindings = found }
        }
    }

    // MARK: - coverage advisor

    /// libraries on this Mac that no job covers, minus the ones waved off.
    var coverageGaps: [CoverageAdvisor.Gap] {
        let locator = ContentLocator()
        return CoverageAdvisor.gaps(types: registry.types, jobs: jobs,
                                    dismissed: Set(UserDefaults.standard.stringArray(forKey: Prefs.coverageDismissed) ?? []),
                                    resolve: { locator.liveRoots(of: $0).first })
    }

    /// stop mentioning this library. Deliberately permanent — being told twice about
    /// something you've already decided against is what makes an advisor a nag.
    func dismissCoverage(_ typeID: String) {
        var list = UserDefaults.standard.stringArray(forKey: Prefs.coverageDismissed) ?? []
        guard !list.contains(typeID) else { return }
        list.append(typeID)
        UserDefaults.standard.set(list, forKey: Prefs.coverageDismissed)
        objectWillChange.send()
    }

    /// open the New Job wizard already pointed at this library.
    func startJob(forLibrary typeID: String) {
        newJobLibraryID = typeID
        showNewJob = true
    }

    /// rebuild the per-job latest archive-health map from disk.
    func reloadHealth() {
        let all = healthStore.all()                 // newest first
        var latest: [String: HealthRecord] = [:]
        for r in all where latest[r.jobID] == nil { latest[r.jobID] = r }
        lastHealth = latest
        healthRecords = all
    }

    /// Rehearse recovering this job: look at its destinations the way a recovery
    /// would, and report what would actually come back. Off the main thread — it
    /// opens archives.
    func rehearseRecovery(_ job: BackupJob) {
        guard !verifyingJobIDs.contains(job.id) else { return }
        verifyingJobIDs.insert(job.id)
        log("🎯 \(job.name): rehearsing a recovery…")
        let store = JobStore.standard()
        Task.detached {
            let (records, busy) = RehearsalSchedule.run(store: store, now: Date(), jobs: [job.id])
            await MainActor.run {
                self.verifyingJobIDs.remove(job.id)
                for r in records { self.applyHealth(r) }
                if let b = busy.first { self.log(Self.busyCheckLine(job.name, holder: b.holder)) }
            }
        }
    }

    /// re-verify a job's existing archives against their checksums, off the main thread.
    func verifyArchives(_ job: BackupJob) {
        guard !verifyingJobIDs.contains(job.id) else { return }
        verifyingJobIDs.insert(job.id)
        log("🔍 \(job.name): checking archives…")
        let resolved = job.resolvingLibraries(in: registry)
        let latestOnly = UserDefaults.standard.string(forKey: Prefs.healthScope) != "all"
        let materializeCloud = UserDefaults.standard.bool(forKey: Prefs.verifyCloudArchives)
        let locks = runLocks
        Task.detached {
            let checked = locks.whileChecking(jobID: job.id) {
                HealthChecker().check(job: resolved, latestOnly: latestOnly, materializeCloud: materializeCloud)
            }
            await MainActor.run {
                self.verifyingJobIDs.remove(job.id)
                self.applyChecked(checked, job: resolved, kind: "checksum")
            }
        }
    }

    /// record a check done under the job's lock, or say why it wasn't done
    private func applyChecked(_ checked: CheckUnderLock<HealthReport>, job: BackupJob, kind: String) {
        switch checked {
        case .done(let report): applyHealth(HealthRecord.from(job: job, report: report, at: Date(), kind: kind))
        case .busy(let holder): log(Self.busyCheckLine(job.name, holder: holder))
        case .unavailable(let why): log("⚠︎ \(job.name): its archives weren't checked — \(why)")
        }
    }

    /// A check reads the newest version, so it waits for a run writing one: while a
    /// run holds the job, the check isn't made.
    static func busyCheckLine(_ name: String, holder: RunHolder?) -> String {
        "⏸ \(name): \(holder?.busyDoing ?? "it couldn't be told whether a backup of this job is running"), so its archives weren't checked — check again once it's done"
    }

    /// run a restore drill: reassemble, mount/extract, and reopen each archive — proves
    /// the restore path works, not just that the bytes match. Needs the passphrase for
    /// an encrypted job, so it runs in the GUI where the Keychain is reachable.
    func drillArchives(_ job: BackupJob) {
        guard !verifyingJobIDs.contains(job.id) else { return }
        verifyingJobIDs.insert(job.id)
        log("🧪 \(job.name): restore drill…")
        let resolved = job.resolvingLibraries(in: registry)
        let latestOnly = UserDefaults.standard.string(forKey: Prefs.healthScope) != "all"
        let materializeCloud = UserDefaults.standard.bool(forKey: Prefs.verifyCloudArchives)
        let passphrase = job.encrypted ? KeychainArchiveKey.load(jobID: job.id) : nil
        let locks = runLocks
        Task.detached {
            let checked = locks.whileChecking(jobID: job.id) {
                RestoreDriller().drill(job: resolved, latestOnly: latestOnly, passphrase: passphrase, materializeCloud: materializeCloud)
            }
            await MainActor.run {
                self.verifyingJobIDs.remove(job.id)
                self.applyChecked(checked, job: resolved, kind: "drill")
            }
        }
    }

    @Published var librarySizes: [String: UInt64] = [:]     // library id → source bytes (cached this session)
    @Published var measuringSizes: Set<String> = []          // libraries whose size is being computed

    /// measure the source size of several libraries, one at a time off the main thread,
    /// caching each. Skips ones already known/in-flight or that don't resolve (no path /
    /// no Full Disk Access). Sizes fill in progressively so the UI never blocks.
    func measureLibraries(_ cts: [ContentType]) {
        let locator = ContentLocator()
        let todo: [(String, URL)] = cts.compactMap { ct in
            guard librarySizes[ct.id] == nil, !measuringSizes.contains(ct.id),
                  let root = locator.liveRoots(of: ct).first else { return nil }
            return (ct.id, root)
        }
        guard !todo.isEmpty else { return }
        for (id, _) in todo { measuringSizes.insert(id) }
        Task.detached(priority: .utility) {
            for (id, root) in todo {
                let size = JobExecutor.directorySize(root)
                await MainActor.run { self.librarySizes[id] = size; self.measuringSizes.remove(id) }
            }
        }
    }

    /// free + total bytes on the volume a URL lives on. Cheap (no directory walk).
    func volumeInfo(for url: URL) -> (free: UInt64, total: UInt64)? {
        let v = StorageReporter.volume(of: url)
        guard let f = v.free, let t = v.total else { return nil }
        return (f, t)
    }

    private var lastSizeRefresh = Date.distantPast
    /// recompute the total protected footprint (off-main, du-style) for the dashboard.
    /// Debounced — it walks every archive, so it's throttled to avoid re-scanning on
    /// every window focus; pass force after a job or run changes the archives.
    func refreshProtectedSize(force: Bool = false) {
        guard !jobs.isEmpty else { protectedBytes = 0; return }
        guard force || Date().timeIntervalSince(lastSizeRefresh) > 30 else { return }
        lastSizeRefresh = Date()
        let jobs = self.jobs
        Task.detached {
            let total = StorageReporter.report(jobs).reduce(UInt64(0)) { $0 + $1.archiveBytes }
            await MainActor.run { self.protectedBytes = total }
        }
    }

    /// the soonest upcoming scheduled run across all enabled jobs, for the dashboard.
    func nextScheduledRun() -> Date? {
        jobs.filter(\.enabled).compactMap { nextDue($0) }.filter { $0 > Date() }.min()
    }

    /// re-verify every job's archives — serially, so we don't saturate the disk with
    /// one full re-hash per job at once.
    func verifyAllArchives() {
        let pending = jobs.filter { !verifyingJobIDs.contains($0.id) }
        guard !pending.isEmpty else { return }
        for j in pending { verifyingJobIDs.insert(j.id) }
        let resolved = pending.map { $0.resolvingLibraries(in: registry) }
        let latestOnly = UserDefaults.standard.string(forKey: Prefs.healthScope) != "all"
        let materializeCloud = UserDefaults.standard.bool(forKey: Prefs.verifyCloudArchives)
        log("🔍 verifying \(resolved.count) job\(resolved.count == 1 ? "" : "s")…")
        let locks = runLocks
        Task.detached {
            for job in resolved {
                let checked = locks.whileChecking(jobID: job.id) {
                    HealthChecker().check(job: job, latestOnly: latestOnly, materializeCloud: materializeCloud)
                }
                await MainActor.run {
                    self.verifyingJobIDs.remove(job.id)
                    self.applyChecked(checked, job: job, kind: "checksum")
                }
            }
        }
    }

    private func applyHealth(_ record: HealthRecord) {
        healthStore.append(record)
        lastHealth[record.jobID] = record
        healthRecords.insert(record, at: 0)      // keep the badge source in step with the store
        log(Self.healthLine(record))
        maybeNotifyHealth(record)
    }

    private func maybeNotifyHealth(_ record: HealthRecord) {
        guard !notifiedHealthIDs.contains(record.id) else { return }
        notifiedHealthIDs.insert(record.id)
        // a 0-archive result on a job that has never produced a run isn't "target offline" —
        // it's "nothing to check yet". Don't nag (locally or remotely) about a brand-new job.
        if record.archivesChecked == 0, lastRecords[record.jobID] == nil { return }
        Notifier.notifyHealth(record)
    }

    static func healthLine(_ r: HealthRecord) -> String {
        let when = r.checkedAt.formatted(date: .abbreviated, time: .shortened)
        let glyph = r.isRehearsal ? "🎯" : (r.isDrill ? "🧪" : "🔍")
        let verb = r.isRehearsal ? "rehearsed clean" : (r.isDrill ? "drilled clean" : "verified")
        let skip = r.skipped > 0 ? " (\(r.skipped) not downloaded)" : ""
        return r.passed
            ? "\(glyph) \(r.jobName): \(r.archivesChecked) archive\(r.archivesChecked == 1 ? "" : "s") \(verb)\(skip) · \(when)"
            : "⚠︎ \(r.jobName): \(r.failures.count) \(r.failureNoun) check(s) failed\(skip) · \(when)"
    }

    /// post a notification for a record once per session (policy is applied inside).
    private func maybeNotify(_ record: RunRecord) {
        guard !notifiedIDs.contains(record.id) else { return }
        notifiedIDs.insert(record.id)
        Notifier.notify(record)
    }

    /// the menu-bar glyph reflecting overall backup health.
    /// the menu-bar glyph is the dashboard's verdict, so the two can never disagree.
    var menuBarSymbol: String { ProtectionStatus.compute(self).glyph }

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
        let locks = runLocks
        Task.detached {
            let resumed = TransferResumer.resumeAll(store: PendingTransferStore.standard(), locks: locks)
            if !resumed.isEmpty {
                await MainActor.run { self.activity.insert("resumed \(resumed.count) interrupted transfer(s)", at: 0) }
            }
        }
    }

    // MARK: jobs / targets

    func addJob(_ job: BackupJob) { store.upsert(job); jobs = store.load().jobs; revalidate(); armWake(); refreshProtectedSize(force: true) }
    func deleteJob(_ id: String) { stopJob(id); KeychainArchiveKey.delete(jobID: id); store.remove(id: id); jobs = store.load().jobs; lastRecords[id] = nil; revalidate(); armWake() }
    func addTarget(_ target: Target) {
        targets.removeAll { $0.id == target.id }; targets.append(target)
        Self.saveKnownTargets(targets)
    }

    /// destinations you've picked before, so a removed default doesn't mean choosing
    /// your NAS again on every launch.
    private static func loadKnownTargets() -> [Target] {
        guard let data = UserDefaults.standard.data(forKey: Prefs.knownTargets),
              let list = try? JSONDecoder().decode([Target].self, from: data) else { return [] }
        return list
    }
    private static func saveKnownTargets(_ list: [Target]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: Prefs.knownTargets)
    }

    /// drop a destination from the picker list. Still refuses one a job depends on —
    /// removing it there would hide the destination without changing the job, which
    /// reads as "deleted" while backups keep going to it.
    func canRemoveTarget(_ id: String) -> Bool {
        !jobs.contains { $0.targets.contains { $0.id == id } }
    }
    /// why a destination can't be removed, for the UI to say out loud.
    func removalBlockedReason(_ id: String) -> String? {
        let users = jobs.filter { $0.targets.contains { $0.id == id } }.map(\.name)
        guard !users.isEmpty else { return nil }
        return "\(users.joined(separator: ", ")) back\(users.count == 1 ? "s" : "") up here. Edit or delete the job first."
    }
    func removeTarget(_ id: String) {
        guard canRemoveTarget(id) else { return }
        targets.removeAll { $0.id == id }
        Self.saveKnownTargets(targets)
    }

    /// distinct destinations to offer in Restore — the session targets plus every
    /// destination a job actually backs up to (NAS, external, cloud), deduped by path.
    var restoreSources: [Target] {
        var seen = Set<String>(), out: [Target] = []
        for t in targets + jobs.flatMap(\.targets) where seen.insert(t.destinationDir.path).inserted { out.append(t) }
        return out
    }

    func setEnabled(_ job: BackupJob, _ enabled: Bool) {
        var j = job; j.enabled = enabled; store.upsert(j); jobs = store.load().jobs; armWake()
    }

    /// copy an encrypted job's passphrase to the clipboard so the user can escrow it
    /// (a password manager). The key is machine-bound — losing it means the backup
    /// can't be decrypted, so escrow is the only recovery path.
    func copyPassphrase(_ job: BackupJob) {
        guard job.encrypted, let pass = KeychainArchiveKey.load(jobID: job.id), !pass.isEmpty else {
            log("⚠︎ \(job.name): no saved passphrase to copy"); return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pass, forType: .string)
        log("🔑 \(job.name): passphrase copied — save it somewhere safe")
    }

    func hasStoredPassphrase(_ job: BackupJob) -> Bool { job.encrypted && KeychainArchiveKey.exists(jobID: job.id) }

    func owningAppRunning(_ type: ContentType) -> Bool { type.owningProcessRunning(detector) }
    func openOwners(_ job: BackupJob) -> [String] {
        job.libraries.compactMap(\.owningProcess).filter(detector.isRunning).map(\.displayName)
    }
    func isRunning(_ id: String) -> Bool { runningJobIDs.contains(id) || externalRuns[id] != nil }
    func isQueued(_ id: String) -> Bool { queue.contains(id) }
    /// every running job, whether this app or the scheduled agent is running it.
    var allRunningJobIDs: Set<String> { runningJobIDs.union(externalRuns.keys) }
    /// jobs being backed up right now, here or elsewhere: not a check of their archives
    var backingUpJobIDs: Set<String> { runningJobIDs.union(externalRuns.filter { $0.value.trigger != .check }.keys) }

    /// what a running job's badge says: its stage when this app runs it (only this
    /// process sees the stages), otherwise who is running it.
    func runningLabel(_ id: String) -> String {
        if let stage = jobStage[id] { return stage.rawValue }
        if stoppingJobIDs.contains(id) { return "stopping…" }
        return externalRuns[id]?.runningLabel ?? "running"
    }

    func nextDue(_ job: BackupJob) -> Date? {
        let ref = store.load().lastRun[job.id] ?? job.createdAt
        return job.frequency.nextFireDate(after: ref)
    }

    // MARK: running

    func runNow(_ job: BackupJob) {
        guard !runningJobIDs.contains(job.id), !queue.contains(job.id) else { return }
        if let holder = externalRuns[job.id] {
            log("⏸ \(job.name): \(RunLockError.alreadyRunning(holder).localizedDescription)")
            return
        }
        queue.append(job.id)
        pump()
    }

    func stopJob(_ id: String) {
        queue.removeAll { $0 == id }
        if controls[id] == nil, let holder = externalRuns[id] {
            // the scheduled agent is running it: ask that process to stop its own run,
            // so its teardown (snapshot, mounts, tools) happens where they live
            let name = jobs.first { $0.id == id }?.name ?? "Job"
            if holder.trigger == .cleanup {
                // a scratch tidy holds the lock for a moment and listens for nothing
                log("⏸ \(name): tidying up leftovers — done in a moment")
            } else if holder.trigger == .check {
                // checks and drills can't be stopped part-way yet
                log("⏸ \(name): its archives are being checked — that can't be stopped part-way; it ends on its own")
            } else if runLocks.requestStop(jobID: id) {
                stoppingJobIDs.insert(id)
                log("⏹ \(name): asked the scheduled run to stop")
            } else {
                log("⚠︎ \(name): couldn't reach the run to stop it — try again in a moment")
            }
            return
        }
        controls[id]?.cancel()
        pausedJobIDs.remove(id)
    }

    // MARK: runs in other processes

    /// Poll the run locks so a job the scheduled agent is running shows as running
    /// here, and stops showing the moment it ends (even if the agent crashed: the
    /// kernel drops a dead process's lock). Only looks; never takes a lock.
    private func watchOtherRuns() {
        runWatch?.cancel()
        scheduleOn = schedule.isEnabled
        runWatch = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshOtherRuns()
                // a job falls overdue with nothing happening; the schedule can be
                // switched off in Settings or System Settings
                if Date().timeIntervalSince(self.clock) >= 30 {
                    self.clock = Date()
                    let on = self.schedule.isEnabled
                    if on != self.scheduleOn { self.scheduleOn = on }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func refreshOtherRuns() {
        let found = runLocks.holders(of: jobs.map(\.id))
            .filter { !$0.value.isThisProcess && !runningJobIDs.contains($0.key) }
        guard found != externalRuns else { return }
        let ended = Set(externalRuns.keys).subtracting(found.keys)
        externalRuns = found
        stoppingJobIDs.formIntersection(found.keys)
        if !ended.isEmpty {
            reloadHistory()                         // the agent recorded the result as it finished
            refreshProtectedSize(force: true)
            armWake()                               // lastRun moved
        }
    }

    /// clean up snapshots and mounts a crashed run left behind. The helper keeps
    /// anything a live process owns; LeftoverCleanup adds that it only asks while no
    /// job is running and only a helper new enough to keep them.
    private func cleanUpLeftovers() async {
        guard helper.isEnabled else { return }
        let ids = jobs.map(\.id), locks = runLocks
        let outcome = await Task.detached {
            let xpc = XPCPrivilegedHelper()
            defer { xpc.invalidate() }
            return await LeftoverCleanup.run(helper: xpc, locks: locks, jobIDs: ids)
        }.value
        if case .cleaned(let r) = outcome, !(r.unmounted.isEmpty && r.deletedSnapshots.isEmpty) {
            log("🧹 cleaned up after an interrupted backup: \(r.unmounted.count) snapshot mount\(r.unmounted.count == 1 ? "" : "s"), \(r.deletedSnapshots.count) snapshot\(r.deletedSnapshots.count == 1 ? "" : "s")")
        }
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
        runningJobIDs.insert(id)
        refreshSleepGuard()
        let control = RunControl(); controls[id] = control
        jobStage[id] = .preparing
        let resolved = job.resolvingLibraries(in: registry)
        let executor = TransferConfig.makeExecutor(detector: detector, store: store)
        let locks = runLocks
        Task {
            // One run per job across this app and the scheduled agent. The short wait
            // rides out a momentary holder (a scratch tidy) that isn't a run.
            let lease: RunLease
            do {
                lease = try await Task.detached { try locks.acquire(jobID: id, trigger: .manual, wait: 2) }.value
            } catch RunLockError.alreadyRunning(let holder) {
                log("⏸ \(job.name): \(RunLockError.alreadyRunning(holder).localizedDescription)")
                finishRun(id)
                refreshOtherRuns()
                return
            } catch {
                apply(RunRecord.failure(job: job, error: error.localizedDescription,
                                        startedAt: Date(), finishedAt: Date(), trigger: "manual"))
                finishRun(id)
                return
            }
            lease.onStopRequest { control.cancel() }
            let startedAt = Date()
            // marks the run as started; its result line replaces it when it finishes, so
            // the log doesn't accumulate a timestamp-less "▶ JobName" beside every
            // completed run — which reads like a run that started and never came back.
            log(Self.startedLine(job.name))
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
            lease.release()
            jobs = store.load().jobs
            revalidate()
            armWake()                               // lastRun changed — re-point the wake
            finishRun(id)
        }
    }

    /// clear a run's live state and give the next queued job its slot.
    private func finishRun(_ id: String) {
        runningJobIDs.remove(id); controls[id] = nil; jobStage[id] = nil; jobLibrary[id] = nil; jobProgress[id] = nil
        pausedJobIDs.remove(id)
        refreshSleepGuard()
        pump()
    }

    /// persist a finished run, update its badge, and narrate the result.
    private func apply(_ record: RunRecord) {
        history.append(record)
        lastRecords[record.jobID] = record
        if record.outcome.isGood { lastGood[record.jobID] = record.finishedAt }
        if record.outcome != .deferred { unrecordedRuns[record.jobID] = nil }      // this run is on record now
        if let w = record.warning { log("⚠︎ \(w)") }
        logFinished(record)
        maybeNotify(record)
    }

    static func symbol(_ kind: RunOutcomeKind) -> String {
        switch kind {
        case .verified, .completed: return "✓"
        case .partial:              return "⚠︎"
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

    /// the one place the "started" line is formatted — the finish path has to find
    /// the exact string the start path wrote, and two literals drift.
    static func startedLine(_ jobName: String) -> String { "▶ \(jobName)" }

    private func log(_ line: String) {
        activity.insert(line, at: 0)
        if activity.count > 60 { activity.removeLast() }
    }

    /// log a finished run, taking its "started" line out of the list. Derived from
    /// the record rather than kept in a side table: nothing to leak when a run ends
    /// by a path that doesn't come through here.
    private func logFinished(_ record: RunRecord) {
        if let i = activity.firstIndex(of: Self.startedLine(record.jobName)) { activity.remove(at: i) }
        log(Self.historyLine(record))
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
