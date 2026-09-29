//
//  LeftoverCleanup.swift
//  CryoframeKit
//
//  When the app launches and when the scheduled agent starts, ask the helper to
//  clean up snapshot mounts and snapshots a crashed run left behind. The helper
//  itself keeps anything whose owning process is still alive; this adds two checks
//  on the calling side, so a mistake in either layer alone can't tear down a run.
//

import Foundation
import CryoframeShared

public enum LeftoverCleanup {
    /// the first helper whose reconcile keeps what live processes own. An older one
    /// unmounts and deletes everything, running or not, so it is never asked.
    public static let minimumHelperVersion = "1.6.0"

    public enum Outcome: Equatable, Sendable {
        case cleaned(ReconcileReport)
        case skippedRunInProgress(String)     // a job id whose run lock is held
        case skippedOldHelper(String)         // the helper's reported version
        case skippedLocksUnreadable(String)   // can't tell whether anything is running
        case abandoned                        // the caller stopped waiting before it was asked
        case failed(String)
    }

    /// - Parameters:
    ///   - jobIDs: every job this user has; if any is running, in this process or
    ///     another, cleanup waits for a later launch.
    ///   - stillWanted: asked just before reconcile. A caller that stops waiting
    ///     (the agent, after a minute) answers false from then on, so a helper that
    ///     answers late never starts a reconcile alongside the runs that followed.
    public static func run(helper: PrivilegedHelper, locks: RunLocks, jobIDs: [String],
                           stillWanted: @escaping @Sendable () -> Bool = { true }) async -> Outcome {
        if let skip = gate(locks: locks, jobIDs: jobIDs) { return skip }
        do {
            let info = try await helper.handshake()
            guard isAtLeast(info.version, minimumHelperVersion) else { return .skippedOldHelper(info.version) }
            // the handshake can take a while (a helper being launched); a run may
            // have started meanwhile, or the caller given up. Look again.
            guard stillWanted() else { return .abandoned }
            if let skip = gate(locks: locks, jobIDs: jobIDs) { return skip }
            return .cleaned(try await helper.reconcile())
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// nil when cleanup may go ahead. Fails closed: a lock it can't read might be a
    /// run's, and this check exists so one mistake elsewhere can't tear a run down.
    static func gate(locks: RunLocks, jobIDs: [String]) -> Outcome? {
        for id in jobIDs {
            switch locks.look(id) {
            case .free: continue
            case .held: return .skippedRunInProgress(id)
            case .unreadable(let why): return .skippedLocksUnreadable(why)
            }
        }
        return nil
    }

    /// dotted-number comparison; anything that isn't one counts as older.
    static func isAtLeast(_ version: String, _ minimum: String) -> Bool {
        func parts(_ s: String) -> [Int]? {
            let p = s.split(separator: ".").map { Int($0) }
            return p.isEmpty || p.contains(nil) ? nil : p.compactMap { $0 }
        }
        guard let v = parts(version), let m = parts(minimum) else { return false }
        for i in 0..<max(v.count, m.count) {
            let a = i < v.count ? v[i] : 0, b = i < m.count ? m[i] : 0
            if a != b { return a > b }
        }
        return true
    }
}
