//
//  ProtectionVerdict.swift
//  CryoframeKit
//
//  One answer to "am I protected?", computed from the jobs, their latest runs and
//  their latest archive checks. The dashboard hero, the menu-bar glyph and the
//  menu's status line all show this one verdict, so they can never disagree. The
//  app adds only the color.
//

import Foundation

public struct ProtectionVerdict: Sendable, Equatable {
    public enum Level: Sendable, Equatable { case protected, attention, critical, idle }

    public var level: Level
    public var title: String
    public var subtitle: String
    public var glyph: String

    public init(level: Level, title: String, subtitle: String, glyph: String) {
        self.level = level; self.title = title; self.subtitle = subtitle; self.glyph = glyph
    }

    /// - Parameters:
    ///   - lastRecords: the latest run per job id.
    ///   - lastHealth: the latest archive check per job id.
    ///   - runningCount: how many jobs are running right now.
    public static func compute(jobs: [BackupJob], lastRecords: [String: RunRecord],
                               lastHealth: [String: HealthRecord], runningCount: Int) -> ProtectionVerdict {
        guard !jobs.isEmpty else {
            return .init(level: .idle, title: "No backup jobs yet",
                         subtitle: "Create a job to start protecting a library.",
                         glyph: "plus.circle")
        }
        if runningCount > 0 {
            let n = runningCount
            return .init(level: .idle, title: "Backing up…",
                         subtitle: "\(n) \(n == 1 ? "job is" : "jobs are") running right now.",
                         glyph: "arrow.triangle.2.circlepath")
        }
        let failed = jobs.filter { lastRecords[$0.id]?.outcome == .failed }
        let partial = jobs.filter { lastRecords[$0.id]?.outcome == .partial }
        let healthBad = jobs.filter { if let h = lastHealth[$0.id] { return !h.passed } else { return false } }
        let neverRan = jobs.filter { lastRecords[$0.id] == nil }
        // dedup by id — a job can be BOTH partial and health-failed, so counting the
        // filters separately would subtract it twice and skew "X of N healthy".
        let problemIDs = Set(failed.map(\.id)).union(partial.map(\.id)).union(healthBad.map(\.id)).union(neverRan.map(\.id))
        let healthy = jobs.count - problemIDs.count

        if let f = failed.first {
            return .init(level: .critical,
                         title: failed.count == 1 ? "1 backup failed" : "\(failed.count) backups failed",
                         subtitle: "\(f.name) didn't finish — open it to see why. \(healthy) of \(jobs.count) jobs are healthy.",
                         glyph: "xmark.octagon.fill")
        }
        if let b = (partial.first ?? healthBad.first) {
            let why = partial.contains(where: { $0.id == b.id }) ? "finished as a partial backup" : "failed an archive check"
            return .init(level: .attention, title: "1 job needs attention",
                         subtitle: "\(b.name) \(why) — open it to fix. \(healthy) of \(jobs.count) jobs are fully healthy.",
                         glyph: "exclamationmark.triangle.fill")
        }
        if !neverRan.isEmpty && healthy == 0 {
            return .init(level: .idle, title: "Ready to back up",
                         subtitle: neverRan.count == 1 ? "Your job hasn't run yet — press Run now, or wait for its schedule."
                                                       : "\(neverRan.count) jobs haven't run yet.",
                         glyph: "clock.badge.checkmark")
        }
        let extra = neverRan.isEmpty ? "" : " \(neverRan.count) haven't run yet."
        return .init(level: .protected, title: "You're protected",
                     subtitle: "\(healthy) \(healthy == 1 ? "job" : "jobs") healthy · \(lastBackupText(jobs: jobs, lastRecords: lastRecords).lowercased()) · nothing needs your attention.\(extra)",
                     glyph: "checkmark.shield.fill")
    }

    // MARK: - shared derived values

    /// the newest run that left a usable copy behind, across all jobs.
    public static func lastSuccessfulRecord(jobs: [BackupJob], lastRecords: [String: RunRecord]) -> RunRecord? {
        jobs.compactMap { lastRecords[$0.id] }
            .filter { [.verified, .completed, .partial].contains($0.outcome) }
            .max(by: { $0.finishedAt < $1.finishedAt })
    }

    public static func lastSuccess(jobs: [BackupJob], lastRecords: [String: RunRecord]) -> Date? {
        lastSuccessfulRecord(jobs: jobs, lastRecords: lastRecords)?.finishedAt
    }

    public static func lastBackupText(jobs: [BackupJob], lastRecords: [String: RunRecord]) -> String {
        guard let d = lastSuccess(jobs: jobs, lastRecords: lastRecords) else { return "Never" }
        return d.formatted(.relative(presentation: .named)).localizedCapitalized
    }

    /// distinct libraries across all jobs, by name.
    public static func libraryCount(_ jobs: [BackupJob]) -> Int {
        Set(jobs.flatMap { $0.libraries.map(\.displayName) }).count
    }

    /// distinct destinations across all jobs, by path.
    public static func destinationCount(_ jobs: [BackupJob]) -> Int {
        Set(jobs.flatMap { $0.targets.map(\.destinationDir.path) }).count
    }
}
