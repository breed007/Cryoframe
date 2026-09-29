//
//  ProtectionStatus.swift
//  Cryoframe (app)
//
//  One answer to "am I protected?", computed once and reused everywhere it's shown —
//  the dashboard hero, the menu-bar glyph, and the menu's status line. Before this,
//  the menu bar had its own rules and could show a checkmark while the dashboard
//  said "needs attention" (it ignored failed archive checks and never-ran jobs).
//  The verdict itself is CryoframeKit's ProtectionVerdict; this adds the color.
//

import SwiftUI
import CryoframeKit

struct ProtectionStatus {
    typealias Level = ProtectionVerdict.Level

    var level: Level
    var title: String
    var subtitle: String
    var glyph: String
    var tint: Color

    /// short form for the menu bar, where there's no room for the subtitle.
    var menuLine: String { title }

    @MainActor
    static func compute(_ model: AppModel) -> ProtectionStatus {
        let v = ProtectionVerdict.compute(jobs: model.jobs, lastRecords: model.lastRecords,
                                          lastHealth: model.lastHealth, runningCount: model.backingUpJobIDs.count,
                                          lastGood: model.lastGood, now: model.clock, scheduleOn: model.scheduleOn)
        return ProtectionStatus(level: v.level, title: v.title, subtitle: v.subtitle, glyph: v.glyph, tint: tint(v.level))
    }

    static func tint(_ level: Level) -> Color {
        switch level {
        case .protected: .cryoGood
        case .attention: .cryoWarn
        case .critical:  .cryoCrit
        case .idle:      .cryoAccent
        }
    }

    // MARK: - shared derived values

    @MainActor
    static func lastBackupText(_ model: AppModel) -> String {
        ProtectionVerdict.lastBackupText(jobs: model.jobs, lastRecords: model.lastRecords)
    }
}
