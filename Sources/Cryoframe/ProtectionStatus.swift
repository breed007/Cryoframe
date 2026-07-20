//
//  ProtectionStatus.swift
//  Cryoframe (app)
//
//  One answer to "am I protected?", computed once and reused everywhere it's shown —
//  the dashboard hero, the menu-bar glyph, and the menu's status line. Before this,
//  the menu bar had its own rules and could show a checkmark while the dashboard
//  said "needs attention" (it ignored failed archive checks and never-ran jobs).
//

import SwiftUI
import CryoframeKit

struct ProtectionStatus {
    enum Level { case protected, attention, critical, idle }

    var level: Level
    var title: String
    var subtitle: String
    var glyph: String
    var tint: Color

    /// short form for the menu bar, where there's no room for the subtitle.
    var menuLine: String { title }

    @MainActor
    static func compute(_ model: AppModel) -> ProtectionStatus {
        let jobs = model.jobs
        guard !jobs.isEmpty else {
            return .init(level: .idle, title: "No backup jobs yet",
                         subtitle: "Create a job to start protecting a library.",
                         glyph: "plus.circle", tint: .cryoAccent)
        }
        if !model.runningJobIDs.isEmpty {
            let n = model.runningJobIDs.count
            return .init(level: .idle, title: "Backing up…",
                         subtitle: "\(n) \(n == 1 ? "job is" : "jobs are") running right now.",
                         glyph: "arrow.triangle.2.circlepath", tint: .cryoAccent)
        }
        let failed = jobs.filter { model.lastRecords[$0.id]?.outcome == .failed }
        let partial = jobs.filter { model.lastRecords[$0.id]?.outcome == .partial }
        let healthBad = jobs.filter { if let h = model.lastHealth[$0.id] { return !h.passed } else { return false } }
        let neverRan = jobs.filter { model.lastRecords[$0.id] == nil }
        // dedup by id — a job can be BOTH partial and health-failed, so counting the
        // filters separately would subtract it twice and skew "X of N healthy".
        let problemIDs = Set(failed.map(\.id)).union(partial.map(\.id)).union(healthBad.map(\.id)).union(neverRan.map(\.id))
        let healthy = jobs.count - problemIDs.count

        if let f = failed.first {
            return .init(level: .critical,
                         title: failed.count == 1 ? "1 backup failed" : "\(failed.count) backups failed",
                         subtitle: "\(f.name) didn't finish — open it to see why. \(healthy) of \(jobs.count) jobs are healthy.",
                         glyph: "xmark.octagon.fill", tint: .cryoCrit)
        }
        if let b = (partial.first ?? healthBad.first) {
            let why = partial.contains(where: { $0.id == b.id }) ? "finished as a partial backup" : "failed an archive check"
            return .init(level: .attention, title: "1 job needs attention",
                         subtitle: "\(b.name) \(why) — open it to fix. \(healthy) of \(jobs.count) jobs are fully healthy.",
                         glyph: "exclamationmark.triangle.fill", tint: .cryoWarn)
        }
        if !neverRan.isEmpty && healthy == 0 {
            return .init(level: .idle, title: "Ready to back up",
                         subtitle: neverRan.count == 1 ? "Your job hasn't run yet — press Run now, or wait for its schedule."
                                                       : "\(neverRan.count) jobs haven't run yet.",
                         glyph: "clock.badge.checkmark", tint: .cryoAccent)
        }
        let extra = neverRan.isEmpty ? "" : " \(neverRan.count) haven't run yet."
        return .init(level: .protected, title: "You're protected",
                     subtitle: "\(healthy) \(healthy == 1 ? "job" : "jobs") healthy · \(lastBackupText(model).lowercased()) · nothing needs your attention.\(extra)",
                     glyph: "checkmark.shield.fill", tint: .cryoGood)
    }

    // MARK: - shared derived values

    @MainActor
    static func lastSuccess(_ model: AppModel) -> Date? {
        model.jobs.compactMap { model.lastRecords[$0.id] }
            .filter { [.verified, .completed, .partial].contains($0.outcome) }
            .map(\.finishedAt).max()
    }

    @MainActor
    static func lastBackupText(_ model: AppModel) -> String {
        guard let d = lastSuccess(model) else { return "Never" }
        return d.formatted(.relative(presentation: .named)).localizedCapitalized
    }
}
