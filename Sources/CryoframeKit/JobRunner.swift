//
//  JobRunner.swift
//  CryoframeKit
//
//  Runs one job: apply the run policy (defer if the owning app is open and the
//  job says so), otherwise preflight the target and back up. Records the run.
//

import Foundation
import CryoframeShared

public enum JobRunResult: Sendable {
    case completed(outcome: BackupOutcome, warning: String?)
    case deferred(String)
}

public struct JobRunner: Sendable {
    let targeted: TargetedBackupRunner
    let detector: ProcessDetector
    let store: JobStore?

    public init(targeted: TargetedBackupRunner, detector: ProcessDetector, store: JobStore? = nil) {
        self.targeted = targeted; self.detector = detector; self.store = store
    }

    public func run(_ job: BackupJob, ownerUID: uid_t, now: Date,
                    onStage: @escaping @Sendable (BackupStage) -> Void = { _ in }) async throws -> JobRunResult {
        switch decide(job.runPolicy, type: job.contentType, detector: detector) {
        case .deferred(let reason):
            return .deferred(reason)                          // owning app open + deferIfRunning
        case let decision:
            let outcome = try await targeted.run(job.contentType, format: job.format, to: job.target,
                                                 ownerUID: ownerUID, verification: job.verification, onStage: onStage)
            store?.recordRun(id: job.id, at: now)
            return .completed(outcome: outcome, warning: decision.warning)
        }
    }
}
