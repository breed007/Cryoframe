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
        TransferResumer.resumeAll(store: PendingTransferStore.standard(), locks: locks)   // finish interrupted transfers first

        // a due job the app is running right now is the app's run: it records the
        // result and moves the schedule on. Not due here, and not a deferral either.
        // A chore holding the lock (a tidy, a transfer finishing) isn't a run; the
        // acquire below waits it out or records why the job waited.
        let running = locks.runningJobIDs(among: store.load().jobs.map(\.id))
        var due = Scheduler().dueJobs(store.load(), now: Date()).filter { !running.contains($0.id) }
        var alerts: [RunRecord] = []      // deferrals, delivered once the run loop is done

        // Unattended work on a dying laptop battery is how a Mac ends up flat. Hold
        // the run for the next hourly check (it may be plugged in by then), and
        // RECORD the deferral — a backup that quietly doesn't happen is the whole
        // failure mode this app exists to prevent. Manual runs never come through here.
        let power = SystemPowerSource().current()
        let floor = TransferConfig.batteryFloorPercent()
        if floor > 0, !due.isEmpty,
           BatteryPolicy.shouldDeferScheduledRun(power, minimumPercent: floor) {
            let reason = BatteryPolicy.deferralReason(power)
            let historyStore = RunHistoryStore.standard()
            let now = Date()
            for job in due {
                let record = RunRecord.make(job: job, outcome: .deferred(reason),
                                            startedAt: now, finishedAt: now, trigger: "scheduled")
                historyStore.append(record)
                alerts.append(record)
            }
            due = []
        }

        let healthDue = HealthSchedule.isDue(now: Date())
        let sleepGuard = SleepGuard()
        if !due.isEmpty || healthDue { sleepGuard.begin() }     // don't idle-sleep mid scheduled work
        if !due.isEmpty {
            let executor = TransferConfig.makeExecutor(detector: WorkspaceProcessDetector(), store: store)
            let registry = ContentTypeRegistry.withOverrides(LibraryOverrides.load())
            let historyStore = RunHistoryStore.standard()       // so scheduled runs leave a record
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
                    if let reason = holder.deferralReason {
                        let now = Date()
                        let record = RunRecord.make(job: job, outcome: .deferred(reason),
                                                    startedAt: now, finishedAt: now, trigger: "scheduled")
                        historyStore.append(record)
                        alerts.append(record)
                    }
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
        sleepGuard.end()

        // Send everything before exiting. This process is the ONLY thing that will
        // tell you a scheduled backup failed while you weren't at the Mac: the app
        // marks every record that predates its launch as already-seen, so a failure
        // it wasn't running for is never announced later.
        // re-point the optional pmset wake at the next due job (lastRun may have changed).
        let sem = DispatchSemaphore(value: 0)
        Task {
            for record in alerts { await RemoteAlert.deliver(for: record) }
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
