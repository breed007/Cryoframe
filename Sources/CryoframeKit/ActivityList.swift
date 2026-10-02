//
//  ActivityList.swift
//  CryoframeKit
//
//  What the Activity list at the bottom of the main window shows when the app
//  starts. Clearing the list only moves a "cleared at" time: runs that finished
//  before it stop appearing there. The run history itself is never touched, because
//  drive rotation evidence, the destination health trend, the last-backup time,
//  overdue alerts, and known-good retention all read it.
//

import Foundation

public enum ActivityList {
    /// The runs to seed the list with at launch: those that finished after
    /// `clearedAt` (all of them when it is nil), newest first, at most `limit`.
    /// `records` is the history, newest first.
    public static func seed(_ records: [RunRecord], clearedAt: Date?, limit: Int) -> [RunRecord] {
        let shown = clearedAt.map { cut in records.filter { $0.finishedAt > cut } } ?? records
        return Array(shown.prefix(max(0, limit)))
    }
}
