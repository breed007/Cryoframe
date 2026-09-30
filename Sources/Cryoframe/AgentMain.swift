//
//  AgentMain.swift
//  Cryoframe (app) — headless scheduled run
//
//  Launched periodically by the LaunchAgent. Cleans up after crashed runs,
//  resumes interrupted transfers, then runs any due jobs (up to the concurrency
//  limit) through the same JobExecutor the GUI uses, then exits. Every run holds
//  its job's run lock, so a job the app is already running is left to the app.
//

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

        // a due job the app is running right now is the app's run: it records the
        // result and moves the schedule on. Not due here, and not a deferral either.
        // A chore holding the lock (a tidy, a transfer finishing) isn't a run; the
        // acquire below waits it out or records why the job waited. A job whose
        // transfer was just stopped from the app waits for the next pass.
        let running = locks.runningJobIDs(among: store.load().jobs.map(\.id))
        var due = Scheduler().jobsToStart(store.load(), now: Date(), running: running,
                                          stoppedThisPass: resumes.stoppedJobIDs)
        var alerts: [RunRecord] = []      // failures to start, delivered once the run loop is done
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
                let control = RunControl()
                lease.onStopRequest { control.cancel() }        // Stop, pressed in the app
                group.enter()
                let resolved = job.resolvingLibraries(in: registry)
                Task {
                    let started = Date()
                    let record: RunRecord
                    do {
                        let outcome = try await executor.run(resolved, ownerUID: getuid(), now: Date(), control: control)
                        record = RunRecord.make(job: job, outcome: outcome,
                                                startedAt: started, finishedAt: Date(), trigger: "scheduled")
                    } catch {
                        record = RunRecord.failure(job: job, error: error.localizedDescription,
                                                   startedAt: started, finishedAt: Date(), trigger: "scheduled")
                    }
                    historyStore.append(record)
                    lease.release()                                 // the run is over once it's recorded
                    await RemoteAlert.deliver(for: record)          // nobody is watching the screen
                    limit.signal()
                    group.leave()
                }
            }
            group.wait()
        }

        var healthRecords = HealthSchedule.runIfDue(store: store, now: Date())   // re-verify cold archives if due
        healthRecords += RehearsalSchedule.runIfDue(store: store, now: Date())   // and prove a recovery would work

        // A destination that fills up doesn't fail loudly, it just stops working —
        // and on an unattended Mac nobody sees the dashboard say so. Warn while
        // there's still room to act. Only once per destination per day, so a full
        // drive doesn't turn into an hourly alarm.
        let pressure = StoragePressure.findings(
            storage: StorageReporter.report(store.load().jobs),
            retention: Dictionary(uniqueKeysWithValues: store.load().jobs.map { ($0.id, $0.retention) })
        ).filter { $0.kind == .tight && StorageNag.shouldWarn($0.destination, now: Date()) }
        let overdue = overdueNotices(jobs: store.load().jobs, history: historyStore, lastRun: store.load().lastRun, now: Date())
        sleepGuard.end()

        // Send everything before exiting. This process is the ONLY thing that will
        // tell you a scheduled backup failed while you weren't at the Mac: the app
        // marks every record that predates its launch as already-seen, so a failure
        // it wasn't running for is never announced later.
        // re-point the optional pmset wake at the next due job (lastRun may have changed).
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
            for record in healthRecords { await RemoteAlert.deliverHealth(for: record) }
            for finding in pressure {
                await RemoteAlert.deliverStorage(for: finding)
                StorageNag.recordWarned(finding.destination, now: Date())
            }
            await WakeScheduler.arm(store: store)
            sem.signal()
        }
        sem.wait()
        exit(0)
    }

    /// Scheduled jobs gone late, as alerts (see AlertPolicy.overdueAlerts), each with
    /// what to call once it has been delivered, so one that couldn't go is tried again
    /// at the next pass.
    private static func overdueNotices(jobs: [BackupJob], history: RunHistoryStore, lastRun: [String: Date],
                                       now: Date) -> [(AlertPolicy.Payload, @Sendable () -> Void)] {
        let throttle = AlertThrottle(key: AlertThrottle.overdueRemoteKey)
        let all = history.all()
        var latest: [String: RunRecord] = [:]
        for r in all where latest[r.jobID] == nil { latest[r.jobID] = r }
        var unrecorded: [String: Date] = [:]
        for job in jobs {
            unrecorded[job.id] = ProtectionVerdict.unrecordedRun(lastRun: lastRun[job.id], records: all.filter { $0.jobID == job.id })
        }
        return AlertPolicy.overdueAlerts(jobs: jobs, latest: latest, lastGood: history.lastGood(), unrecordedRuns: unrecorded,
                                         now: now, throttle: throttle)
            .map { alert in (alert.payload, { throttle.recordSent(alert.subject, now: now) }) }
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
