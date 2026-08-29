//
//  RetentionTests.swift
//  CryoframeKitTests
//
//  The retention pruning logic — keep-last-N and grandfather-father-son.
//

import Testing
import Foundation
@testable import CryoframeKit

private let cal = Calendar(identifier: .gregorian)
private func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
    cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
}

@Test func versionStampRoundTrips() {
    let date = day(2026, 6, 25, 14)
    let s = VersionStamp.string(date)
    #expect(VersionStamp.date(s) != nil)
    #expect(s.count == "yyyy-MM-dd-HHmmss".count)
    #expect(VersionStamp.date("not-a-stamp") == nil)
    // lexical order matches chronological order
    #expect(VersionStamp.string(day(2026, 6, 24)) < VersionStamp.string(day(2026, 6, 25)))
}

@Test func keepAllPrunesNothing() {
    let vs = [day(2026, 6, 25), day(2026, 6, 24), day(2026, 6, 23)]
    #expect(retentionPrune(vs, policy: .keepAll).isEmpty)
}

@Test func keepLastPrunesOldestBeyondN() {
    let vs = [day(2026, 6, 21), day(2026, 6, 22), day(2026, 6, 23), day(2026, 6, 24), day(2026, 6, 25)]
    let pruned = retentionPrune(vs, policy: .keepLast(3))
    #expect(pruned == Set([day(2026, 6, 21), day(2026, 6, 22)]))     // keep the 3 newest
}

@Test func keepLastOneKeepsOnlyTheNewest() {
    let vs = [day(2026, 6, 24), day(2026, 6, 25)]
    #expect(retentionPrune(vs, policy: .keepLast(1)) == Set([day(2026, 6, 24)]))
}

@Test func gfsKeepsNewestPerDayWeekMonth() {
    // two same-day versions, a previous month, and a third month
    let vs = [day(2026, 6, 25, 9), day(2026, 6, 25, 18), day(2026, 6, 24),
              day(2026, 5, 15), day(2026, 4, 10)]
    let pruned = retentionPrune(vs, policy: .gfs(daily: 1, weekly: 0, monthly: 2))
    // daily(1): newest day → Jun 25 18:00. monthly(2): June→Jun 25 18:00, May→May 15.
    #expect(pruned.contains(day(2026, 6, 25, 9)))    // older same-day copy
    #expect(pruned.contains(day(2026, 6, 24)))       // not newest of its day, beyond daily limit
    #expect(pruned.contains(day(2026, 4, 10)))       // 3rd month, beyond monthly limit
    #expect(!pruned.contains(day(2026, 6, 25, 18)))  // newest overall, kept
    #expect(!pruned.contains(day(2026, 5, 15)))      // newest of May, kept by monthly
}

@Test func gfsWeeklyKeepsOnePerWeek() {
    let vs = [day(2026, 6, 25), day(2026, 6, 24), day(2026, 6, 17), day(2026, 6, 10)]   // 3 distinct weeks
    let pruned = retentionPrune(vs, policy: .gfs(daily: 0, weekly: 2, monthly: 0))
    // weekly(2): newest two weeks → week of Jun 25 (newest = Jun 25) and week of Jun 17.
    #expect(!pruned.contains(day(2026, 6, 25)))
    #expect(!pruned.contains(day(2026, 6, 17)))
    #expect(pruned.contains(day(2026, 6, 24)))       // same week as Jun 25, not newest
    #expect(pruned.contains(day(2026, 6, 10)))       // 3rd week, beyond limit
}

// MARK: - the floor: no policy may select every version

// A retention setting that selects nothing means "delete every backup", and the
// engine carries the result straight into removeItem — including on the version it
// has just finished writing. Both of these were reachable: keepLast(0) from a
// hand-edited jobs.json, and a GFS with all three buckets at zero straight from the
// steppers in the UI.
@Test func noPolicyCanPruneEveryVersion() {
    let versions = (1...30).map { day(2026, 7, $0) }
    let policies: [RetentionPolicy] = [
        .keepLast(0), .keepLast(-1),
        .gfs(daily: 0, weekly: 0, monthly: 0),
        .gfs(daily: -1, weekly: -1, monthly: -1),
    ]
    for p in policies {
        let doomed = retentionPrune(versions, policy: p, calendar: cal)
        #expect(doomed.count < versions.count, "\(p) selected every version for deletion")
        #expect(!doomed.contains(day(2026, 7, 30)), "\(p) selected the newest version")
    }
}

@Test func theFloorKeepsExactlyTheNewestAndNothingElse() {
    // degrading to "keep the newest" must not quietly keep more than that
    let versions = (1...5).map { day(2026, 7, $0) }
    let doomed = retentionPrune(versions, policy: .gfs(daily: 0, weekly: 0, monthly: 0), calendar: cal)
    #expect(versions.count - doomed.count == 1)
    #expect(!doomed.contains(day(2026, 7, 5)))
}

@Test func theFloorDoesNotDisturbAWorkingPolicy() {
    // the newest is already kept by every sane policy, so the floor must be a no-op
    let versions = (1...30).map { day(2026, 7, $0) }
    #expect(retentionPrune(versions, policy: .keepLast(7), calendar: cal).count == 23)
    #expect(retentionPrune(versions, policy: .keepAll, calendar: cal).isEmpty)
    let gfs = retentionPrune(versions, policy: .gfs(daily: 7, weekly: 4, monthly: 6), calendar: cal)
    #expect(versions.count - gfs.count == 9)
}

@Test func aSingleVersionIsNeverPruned() {
    // the first run of a job: one version exists, and it is the one just written
    let only = [day(2026, 7, 1)]
    for p: RetentionPolicy in [.keepLast(0), .keepLast(1), .gfs(daily: 0, weekly: 0, monthly: 0)] {
        #expect(retentionPrune(only, policy: p, calendar: cal).isEmpty, "\(p) pruned the only version there is")
    }
}
