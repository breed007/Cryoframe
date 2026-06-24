//
//  AgentMain.swift
//  Cryoframe (app) — headless scheduled run
//
//  Launched periodically by the LaunchAgent. Loads the job store, runs any due
//  jobs through the same pipeline the GUI uses (XPC helper + FDA reader), then
//  exits. Errors are swallowed per-job so one bad job doesn't block the rest.
//

import Foundation
import CryoframeKit

enum AgentMain {
    static func run() {
        let store = JobStore.standard()
        let due = Scheduler().dueJobs(store.load(), now: Date())
        guard !due.isEmpty else { exit(0) }

        let runner = JobRunner(
            targeted: TargetedBackupRunner(backup: BackupRunner(helper: XPCPrivilegedHelper())),
            detector: WorkspaceProcessDetector(),
            store: store)

        let group = DispatchGroup()
        for job in due {
            group.enter()
            Task {
                _ = try? await runner.run(job, ownerUID: getuid(), now: Date())
                group.leave()
            }
        }
        group.wait()
        exit(0)
    }
}
