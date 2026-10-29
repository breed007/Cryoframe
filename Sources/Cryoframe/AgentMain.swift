//
//  AgentMain.swift
//  Cryoframe (app) — headless scheduled run
//
//  Launched periodically by the LaunchAgent. Cleans up after crashed runs,
//  resumes interrupted transfers, then runs any due jobs (up to the concurrency
//  limit) through the same JobExecutor the GUI uses, then exits. Every run holds
//  its job's run lock, so a job the app is already running is left to the app.
//  When the app isn't open, it also posts the notices the app would have (Notifier).
//

import AppKit
import Foundation
import ServiceManagement
import CryoframeShared
import CryoframeKit

enum AgentMain {
    static func run() {
        let store = JobStore.standard()
        let locks = RunLocks.standard()
        cleanUpLeftovers(jobIDs: store.load().jobs.map(\.id), locks: locks)
        // archives and mirrors a crashed process left attached (the app does this at
        // launch too); ones a live process has open are left alone
        ArchiveReader.sweepStaleOpens()
        // finish interrupted transfers first
        let resumes = TransferResumer.resume(store: PendingTransferStore.standard(), locks: locks)

        // Woken for a scheduled backup, this pass starts a couple of minutes before the
        // job's time (see WakeScheduler), and the Mac may be asleep again by the next
        // one: wait for it, awake.
        if UserDefaults.standard.bool(forKey: Prefs.wakeForSchedule),
           let wait = Scheduler().waitForNextDue(store.load(), now: Date(), within: WakeScheduler.leadSeconds + 60) {
            let waiting = SleepGuard()
            waiting.begin()
            Thread.sleep(forTimeInterval: wait + 1)
            waiting.end()
        }

        // a due job the app is running right now is the app's run: it records the
        // result and moves the schedule on. Not due here, and not a deferral either.
        // A chore holding the lock (a tidy, a transfer finishing) isn't a run; the
        // acquire below waits it out or records why the job waited. A job whose
        // transfer was just stopped from the app waits for the next pass.
        let running = locks.runningJobIDs(among: store.load().jobs.map(\.id))
        var due = Scheduler().jobsToStart(store.load(), now: Date(), running: running,
                                          stoppedThisPass: resumes.stoppedJobIDs)
        var alerts: [RunRecord] = []      // failures to start, delivered once the run loop is done
        let finished = Finished()         // every run's record, for the notices on this Mac
        var notices: [(payload: AlertPolicy.Payload, record: RunRecord)] = []     // deferrals that have gone on
        let historyStore = RunHistoryStore.standard()
        // One history record per run of deferrals, kept up to date, rather than one
        // every hour (see RunHistoryStore.recordDeferral); an alert once it has
        // happened several times in a row.
        func deferred(_ job: BackupJob, _ reason: String) {
            let (record, count) = historyStore.recordDeferral(job: job, reason: reason, at: Date())
            if let p = AlertPolicy.payload(forDeferral: record, count: count) { notices.append((p, record)) }
        }

        // Unattended work on a dying laptop battery is how a Mac ends up flat. Hold
        // the run for the next hourly check (it may be plugged in by then), and
        // RECORD the deferral — a backup that quietly doesn't happen is the whole
        // failure mode this app exists to prevent. Manual runs never come through here.
        let power = SystemPowerSource().current()
        let floor = TransferConfig.batteryFloorPercent()
        if floor > 0, !due.isEmpty,
           BatteryPolicy.shouldDeferScheduledRun(power, minimumPercent: floor) {
            let reason = BatteryPolicy.deferralReason(power)
            for job in due { deferred(job, reason) }
            due = []
        }

        let healthDue = HealthSchedule.isDue(now: Date())
        let sleepGuard = SleepGuard()
        if !due.isEmpty || healthDue { sleepGuard.begin() }     // don't idle-sleep mid scheduled work
        if !due.isEmpty {
            let executor = TransferConfig.makeExecutor(detector: WorkspaceProcessDetector(), store: store)
            let registry = ContentTypeRegistry.withOverrides(LibraryOverrides.load())
            let limit = DispatchSemaphore(value: TransferConfig.maxConcurrentJobs())
            let group = DispatchGroup()

            for job in due {
                limit.wait()                                    // bound concurrency
                // One run per job, across this process and the app. Taken here, not
                // in the task: the short wait sleeps, and must not tie up the pool.
                let lease: RunLease
                do {
                    lease = try locks.acquire(jobID: job.id, trigger: .scheduled, wait: 2)
                } catch RunLockError.alreadyRunning(let holder) {
                    // a run started elsewhere since we looked: it records the result.
                    // A chore still holding it after the wait: say why this one waited.
                    if let reason = holder.deferralReason { deferred(job, reason) }
                    limit.signal(); continue
                } catch {
                    // can't tell whether it's running: say so rather than skip quietly
                    let now = Date()
                    let record = RunRecord.failure(job: job, error: error.localizedDescription,
                                                   startedAt: now, finishedAt: now, trigger: "scheduled")
                    historyStore.append(record)
                    alerts.append(record)
                    limit.signal(); continue
                }
                // the job as it is now it's ours: edited or deleted since the list was read
                guard let current = store.load().jobs.first(where: { $0.id == job.id }) else {
                    lease.release(); limit.signal(); continue
                }
                let control = RunControl()
                lease.onStopRequest { control.cancel() }        // Stop, pressed in the app
                group.enter()
                let resolved = current.resolvingLibraries(in: registry)
                Task {
                    let started = Date()
                    let record: RunRecord
                    do {
                        let outcome = try await executor.run(resolved, ownerUID: getuid(), now: Date(), control: control)
                        record = RunRecord.make(job: current, outcome: outcome,
                                                startedAt: started, finishedAt: Date(), trigger: "scheduled",
                                                bandChecks: control.bandChecks)
                    } catch {
                        record = RunRecord.failure(job: current, error: error.localizedDescription,
                                                   startedAt: started, finishedAt: Date(), trigger: "scheduled")
                    }
                    historyStore.append(record)
                    finished.add(record)
                    // each destination's trend, and a cloud run's versions for the upload check
                    RunFollowUp.record(record, job: current, health: .standard(), uploads: .standard(),
                                       lastCheck: HealthStore.standard().latest(forJob: current.id), checks: .standard())
                    lease.release()                                 // the run is over once it's recorded
                    await RemoteAlert.deliver(for: record)          // nobody is watching the screen
                    limit.signal()
                    group.leave()
                }
            }
            group.wait()
        }

        var checks = HealthSchedule.runIfDue(store: store, now: Date())   // re-verify cold archives if due
        checks += RehearsalSchedule.runIfDue(store: store, now: Date())   // and prove a recovery would work

        // A destination that fills up doesn't fail loudly, it just stops working —
        // and on an unattended Mac nobody sees the dashboard say so. Warn while
        // there's still room to act. Only once per destination per day, so a full
        // drive doesn't turn into an hourly alarm.
        let pressure = StoragePressure.findings(
            storage: StorageReporter.report(store.load().jobs),
            retention: Dictionary(uniqueKeysWithValues: store.load().jobs.map { ($0.id, $0.retention) })
        ).filter { $0.kind == .tight && StorageNag.shouldWarn($0.destination, now: Date()) }
        let remoteThrottle = AlertThrottle(key: AlertThrottle.overdueRemoteKey), overdueAt = Date()
        let overdue: [(AlertPolicy.Payload, @Sendable () -> Void)] = overdueAlerts(
            jobs: store.load().jobs, history: historyStore, lastRun: store.load().lastRun, now: overdueAt, throttle: remoteThrottle)
            .map { alert in (alert.payload, { remoteThrottle.recordSent(alert.subject, now: overdueAt) }) }
        sleepGuard.end()

        // Send everything before exiting. This process is the ONLY thing that will
        // tell you a scheduled backup failed while you weren't at the Mac: the app
        // marks every record that predates its launch as already-seen, so a failure
        // it wasn't running for is never announced later.
        // re-point the optional pmset wake at the next due job (lastRun may have changed).
        let runs = alerts + finished.records, madeChecks = checks      // for the notices, after
        let sem = DispatchSemaphore(value: 0)
        Task {
            for record in alerts { await RemoteAlert.deliver(for: record) }
            // an alert that couldn't go is owed at the next deferral of the same run
            for n in notices {
                let delivered = await RemoteAlert.deliverPayload(n.payload)
                historyStore.setDeferralAlertPending(recordID: n.record.id, !delivered)
            }
            for (p, sent) in overdue {
                if await RemoteAlert.deliverPayload(p) { sent() }
            }
            // a stopped check's failures too (see AlertPolicy.payload(forStopped:))
            for check in checks {
                if let p = check.alert(everyEvent: RemoteAlert.allEvents) { await RemoteAlert.deliverPayload(p) }
            }
            for finding in pressure {
                await RemoteAlert.deliverStorage(for: finding)
                StorageNag.recordWarned(finding.destination, now: Date())
            }
            await WakeScheduler.arm(store: store)
            sem.signal()
        }
        sem.wait()

        // Last of all, so that if macOS won't take them nothing above has changed.
        // Looked for here, on the main thread, just before posting.
        let appOpen = appIsOpen()
        let posted = DispatchSemaphore(value: 0)
        Task {
            await postNotices(runs: runs, checks: madeChecks, pressure: pressure, store: store, history: historyStore,
                              appOpen: appOpen)
            posted.signal()
        }
        posted.wait()
        exit(0)
    }

