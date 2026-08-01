//
//  AgentMain.swift
//  Cryoframe (app) — headless scheduled run
//
//  Launched periodically by the LaunchAgent. Resumes interrupted transfers,
//  then runs any due jobs (up to the concurrency limit) through the same
//  JobExecutor the GUI uses, then exits.
//

import Foundation
import CryoframeKit

enum AgentMain {
    static func run() {
        let store = JobStore.standard()
        TransferResumer.resumeAll(store: PendingTransferStore.standard())   // finish interrupted transfers first

        var due = Scheduler().dueJobs(store.load(), now: Date())

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
                historyStore.append(RunRecord.make(job: job, outcome: .deferred(reason),
                                                   startedAt: now, finishedAt: now, trigger: "scheduled"))
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
                group.enter()
                let resolved = job.resolvingLibraries(in: registry)
                Task {
                    let started = Date()
                    do {
                        let outcome = try await executor.run(resolved, ownerUID: getuid(), now: Date())
                        historyStore.append(RunRecord.make(job: job, outcome: outcome,
                                                           startedAt: started, finishedAt: Date(), trigger: "scheduled"))
                    } catch {
                        historyStore.append(RunRecord.failure(job: job, error: error.localizedDescription,
                                                              startedAt: started, finishedAt: Date(), trigger: "scheduled"))
                    }
                    limit.signal()
                    group.leave()
                }
            }
            group.wait()
        }

        HealthSchedule.runIfDue(store: store, now: Date())     // re-verify cold archives if due
        sleepGuard.end()

        // re-point the optional pmset wake at the next due job (lastRun may have changed).
        let sem = DispatchSemaphore(value: 0)
        Task { await WakeScheduler.arm(store: store); sem.signal() }
        sem.wait()
        exit(0)
    }
}
