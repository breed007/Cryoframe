//
//  HonestStatusTests.swift
//  CryoframeKitTests
//
//  What the history keeps and what the agent sends when backups stop happening:
//  a run of deferrals is one record, a job's last good run survives trimming, and
//  overdue jobs and repeated deferrals alert without nagging.
//

import Testing
import Foundation
@testable import CryoframeKit

private func tmpFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("cf-honest-\(UUID().uuidString).json")
}

private func job(_ id: String, _ frequency: BackupFrequency = .daily(hour: 2, minute: 0)) -> BackupJob {
    BackupJob(id: id, name: "Job \(id)", libraries: [.photos],
              target: .localVolume(id: "t", name: "Disk", dir: URL(fileURLWithPath: "/x")),
              format: .sealedZip, frequency: frequency, createdAt: Date(timeIntervalSince1970: 0))
}

private func record(_ job: BackupJob, _ outcome: RunOutcomeKind, at t: TimeInterval) -> RunRecord {
    RunRecord(id: UUID().uuidString, jobID: job.id, jobName: job.name,
              startedAt: Date(timeIntervalSince1970: t - 10), finishedAt: Date(timeIntervalSince1970: t),
              trigger: "scheduled", outcome: outcome, summary: "", libraries: [], bytes: 0, warning: nil)
}

@Suite struct HonestStatusTests {

    // The agent looks every hour. A job held back all day (on battery, or behind a
    // transfer the app is finishing) wrote 24 history lines a day, and the history is
    // capped: real runs were pushed out by the noise.
    @Test func aRunOfDeferralsIsOneRecord() {
        let url = tmpFile(); defer { try? FileManager.default.removeItem(at: url) }
        let store = RunHistoryStore(url: url)
        let a = job("a"), b = job("b")
        var counts: [Int] = []
        for h in 0..<5 {
            counts.append(store.recordDeferral(job: a, reason: "on battery (12%)", at: Date(timeIntervalSince1970: 1_000 + Double(h) * 3600)).count)
            store.append(record(b, .completed, at: 1_500 + Double(h) * 3600))       // another job carries on
        }
        #expect(counts == [1, 2, 3, 4, 5])
        let mine = store.all().filter { $0.jobID == "a" }
        #expect(mine.count == 1)
        #expect(mine.first?.deferrals == 5)
        #expect(mine.first?.startedAt == Date(timeIntervalSince1970: 1_000))
        #expect(mine.first?.finishedAt == Date(timeIntervalSince1970: 1_000 + 4 * 3600))
        #expect(mine.first?.summary.hasPrefix("on battery (12%) (5 times in a row since") == true, "\(mine.first?.summary ?? "")")
        #expect(store.all().first?.jobID == "b")
        store.recordDeferral(job: a, reason: "on battery (11%)", at: Date(timeIntervalSince1970: 1_000 + 5 * 3600))
        #expect(store.all().first?.jobID == "a", "the stretch moves to the top as it goes on")
        #expect(store.all().first?.deferrals == 6)

        // once the job runs, the next deferral starts a new stretch
        store.append(record(a, .completed, at: 30_000))
        #expect(store.recordDeferral(job: a, reason: "on battery (9%)", at: Date(timeIntervalSince1970: 40_000)).count == 1)
        #expect(store.all().filter { $0.jobID == "a" }.count == 3)
    }

    // The history is capped at 200 records. A job failing for weeks beside a busier
    // one lost its last good run from the history and read as never backed up.
    @Test func trimmingKeepsEachJobsNewestGoodRun() {
        let url = tmpFile(); defer { try? FileManager.default.removeItem(at: url) }
        let store = RunHistoryStore(url: url, cap: 5)
        let a = job("a"), b = job("b")
        store.append(record(a, .partial, at: 50))
        store.append(record(a, .verified, at: 100))
        store.append(record(a, .completed, at: 90))           // recorded later, but finished earlier
        for i in 0..<12 { store.append(record(b, .completed, at: 200 + Double(i))) }
        store.append(record(a, .failed, at: 400))
        let all = store.all()
        #expect(all.count == 6, "the cap, plus job a's newest good run")
        #expect(store.lastGood()["a"] == Date(timeIntervalSince1970: 100))
        #expect(store.lastGood()["b"] == Date(timeIntervalSince1970: 211))
        #expect(all.first?.outcome == .failed)
    }

