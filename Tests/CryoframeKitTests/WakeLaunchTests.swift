//
//  WakeLaunchTests.swift
//  CryoframeKitTests
//
//  "Wake the Mac for scheduled backups" sets a wake a couple of minutes before the
//  next job is due. The agent was started only by StartInterval, and launchd.plist(5)
//  says an interval that falls while the Mac is asleep is missed, so nothing started
//  the agent during that wake, and the job wasn't due yet even if something had. A
//  calendar interval missed in sleep is run when the Mac wakes, and the agent, started
//  that early, waits for the job's time.
//

import Testing
import Foundation
@testable import CryoframeKit

private let start = Date(timeIntervalSince1970: 1_790_000_000)

private func job(_ id: String, _ frequency: BackupFrequency, enabled: Bool = true) -> BackupJob {
    BackupJob(id: id, name: id,
              libraries: [.genericFolder(id: "/p", displayName: "Papers", path: .absolute("/p"))],
              target: .localVolume(id: "/Volumes/NAS/Backups", name: "NAS", dir: URL(fileURLWithPath: "/Volumes/NAS/Backups")),
              format: .sealedDMG, frequency: frequency, enabled: enabled, createdAt: start)
}

@Suite struct WakeLaunchTests {
    @Test func theAgentIsStartedByACalendarIntervalThatAWakeCatchesUp() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Sources/Cryoframe/app.cryoframe.agent.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["StartInterval"] == nil)                   // missed while asleep, never made up
        let calendar = try #require(plist["StartCalendarInterval"] as? [String: Int])
        #expect(calendar == ["Minute": 0])                       // hourly, as before
    }

    @Test func anAgentStartedJustBeforeAJobsTimeWaitsForIt() {
        let state = ScheduleState(jobs: [job("in-two-minutes", .oneTime(start.addingTimeInterval(115))),
                                         job("tomorrow", .oneTime(start.addingTimeInterval(86_400)))])
        #expect(Scheduler().waitForNextDue(state, now: start, within: 180) == 115)
    }

    @Test func noWaitWhenNothingComesDueThatSoon() {
        let s = Scheduler()
        let later = ScheduleState(jobs: [job("later", .oneTime(start.addingTimeInterval(600)))])
        #expect(s.waitForNextDue(later, now: start, within: 180) == nil)
        let paused = ScheduleState(jobs: [job("paused", .oneTime(start.addingTimeInterval(60)), enabled: false)])
        #expect(s.waitForNextDue(paused, now: start, within: 180) == nil)
        let dueNow = ScheduleState(jobs: [job("due", .everyHours(1))], lastRun: ["due": start.addingTimeInterval(-7200)])
        #expect(s.waitForNextDue(dueNow, now: start, within: 180) == nil)      // runs now
        var unreadable = ScheduleState(jobs: [job("soon", .oneTime(start.addingTimeInterval(60)))])
        unreadable.unreadableFiles = ["jobs.json"]
        #expect(s.waitForNextDue(unreadable, now: start, within: 180) == nil)  // nothing runs
    }

    @Test func aJobDueNowWaitsWithTheOneComingDue() {
        let state = ScheduleState(jobs: [job("due", .everyHours(1)), job("soon", .oneTime(start.addingTimeInterval(90)))],
                                  lastRun: ["due": start.addingTimeInterval(-7200)])
        #expect(Scheduler().waitForNextDue(state, now: start, within: 180) == 90)
    }
}
