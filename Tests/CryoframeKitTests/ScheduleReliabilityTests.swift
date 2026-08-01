//
//  ScheduleReliabilityTests.swift
//  CryoframeKitTests
//
//  Two unattended-reliability guarantees:
//
//  1. A run missed while the Mac was asleep or shut down is CAUGHT UP, not skipped
//     to the next window. This already falls out of `next <= now` plus the agent's
//     hourly wake, and these tests exist so it keeps falling out.
//  2. A scheduled run waits when the battery is low — but only when we're certain,
//     because a backup that silently never happens is the worse failure.
//

import Testing
import Foundation
@testable import CryoframeKit

private let cal = Calendar(identifier: .gregorian)
private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    cal.date(from: DateComponents(year: 2026, month: 7, day: day, hour: hour, minute: minute))!
}
private let target = Target.localVolume(id: "t", name: "Backup", dir: URL(fileURLWithPath: "/Volumes/Backup"))

private func job(_ freq: BackupFrequency, created: Date, enabled: Bool = true) -> BackupJob {
    BackupJob(id: "j", name: "Nightly", libraries: [], targets: [target], format: .sealedDMG,
              frequency: freq, verification: .checksumOnly, runPolicy: .proceed,
              enabled: enabled, createdAt: created)
}

// MARK: - catch-up after sleep

@Test func missedNightlyRunIsCaughtUpAfterWake() {
    // ran Monday 02:00, Mac asleep through Tuesday 02:00, wakes Tuesday 09:00.
    let j = job(.daily(hour: 2, minute: 0), created: at(20, 2))
    let s = Scheduler()
    #expect(s.isDue(j, lastRun: at(20, 2), now: at(21, 9), calendar: cal))
}

@Test func nightlyRunIsNotDueBeforeItsWindow() {
    let j = job(.daily(hour: 2, minute: 0), created: at(20, 2))
    // 20:00 the same evening — the next 02:00 hasn't arrived.
    #expect(!Scheduler().isDue(j, lastRun: at(20, 2), now: at(20, 20), calendar: cal))
}

@Test func aWeekOfDowntimeStillOnlyOwesOneRun() {
    // the point of catch-up is one run when you get back, not seven queued.
    let j = job(.daily(hour: 2, minute: 0), created: at(20, 2))
    let state = ScheduleState(jobs: [j], lastRun: [j.id: at(20, 2)])
    let due = Scheduler().dueJobs(state, now: at(27, 11), calendar: cal)
    #expect(due.count == 1)
}

@Test func everyHoursCatchesUpAfterLongDowntime() {
    let j = job(.everyHours(6), created: at(20, 0))
    let s = Scheduler()
    #expect(s.isDue(j, lastRun: at(20, 0), now: at(23, 0), calendar: cal))   // days later
    #expect(!s.isDue(j, lastRun: at(20, 0), now: at(20, 3), calendar: cal))  // only 3h later
}

@Test func neverRunJobFallsBackToCreationDate() {
    let j = job(.daily(hour: 2, minute: 0), created: at(20, 12))
    // created midday on the 20th; by 03:00 on the 21st its first window has passed.
    #expect(Scheduler().isDue(j, lastRun: nil, now: at(21, 3), calendar: cal))
}

@Test func disabledJobIsNeverDue() {
    let j = job(.daily(hour: 2, minute: 0), created: at(20, 2), enabled: false)
    let state = ScheduleState(jobs: [j], lastRun: [j.id: at(20, 2)])
    #expect(Scheduler().dueJobs(state, now: at(25, 9), calendar: cal).isEmpty)
}

@Test func manualJobIsNeverDue() {
    let j = job(.manual, created: at(20, 2))
    #expect(!Scheduler().isDue(j, lastRun: nil, now: at(30, 9), calendar: cal))
}

// MARK: - battery

@Test func lowBatteryDefersAScheduledRun() {
    #expect(BatteryPolicy.shouldDeferScheduledRun(PowerState(onBattery: true, percentRemaining: 12)))
}

@Test func healthyBatteryRuns() {
    #expect(!BatteryPolicy.shouldDeferScheduledRun(PowerState(onBattery: true, percentRemaining: 65)))
}

@Test func exactlyAtTheFloorRuns() {
    // the floor is "below 20", not "at or below" — no off-by-one surprise at 20%.
    #expect(!BatteryPolicy.shouldDeferScheduledRun(PowerState(onBattery: true, percentRemaining: 20)))
    #expect(BatteryPolicy.shouldDeferScheduledRun(PowerState(onBattery: true, percentRemaining: 19)))
}

@Test func lowButPluggedInRuns() {
    // charging at 5% is fine — the machine isn't going to die.
    #expect(!BatteryPolicy.shouldDeferScheduledRun(PowerState(onBattery: false, percentRemaining: 5)))
}

@Test func desktopWithNoBatteryAlwaysRuns() {
    #expect(!BatteryPolicy.shouldDeferScheduledRun(.wallPower))
}

@Test func unreadableBatteryLevelRuns() {
    // we know it's on battery but not how full: don't block a backup on a reading
    // we don't understand.
    #expect(!BatteryPolicy.shouldDeferScheduledRun(PowerState(onBattery: true, percentRemaining: nil)))
}

@Test func thresholdIsConfigurable() {
    let p = PowerState(onBattery: true, percentRemaining: 45)
    #expect(!BatteryPolicy.shouldDeferScheduledRun(p, minimumPercent: 20))
    #expect(BatteryPolicy.shouldDeferScheduledRun(p, minimumPercent: 50))
}

@Test func deferralReasonNamesTheLevel() {
    #expect(BatteryPolicy.deferralReason(PowerState(onBattery: true, percentRemaining: 12)).contains("12%"))
    #expect(BatteryPolicy.deferralReason(PowerState(onBattery: true, percentRemaining: nil)).contains("low"))
}