    // One routine deferral isn't news; the third in a row is, once.
    @Test func deferralsAlertOnceAtTheThirdInARow() {
        let url = tmpFile(); defer { try? FileManager.default.removeItem(at: url) }
        let store = RunHistoryStore(url: url)
        let a = job("a")
        var sent: [Int] = []
        for h in 0..<6 {
            let (r, n) = store.recordDeferral(job: a, reason: "on battery (12%)", at: Date(timeIntervalSince1970: Double(h) * 3600))
            if let p = AlertPolicy.payload(forDeferral: r, count: n) {
                sent.append(n)
                #expect(p.title == "Cryoframe — Job a isn't running")
                #expect(p.body.hasPrefix("⏸ Put off: on battery (12%) (3 times in a row since"), "\(p.body)")
                #expect(!p.high)
            }
        }
        #expect(sent == [AlertPolicy.deferralsBeforeAlert])
    }

    @Test func anOverdueJobAlertsAndACriticalOneLoudly() {
        let a = job("a")
        let now = Date(timeIntervalSince1970: 10 * 86_400)
        let late = ProtectionVerdict.standing(of: a, latest: record(a, .deferred, at: 9.5 * 86_400),
                                              lastGood: Date(timeIntervalSince1970: 7 * 86_400), health: nil, now: now)
        let p = AlertPolicy.payload(forOverdue: a, standing: late, now: now)
        #expect(p?.title == "Cryoframe — Job a is overdue")
        #expect(p?.high == false)
        #expect(p?.body.hasPrefix("⏰ Job a hasn't had a good backup in 3 days (put off") == true, "\(p?.body ?? "")")
        let week = ProtectionVerdict.standing(of: a, latest: nil, lastGood: Date(timeIntervalSince1970: 2 * 86_400), health: nil, now: now)
        #expect(AlertPolicy.payload(forOverdue: a, standing: week, now: now)?.high == true)
        let fine = ProtectionVerdict.standing(of: a, latest: record(a, .verified, at: 9.9 * 86_400),
                                              lastGood: Date(timeIntervalSince1970: 9.9 * 86_400), health: nil, now: now)
        #expect(AlertPolicy.payload(forOverdue: a, standing: fine, now: now) == nil)
        // a job run by hand is never overdue, however old its copy
        let m = job("m", .manual)
        let later = Date(timeIntervalSince1970: 400 * 86_400)
        let old = ProtectionVerdict.standing(of: m, latest: nil, lastGood: Date(timeIntervalSince1970: 0), health: nil, now: later)
        #expect(AlertPolicy.payload(forOverdue: m, standing: old, now: later) == nil)
    }

    // The agent looks every hour; an overdue job is told once a day.
    @Test func theThrottleSaysSoOnceADay() throws {
        let suite = "cf-throttle-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let t = AlertThrottle(defaults: defaults, key: "overdue")
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        #expect(t.shouldSend("a", now: t0))
        t.recordSent("a", now: t0)
        #expect(!t.shouldSend("a", now: t0.addingTimeInterval(3600)))
        #expect(t.shouldSend("b", now: t0.addingTimeInterval(3600)), "each subject on its own")
        #expect(t.shouldSend("a", now: t0.addingTimeInterval(24 * 3600)))
        #expect(t.shouldSend("a", now: t0.addingTimeInterval(-3600)), "a clock set back doesn't silence it for good")
        t.clear("a")
        #expect(t.shouldSend("a", now: t0.addingTimeInterval(60)))
    }
    // Upgraded from 1.5, whose history kept 200 records and nothing per job: a job
    // whose good runs were trimmed out read as never backed up since it was set up,
    // critical, with a high-priority alert. The job store still knows it ran.
    @Test func anUpgradedJobWhoseGoodRunsWereTrimmedIsNotCritical() {
        let a = job("a")                                // daily, set up in 1970
        let now = Date(timeIntervalSince1970: 1_000 * 86_400)
        let ranYesterday = now.addingTimeInterval(-86_400)
        // nothing in the history for it: the run the job store saw isn't on record
        #expect(ProtectionVerdict.unrecordedRun(lastRun: ranYesterday, records: []) == ranYesterday)
        let v = ProtectionVerdict.compute(jobs: [a], lastRecords: [:], lastHealth: [:], runningCount: 0,
                                          now: now, unrecordedRuns: ["a": ranYesterday])
        #expect(v.level == .attention, "\(v)")
        #expect(v.subtitle.hasPrefix("Job a has no record of its last good backup (older history wasn't kept); it last ran 24 hours ago"), "\(v.subtitle)")
        let quiet = ProtectionVerdict.standing(of: a, latest: nil, lastGood: nil, health: nil, now: now, unrecordedRun: ranYesterday)
        #expect(AlertPolicy.payload(forOverdue: a, standing: quiet, now: now) == nil)
        // a job that hasn't run at all for over a week is critical, and says so
        let ranLongAgo = now.addingTimeInterval(-10 * 86_400)
        let late = ProtectionVerdict.standing(of: a, latest: nil, lastGood: nil, health: nil, now: now, unrecordedRun: ranLongAgo)
        #expect(late.level == .critical)
        #expect(AlertPolicy.payload(forOverdue: a, standing: late, now: now)?.high == true)
        // the run is on record (a 1.6 history): judged by the record, as before
        let failedThen = RunRecord(id: "r", jobID: "a", jobName: "Job a", startedAt: ranYesterday, finishedAt: ranYesterday.addingTimeInterval(60),
                                   trigger: "scheduled", outcome: .partial, summary: "", libraries: [], bytes: 0, warning: nil)
        #expect(ProtectionVerdict.unrecordedRun(lastRun: ranYesterday, records: [failedThen]) == nil)
        // a deferral isn't a run the job store records
        let putOff = RunRecord(id: "d", jobID: "a", jobName: "Job a", startedAt: ranYesterday, finishedAt: ranYesterday,
                               trigger: "scheduled", outcome: .deferred, summary: "", libraries: [], bytes: 0, warning: nil)
        #expect(ProtectionVerdict.unrecordedRun(lastRun: ranYesterday, records: [putOff]) == ranYesterday)
        #expect(ProtectionVerdict.unrecordedRun(lastRun: nil, records: []) == nil)
    }

