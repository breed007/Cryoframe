//
//  HonestyFixEdgeTests.swift
//  CryoframeKitTests
//
//  The milestone 3 fixes to the honest dashboard and its alerts, at their edges: a
//  run the history lost in 1.5's trimming (what counts as recorded, when it turns
//  critical), the overdue throttle through failed and put-off runs, an owed deferral
//  alert, and what counts as delivered.
//

import Testing
import Foundation
@testable import CryoframeKit

private let hour: TimeInterval = 3600, day: TimeInterval = 86_400

private func job(_ id: String, _ frequency: BackupFrequency = .daily(hour: 2, minute: 0), enabled: Bool = true) -> BackupJob {
    BackupJob(id: id, name: "Job \(id)", libraries: [.photos],
              target: .localVolume(id: "t", name: "Disk", dir: URL(fileURLWithPath: "/x")),
              format: .sealedZip, frequency: frequency, enabled: enabled, createdAt: Date(timeIntervalSince1970: 0))
}

private func record(_ job: BackupJob, _ outcome: RunOutcomeKind, from start: TimeInterval, to end: TimeInterval) -> RunRecord {
    RunRecord(id: UUID().uuidString, jobID: job.id, jobName: job.name,
              startedAt: Date(timeIntervalSince1970: start), finishedAt: Date(timeIntervalSince1970: end),
              trigger: "scheduled", outcome: outcome, summary: "", libraries: [], bytes: 0, warning: nil)
}

private func d(_ t: TimeInterval) -> Date { Date(timeIntervalSince1970: t) }

@Suite struct HonestyFixEdgeTests {

    // A run is "recorded" only by a record of a run (not a deferral) that it falls
    // within, five minutes either side.
    @Test func whatCountsAsARecordOfTheLastRun() {
        let a = job("a")
        let t: TimeInterval = 100 * day
        let run = record(a, .failed, from: t, to: t + hour)
        #expect(ProtectionVerdict.unrecordedRun(lastRun: d(t), records: [run]) == nil)
        #expect(ProtectionVerdict.unrecordedRun(lastRun: d(t - 299), records: [run]) == nil)
        #expect(ProtectionVerdict.unrecordedRun(lastRun: d(t + hour + 299), records: [run]) == nil)
        #expect(ProtectionVerdict.unrecordedRun(lastRun: d(t - 301), records: [run]) == d(t - 301))
        #expect(ProtectionVerdict.unrecordedRun(lastRun: d(t), records: [record(a, .deferred, from: t, to: t)]) == d(t))
        #expect(ProtectionVerdict.unrecordedRun(lastRun: nil, records: []) == nil)
    }