    /// Notices on this Mac for what this pass did, as the app would post them (see
    /// Notifier): when macOS allows them and the app isn't open. Each call to the
    /// notification center is given up after 5 seconds (LocalNotice).
    private static func postNotices(runs: [RunRecord], checks: [CheckRecording.Outcome],
                                    pressure: [StoragePressure.Finding], store: JobStore, history: RunHistoryStore,
                                    appOpen: Bool) async {
        let policy = Notifier.current()
        // the notification center needs the app's bundle; and with the app open, it posts
        guard policy != .never, !appOpen, Bundle.main.bundleIdentifier != nil else { return }
        let now = Date()
        let ran = Set(history.all().map(\.jobID))
        var notices = runs.compactMap { NoticeContent.run($0, policy: policy) }
        for check in checks {
            switch check {
            case .recorded(let record):
                if let n = NoticeContent.health(record, policy: policy, jobHasRun: ran.contains(record.jobID)) { notices.append(n) }
            case .canceled(let stopped):
                if let n = NoticeContent.stopped(stopped, policy: policy) { notices.append(n) }
            }
        }
        notices += pressure.compactMap { NoticeContent.storage($0, policy: policy, now: now) }
        // overdue jobs, from the ledger the app posts from too
        let ledger = AlertThrottle.overdueLocal()
        let overdue = overdueAlerts(jobs: store.load().jobs, history: history, lastRun: store.load().lastRun,
                                    now: now, throttle: ledger)
        guard !notices.isEmpty || !overdue.isEmpty,
              AgentNotices.shouldPost(appOpen: appOpen, authorization: await LocalNotice.authorization()) else { return }
        for notice in notices { await LocalNotice.post(notice) }
        for alert in overdue {
            guard let notice = NoticeContent.overdue(alert.payload, subject: alert.subject, policy: policy, now: now),
                  let claim = ledger.claim(alert.subject, now: now) else { continue }
            if !(await LocalNotice.post(notice)) { ledger.release(claim) }
        }
    }

