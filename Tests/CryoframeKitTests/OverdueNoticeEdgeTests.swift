//
//  OverdueNoticeEdgeTests.swift
//  CryoframeKitTests
//
//  The app's overdue notice on this Mac and its own throttle. The app looks every
//  30 seconds, but only while it runs: a good run can come and go (the scheduled
//  agent's, overnight) while it is closed, and the throttle is cleared only when a
//  look happens to see a good run as the latest.
//

import Testing
import Foundation
@testable import CryoframeKit

private func job(_ id: String, _ frequency: BackupFrequency) -> BackupJob {
    BackupJob(id: id, name: "Job \(id)", libraries: [.photos],
              target: .localVolume(id: "t", name: "Disk", dir: URL(fileURLWithPath: "/x")),
              format: .sealedZip, frequency: frequency, createdAt: Date(timeIntervalSince1970: 0))
}

private func record(_ job: BackupJob, _ outcome: RunOutcomeKind, at t: Date) -> RunRecord {
    RunRecord(id: UUID().uuidString, jobID: job.id, jobName: job.name,
              startedAt: t.addingTimeInterval(-10), finishedAt: t,
              trigger: "scheduled", outcome: outcome, summary: "", libraries: [], bytes: 0, warning: nil)
}

@Suite struct OverdueNoticeEdgeTests {

    // An hourly job goes overdue and the notice is shown. The app is closed; the
    // job then runs fine, and hours later goes overdue again: a new stretch, which
    // should be told when the app next looks, not held back until a day after the
    // first notice.
    @Test func aNewOverdueStretchAfterAGoodRunTheAppDidntSeeIsTold() throws {
        let suite = "cf-notice-edge-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let local = AlertThrottle(defaults: defaults, key: AlertThrottle.overdueLocalKey)
        let hourly = job("h", .everyHours(1))
        let t0 = Date(timeIntervalSince1970: 100 * 86_400)

        // overdue: put off since the last good run three hours ago
        let first = AlertPolicy.overdueAlerts(jobs: [hourly], latest: ["h": record(hourly, .deferred, at: t0.addingTimeInterval(-60))],
                                              lastGood: ["h": t0.addingTimeInterval(-3 * 3600)], now: t0, throttle: local)
        try #require(first.count == 1)
        for a in first { local.recordSent(a.subject, now: t0) }

        // the app closes; a good run at t0 + 1 h; put off since; overdue again at t0 + 4 h
        let good = t0.addingTimeInterval(3600)
        let now = t0.addingTimeInterval(4 * 3600)
        let latest = ["h": record(hourly, .deferred, at: now.addingTimeInterval(-60))]
        let fresh = AlertThrottle(defaults: defaults, key: "cf-notice-edge-fresh")
        try #require(AlertPolicy.overdueAlerts(jobs: [hourly], latest: latest, lastGood: ["h": good], now: now, throttle: fresh).count == 1,
                     "not overdue again: the fixture is wrong")
        let again = AlertPolicy.overdueAlerts(jobs: [hourly], latest: latest, lastGood: ["h": good], now: now, throttle: local)
        #expect(again.count == 1, "a new overdue stretch after a good run is held back until a day after the last notice")
    }

    // Local and remote throttles don't touch each other's record, and a notice the
    // Mac couldn't show (not recorded) is still owed at the next look.
    @Test func aNoticeNotShownIsStillOwed() throws {
        let suite = "cf-notice-owed-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let local = AlertThrottle(defaults: defaults, key: AlertThrottle.overdueLocalKey)
        let remote = AlertThrottle(defaults: defaults, key: AlertThrottle.overdueRemoteKey)
        let daily = job("d", .daily(hour: 2, minute: 0))
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        let latest = ["d": record(daily, .deferred, at: now.addingTimeInterval(-60))]
        let lastGood = ["d": now.addingTimeInterval(-3 * 86_400)]
        #expect(AlertPolicy.overdueAlerts(jobs: [daily], latest: latest, lastGood: lastGood, now: now, throttle: local).count == 1)
        // not recorded: macOS didn't take it
        #expect(AlertPolicy.overdueAlerts(jobs: [daily], latest: latest, lastGood: lastGood, now: now.addingTimeInterval(30), throttle: local).count == 1)
        remote.recordSent("d", now: now)
        #expect(AlertPolicy.overdueAlerts(jobs: [daily], latest: latest, lastGood: lastGood, now: now.addingTimeInterval(60), throttle: local).count == 1)
        // critical a week on: told again at once, whatever was said the day before
        local.recordSent("d", now: now.addingTimeInterval(6 * 86_400))
        let critical = AlertPolicy.overdueAlerts(jobs: [daily], latest: latest, lastGood: lastGood,
                                                 now: now.addingTimeInterval(6 * 86_400 + 3600), throttle: local)
        #expect(critical.count == 1 && critical.first?.subject == "d.critical", "\(critical.map(\.subject))")
    }
}