    // With no good run on record and a run the history lost: attention, and critical
    // only once the job hasn't run at all for twice its interval and at least a week
    // (a nightly job: 7 days; a weekly one: 14). A job with a good run on record is
    // judged by it as before; a job run by hand is never critical.
    @Test func aLostRunIsCriticalOnlyWhenTheJobStoppedRunning() {
        let daily = job("d"), weekly = job("w", .everyHours(168)), manual = job("m", .manual)
        let ran: TimeInterval = 100 * day
        func s(_ j: BackupJob, at now: TimeInterval, lastGood: TimeInterval? = nil) -> ProtectionVerdict.Standing {
            ProtectionVerdict.standing(of: j, latest: nil, lastGood: lastGood.map(d), health: nil, now: d(now), unrecordedRun: d(ran))
        }
        #expect(s(daily, at: ran + 7 * day - 1) == .noRecordOfGoodRun(lastRan: d(ran), critical: false))
        #expect(s(daily, at: ran + 7 * day) == .noRecordOfGoodRun(lastRan: d(ran), critical: true))
        #expect(s(weekly, at: ran + 14 * day - 1).level == .attention)
        #expect(s(weekly, at: ran + 14 * day).level == .critical)
        #expect(s(manual, at: ran + 400 * day).level == .attention)
        #expect(s(daily, at: ran + hour).reason(now: d(ran + hour)) == "has no record of its last good backup (older history wasn't kept); it last ran 1 hour ago")
        // a good run on record wins: judged by it, not by the lost run
        if case .noRecordOfGoodRun = s(daily, at: ran + 30 * day, lastGood: ran + 29 * day) { Issue.record("a good run on record was ignored") }
        // paused still says paused
        #expect(ProtectionVerdict.standing(of: job("p", enabled: false), latest: nil, lastGood: nil, health: nil,
                                           now: d(ran + 30 * day), unrecordedRun: d(ran)) == .paused)
    }

    // The fixed throttle: a job overdue, then failing, then put off again the same day
    // is told it is overdue once, not again after each failure. A good run clears it.
    @Test func aFailureBetweenOverdueAlertsDoesNotRepeatThem() throws {
        let suite = "cf-fixthrottle-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let throttle = AlertThrottle(defaults: defaults, key: "overdue.lastAlerted")
        let a = job("a", .everyHours(1))
        let good: [String: Date] = ["a": d(0)]
        var sent: [Int] = []
        for h in 3...10 {
            let now = d(Double(h) * hour)
            let latest = h % 2 == 0 ? record(a, .failed, from: now.timeIntervalSince1970 - 60, to: now.timeIntervalSince1970 - 30)
                                    : record(a, .deferred, from: now.timeIntervalSince1970 - 60, to: now.timeIntervalSince1970 - 30)
            for alert in AlertPolicy.overdueAlerts(jobs: [a], latest: ["a": latest], lastGood: good, now: now, throttle: throttle) {
                sent.append(h); throttle.recordSent(alert.subject, now: now)
            }
        }
        #expect(sent == [3], "overdue alerts at hours \(sent)")
        // a good run clears it: the next trouble is told at once
        let fine = record(a, .completed, from: 11 * hour - 60, to: 11 * hour)
        #expect(AlertPolicy.overdueAlerts(jobs: [a], latest: ["a": fine], lastGood: ["a": d(11 * hour)], now: d(11 * hour), throttle: throttle).isEmpty)
        let late = record(a, .deferred, from: 14 * hour - 60, to: 14 * hour - 30)
        #expect(AlertPolicy.overdueAlerts(jobs: [a], latest: ["a": late], lastGood: ["a": d(11 * hour)], now: d(14 * hour), throttle: throttle).count == 1)
        // a paused job and a job run by hand never alert
        #expect(AlertPolicy.overdueAlerts(jobs: [job("p", enabled: false), job("m", .manual)], latest: [:], lastGood: [:],
                                          now: d(400 * day), throttle: throttle).isEmpty)
    }

    // A job whose good runs 1.5 trimmed away: no overdue alert while it only needs
    // attention; a high one once it has stopped running.
    @Test func aLostRunAlertsOnlyWhenCritical() throws {
        let suite = "cf-fixlost-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let throttle = AlertThrottle(defaults: defaults, key: "overdue.lastAlerted")
        let a = job("a")
        #expect(AlertPolicy.overdueAlerts(jobs: [a], latest: [:], lastGood: [:], unrecordedRuns: ["a": d(100 * day)],
                                          now: d(103 * day), throttle: throttle).isEmpty)
        let late = AlertPolicy.overdueAlerts(jobs: [a], latest: [:], lastGood: [:], unrecordedRuns: ["a": d(100 * day)],
                                             now: d(108 * day), throttle: throttle)
        #expect(late.count == 1 && late.first?.payload.high == true && late.first?.subject == "a.critical")
    }

    // A deferral alert that couldn't be delivered is owed until it is, within the
    // same run of deferrals, and not carried into the next one.
    @Test func anUndeliveredDeferralAlertIsOwedWithinItsStretchOnly() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cf-owed-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = RunHistoryStore(url: url)
        let a = job("a")
        var due: [Int] = []
        for h in 1...6 {
            let (r, n) = store.recordDeferral(job: a, reason: "on battery", at: d(Double(h) * hour))
            if AlertPolicy.payload(forDeferral: r, count: n) != nil {
                due.append(n)
                store.setDeferralAlertPending(recordID: r.id, n < 5)       // delivered only at the 5th
            }
        }
        #expect(due == [3, 4, 5])
        #expect(store.all().first?.deferralAlertPending == nil)
        // owed at the end of a stretch, then the job runs: the next stretch owes nothing
        let url2 = FileManager.default.temporaryDirectory.appendingPathComponent("cf-owed2-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url2) }
        let s2 = RunHistoryStore(url: url2)
        for h in 1...3 {
            let (r, n) = s2.recordDeferral(job: a, reason: "on battery", at: d(Double(h) * hour))
            if AlertPolicy.payload(forDeferral: r, count: n) != nil { s2.setDeferralAlertPending(recordID: r.id, true) }
        }
        s2.append(record(a, .completed, from: 4 * hour, to: 4 * hour + 60))
        var again: [Int] = []
        for h in 5...6 {
            let (r, n) = s2.recordDeferral(job: a, reason: "on battery", at: d(Double(h) * hour))
            if AlertPolicy.payload(forDeferral: r, count: n) != nil { again.append(n) }
        }
        #expect(again.isEmpty)
    }

    // Delivered means the service answered 2xx: not a redirect, a refusal, a server
    // error, or no answer.
    @Test func deliveredMeansTwoHundredSomething() throws {
        let u = try #require(URL(string: "https://ntfy.example/topic"))
        func http(_ code: Int) -> URLResponse? { HTTPURLResponse(url: u, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil) }
        #expect(AlertPolicy.wasDelivered(http(200)) && AlertPolicy.wasDelivered(http(204)) && AlertPolicy.wasDelivered(http(299)))
        for code in [199, 300, 301, 400, 401, 403, 404, 429, 500, 503] { #expect(!AlertPolicy.wasDelivered(http(code)), "\(code)") }
        #expect(!AlertPolicy.wasDelivered(nil))
        #expect(!AlertPolicy.wasDelivered(URLResponse(url: u, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)))
    }
}