    /// whether the app is open: another process of this bundle, as macOS lists apps
    private static func appIsOpen() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let me = getpid()
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { $0.processIdentifier != me }
    }

    /// Scheduled jobs gone late, as alerts (see AlertPolicy.overdueAlerts), each with
    /// the subject to record in `throttle` once it has been delivered, so one that
    /// couldn't go is tried again at the next pass.
    private static func overdueAlerts(jobs: [BackupJob], history: RunHistoryStore, lastRun: [String: Date],
                                      now: Date, throttle: AlertThrottle) -> [(payload: AlertPolicy.Payload, subject: String)] {
        let all = history.all()
        var latest: [String: RunRecord] = [:]
        for r in all where latest[r.jobID] == nil { latest[r.jobID] = r }
        var unrecorded: [String: Date] = [:]
        for job in jobs {
            unrecorded[job.id] = ProtectionVerdict.unrecordedRun(lastRun: lastRun[job.id], records: all.filter { $0.jobID == job.id })
        }
        return AlertPolicy.overdueAlerts(jobs: jobs, latest: latest, lastGood: history.lastGood(), unrecordedRuns: unrecorded,
                                         now: now, throttle: throttle)
    }

    /// the records of the runs this pass made, added as each finishes
    private final class Finished: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [RunRecord] = []
        var records: [RunRecord] { lock.lock(); defer { lock.unlock() }; return list }
        func add(_ record: RunRecord) { lock.lock(); list.append(record); lock.unlock() }
    }

    /// Ask the helper to clean up after crashed runs before any run of ours starts.
    /// Bounded: if the helper doesn't answer, the backups matter more than the
    /// tidying. Giving up means giving up: a late answer must not start a reconcile
    /// alongside the runs that follow (the helper would still keep what they own,
    /// but that is the second guard, not the first).
    private static func cleanUpLeftovers(jobIDs: [String], locks: RunLocks) {
        // no helper set up: nothing could answer, so don't wait a minute to find out
        guard SMAppService.daemon(plistName: CryoframeHelper.daemonPlistName).status == .enabled else { return }
        let wanted = StillWanted()
        let helper = XPCPrivilegedHelper()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            _ = await LeftoverCleanup.run(helper: helper, locks: locks, jobIDs: jobIDs,
                                          stillWanted: { wanted.value })
            done.signal()
        }
        if done.wait(timeout: .now() + 60) == .timedOut { wanted.giveUp() }
        helper.invalidate()                 // fails any call still waiting for an answer
    }

    private final class StillWanted: @unchecked Sendable {
        private let lock = NSLock()
        private var wanted = true
        var value: Bool { lock.lock(); defer { lock.unlock() }; return wanted }
        func giveUp() { lock.lock(); wanted = false; lock.unlock() }
    }
}
