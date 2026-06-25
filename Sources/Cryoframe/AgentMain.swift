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

        let due = Scheduler().dueJobs(store.load(), now: Date())
        guard !due.isEmpty else { exit(0) }

        let executor = TransferConfig.makeExecutor(detector: WorkspaceProcessDetector(), store: store)
        let registry = ContentTypeRegistry.withOverrides(LibraryOverrides.load())
        let limit = DispatchSemaphore(value: TransferConfig.maxConcurrentJobs())
        let group = DispatchGroup()

        for job in due {
            limit.wait()                                    // bound concurrency
            group.enter()
            let resolved = job.resolvingLibraries(in: registry)
            Task {
                _ = try? await executor.run(resolved, ownerUID: getuid(), now: Date())
                limit.signal()
                group.leave()
            }
        }
        group.wait()
        exit(0)
    }
}