    // An hourly job whose runs alternate failed and put off, a week without a good
    // one: told once, not every other hour. A good run clears it, and the next
    // trouble is told at once.
    @Test func anOverdueJobIsToldOnceADayWhateverItsRunsAlternateBetween() throws {
        let suite = "cf-overdue-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let throttle = AlertThrottle(defaults: defaults, key: "overdue")
        let h = job("h", .everyHours(1))
        let start = 100.0 * 86_400
        let good = ["h": Date(timeIntervalSince1970: start - 8 * 86_400)]
        var sent = 0
        for hour in 0..<24 {
            let now = Date(timeIntervalSince1970: start + Double(hour) * 3600)
            let latest = ["h": record(h, hour % 2 == 0 ? .failed : .deferred, at: now.timeIntervalSince1970 - 60)]
            for alert in AlertPolicy.overdueAlerts(jobs: [h], latest: latest, lastGood: good, now: now, throttle: throttle) {
                sent += 1; throttle.recordSent(alert.subject, now: now)
            }
        }
        #expect(sent == 1, "told \(sent) times in a day")
        // a good run clears it; the next time it is late, it is told at once
        let later = Date(timeIntervalSince1970: start + 25 * 3600)
        _ = AlertPolicy.overdueAlerts(jobs: [h], latest: ["h": record(h, .completed, at: later.timeIntervalSince1970)],
                                      lastGood: ["h": later], now: later, throttle: throttle)
        let lateAgain = later.addingTimeInterval(3 * 3600)
        #expect(AlertPolicy.overdueAlerts(jobs: [h], latest: ["h": record(h, .deferred, at: lateAgain.timeIntervalSince1970)],
                                          lastGood: ["h": later], now: lateAgain, throttle: throttle).count == 1)
    }

    // A deferral alert that couldn't go at the third (alerts not set up, the network
    // down) is owed: tried at each later deferral of the same run until it goes. Once
    // the job runs, nothing is owed.
    @Test func anUndeliveredDeferralAlertIsTriedAgainUntilItGoes() {
        let url = tmpFile(); defer { try? FileManager.default.removeItem(at: url) }
        let store = RunHistoryStore(url: url)
        let a = job("a")
        var due: [Int] = []
        for h in 0..<6 {
            let (r, n) = store.recordDeferral(job: a, reason: "on battery (12%)", at: Date(timeIntervalSince1970: Double(h) * 3600))
            guard AlertPolicy.payload(forDeferral: r, count: n) != nil else { continue }
            due.append(n)
            store.setDeferralAlertPending(recordID: r.id, n < 5)        // delivered only at the fifth
        }
        #expect(due == [3, 4, 5])
        store.append(record(a, .completed, at: 10 * 3600))
        let (r, n) = store.recordDeferral(job: a, reason: "on battery (9%)", at: Date(timeIntervalSince1970: 11 * 3600))
        #expect(n == 1 && AlertPolicy.payload(forDeferral: r, count: n) == nil && r.deferralAlertPending == nil)
    }

    // Only an answer in the 2xx range counts as delivered.
    @Test func onlyAnAcceptedAlertCountsAsDelivered() throws {
        let url = try #require(URL(string: "https://ntfy.example/topic"))
        func answer(_ code: Int) -> URLResponse? { HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil) }
        #expect(AlertPolicy.wasDelivered(answer(200)) && AlertPolicy.wasDelivered(answer(204)))
        #expect(!AlertPolicy.wasDelivered(answer(403)) && !AlertPolicy.wasDelivered(answer(500)))
        #expect(!AlertPolicy.wasDelivered(nil), "a request that failed")
    }
}
