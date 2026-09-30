//
//  HonestyEdgeTests.swift
//  CryoframeKitTests
//
//  The honest dashboard at its edges: the exact moment a job turns overdue and then
//  critical, a clock that moves backward, a schedule that never had a good run, the
//  history cap evicting everything but a job's last good run, deferral stretches
//  from before 1.6, and the alert throttle across agent restarts and escalation.
//

import Testing
import Foundation
@testable import CryoframeKit

private let hour: TimeInterval = 3600, day: TimeInterval = 86_400

private func job(_ id: String, _ frequency: BackupFrequency = .daily(hour: 2, minute: 0),
                 created: TimeInterval = 0, enabled: Bool = true) -> BackupJob {
    BackupJob(id: id, name: "Job \(id)", libraries: [.photos],
              target: .localVolume(id: "t", name: "Disk", dir: URL(fileURLWithPath: "/x")),
              format: .sealedZip, frequency: frequency, enabled: enabled, createdAt: Date(timeIntervalSince1970: created))
}

private func record(_ job: BackupJob, _ outcome: RunOutcomeKind, at t: TimeInterval, summary: String = "") -> RunRecord {
    RunRecord(id: UUID().uuidString, jobID: job.id, jobName: job.name,
              startedAt: Date(timeIntervalSince1970: t - 10), finishedAt: Date(timeIntervalSince1970: t),
              trigger: "scheduled", outcome: outcome, summary: summary, libraries: [], bytes: 0, warning: nil)
}

private func standing(_ j: BackupJob, latest: RunRecord? = nil, lastGood: TimeInterval?, now: TimeInterval) -> ProtectionVerdict.Standing {
    ProtectionVerdict.standing(of: j, latest: latest, lastGood: lastGood.map { Date(timeIntervalSince1970: $0) },
                               health: nil, now: Date(timeIntervalSince1970: now))
}

private func historyFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("cf-honesty-edge-\(UUID().uuidString).json")
}

@Suite struct HonestyEdgeTests {

    // Boundary: overdue at exactly twice the interval, not a second before; critical
    // at exactly seven days since the last good run, not a second before.
    @Test func overdueAndCriticalStartOnTheExactSecond() {
        let a = job("a")
        let good: TimeInterval = 100 * day
        let ran = record(a, .completed, at: good)
        #expect(standing(a, latest: ran, lastGood: good, now: good + 2 * day - 1) == .healthy)
        guard case .overdue(_, _, let critical, _) = standing(a, latest: ran, lastGood: good, now: good + 2 * day) else {
            Issue.record("not overdue at exactly twice the interval"); return
        }
        #expect(!critical)
        guard case .overdue(_, _, let before, _) = standing(a, lastGood: good, now: good + 7 * day - 1),
              case .overdue(_, _, let at, _) = standing(a, lastGood: good, now: good + 7 * day) else {
            Issue.record("not overdue a week on"); return
        }
        #expect(!before && at)
        // every 6 hours: overdue at 12 hours
        let six = job("six", .everyHours(6))
        #expect(standing(six, latest: record(six, .verified, at: good), lastGood: good, now: good + 12 * hour - 1) == .healthy)
        #expect(standing(six, lastGood: good, now: good + 12 * hour).level == .attention)
        // a nonsense "every 0 hours" is treated as hourly, not as never overdue
        let zero = job("zero", .everyHours(0))
        #expect(standing(zero, lastGood: good, now: good + 2 * hour).level == .attention)
    }

    // A clock set back (or a record written by a Mac whose clock ran ahead) puts the
    // last good run in the future. That is not overdue, and the wording doesn't go
    // negative.
    @Test func aLastGoodRunInTheFutureIsNotOverdue() {
        let a = job("a")
        #expect(standing(a, latest: record(a, .completed, at: 200 * day), lastGood: 200 * day, now: 100 * day) == .healthy)
        #expect(ProtectionVerdict.age(from: Date(timeIntervalSince1970: 200 * day), to: Date(timeIntervalSince1970: 100 * day)) == "0 hours")
        // a job created "in the future" and never run isn't overdue either
        let future = job("f", created: 500 * day)
        #expect(standing(future, lastGood: nil, now: 100 * day) == .neverRan)
    }

    // A job set up a year ago that has never finished is critical at once, and the
    // dashboard says how long, even with no record at all to go on.
    @Test func aJobSetUpLongAgoThatNeverRanIsCritical() {
        let a = job("a", created: 0)
        let s = standing(a, lastGood: nil, now: 365 * day)
        guard case .overdue(nil, _, true, nil) = s else { Issue.record("\(s)"); return }
        #expect(s.reason(now: Date(timeIntervalSince1970: 365 * day)) == "hasn't finished a backup since it was set up 365 days ago")
        let v = ProtectionVerdict.compute(jobs: [a], lastRecords: [:], lastHealth: [:], runningCount: 0,
                                          now: Date(timeIntervalSince1970: 365 * day))
        #expect(v.level == .critical && v.title == "1 backup is overdue")
        // paused, the same job is flagged as paused, never overdue
        #expect(standing(job("p", created: 0, enabled: false), lastGood: nil, now: 365 * day) == .paused)
        // and a one-time job has no staleness rule
        let once = job("o", .oneTime(Date(timeIntervalSince1970: day)), created: 0)
        #expect(standing(once, latest: record(once, .completed, at: day), lastGood: day, now: 365 * day) == .healthy)
    }

    // A failure outranks everything, and a paused job's failed last run still reads
    // as failed, not as paused.
    @Test func failedOutranksPausedAndOverdue() {
        let p = job("p", enabled: false)
        #expect(standing(p, latest: record(p, .failed, at: 10 * day), lastGood: 0, now: 30 * day) == .failed)
        let a = job("a")
        #expect(standing(a, latest: record(a, .failed, at: 10 * day), lastGood: 0, now: 30 * day) == .failed)
    }

    // The history cap: 200 records of busier jobs arrive after job a's only good run,
    // and a job deleted long ago had a good run too. a's survives every trim; the
    // store doesn't grow past the cap by more than one record per job.
    @Test func theCapEvictsEverythingButEachJobsLastGoodRun() {
        let url = historyFile(); defer { try? FileManager.default.removeItem(at: url) }
        let store = RunHistoryStore(url: url, cap: 20)
        let a = job("a"), gone = job("gone"), b = job("b"), c = job("c")
        store.append(record(gone, .verified, at: 10))
        store.append(record(a, .completed, at: 20))
        store.append(record(a, .partial, at: 30))
        for i in 0..<100 {
            store.append(record(i % 2 == 0 ? b : c, i % 3 == 0 ? .completed : .failed, at: 100 + Double(i)))
            store.append(record(a, .failed, at: 100.5 + Double(i)))
        }
        let all = store.all()
        #expect(store.lastGood()["a"] == Date(timeIntervalSince1970: 20))
        #expect(all.count <= 20 + 4, "\(all.count) records")
        #expect(all.filter { $0.jobID == "a" && $0.outcome.isGood }.count == 1)
        #expect(!all.contains { $0.jobID == "a" && $0.outcome == .partial }, "a partial run isn't kept past the cap")
        // the verdict from the trimmed history once a is put off (its failures are said
        // first while it fails): overdue since its last good run, not "never backed up"
        let put = store.recordDeferral(job: a, reason: "on battery", at: Date(timeIntervalSince1970: 1_000)).record
        let s = ProtectionVerdict.standing(of: a, latest: put, lastGood: store.lastGood()["a"],
                                           health: nil, now: Date(timeIntervalSince1970: 3 * day))
        guard case .overdue(let lg?, _, _, _) = s else { Issue.record("\(s)"); return }
        #expect(lg == Date(timeIntervalSince1970: 20))
    }

    // A deferral written by 1.5.x has no count. The first 1.6 deferral after it
    // continues the stretch at 2, and the alert still fires once, at 3.
    @Test func aDeferralFromBeforeTheUpgradeContinuesTheStretch() throws {
        let url = historyFile(); defer { try? FileManager.default.removeItem(at: url) }
        let a = job("a")
        var legacy = record(a, .deferred, at: 1_000, summary: "on battery (12%)")
        legacy.deferrals = nil
        let data = try JSONEncoder().encode([legacy])
        try data.write(to: url)
        let store = RunHistoryStore(url: url)
        var alerts: [Int] = []
        for h in 1...4 {
            let (r, n) = store.recordDeferral(job: a, reason: "on battery (11%)", at: Date(timeIntervalSince1970: 1_000 + Double(h) * hour))
            if AlertPolicy.payload(forDeferral: r, count: n) != nil { alerts.append(n) }
        }
        #expect(alerts == [3])
        #expect(store.all().count == 1)
        #expect(store.all().first?.deferrals == 5)
    }

    // Two jobs put off in the same passes keep a stretch each, and one job's run
    // doesn't end the other's stretch.
    @Test func eachJobKeepsItsOwnStretch() {
        let url = historyFile(); defer { try? FileManager.default.removeItem(at: url) }
        let store = RunHistoryStore(url: url)
        let a = job("a"), b = job("b")
        for h in 0..<3 {
            #expect(store.recordDeferral(job: a, reason: "on battery", at: Date(timeIntervalSince1970: Double(h) * hour)).count == h + 1)
            #expect(store.recordDeferral(job: b, reason: "on battery", at: Date(timeIntervalSince1970: Double(h) * hour + 1)).count == h + 1)
        }
        store.append(record(b, .completed, at: 4 * hour))
        #expect(store.recordDeferral(job: a, reason: "on battery", at: Date(timeIntervalSince1970: 5 * hour)).count == 4)
        #expect(store.recordDeferral(job: b, reason: "on battery", at: Date(timeIntervalSince1970: 5 * hour)).count == 1)
    }

    // Deferrals recorded from several threads at once (the agent runs jobs
    // concurrently) all count: none is lost to another's write.
    @Test func concurrentDeferralsAllCount() {
        let url = historyFile(); defer { try? FileManager.default.removeItem(at: url) }
        let store = RunHistoryStore(url: url)
        let jobs = (0..<8).map { job("j\($0)") }
        DispatchQueue.concurrentPerform(iterations: 8 * 10) { i in
            store.recordDeferral(job: jobs[i % 8], reason: "busy", at: Date(timeIntervalSince1970: Double(i)))
        }
        let all = store.all()
        #expect(all.count == 8)
        #expect(all.map { $0.deferrals ?? 0 }.reduce(0, +) == 80)
    }

    // The throttle lives in defaults, so a restarted agent (a new process every hour)
    // remembers it; an escalation to critical is its own subject and goes at once;
    // a clock set back re-sends once and then throttles from the new time.
    @Test func theThrottleSurvivesARestartAndEscalates() throws {
        let suite = "cf-throttle-edge-\(UUID().uuidString)"
        let d1 = try #require(UserDefaults(suiteName: suite))
        defer { d1.removePersistentDomain(forName: suite) }
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        AlertThrottle(defaults: d1, key: "overdue.lastAlerted").recordSent("a", now: t0)
        // the next agent process
        let d2 = try #require(UserDefaults(suiteName: suite))
        let t = AlertThrottle(defaults: d2, key: "overdue.lastAlerted")
        #expect(!t.shouldSend("a", now: t0.addingTimeInterval(23 * hour)))
        #expect(t.shouldSend("a.critical", now: t0.addingTimeInterval(23 * hour)), "escalation waits for nothing")
        // clock set back a day: sent again once, then quiet for a day from then
        let back = t0.addingTimeInterval(-day)
        #expect(t.shouldSend("a", now: back))
        t.recordSent("a", now: back)
        #expect(!t.shouldSend("a", now: back.addingTimeInterval(hour)))
        // another key doesn't see this one
        #expect(AlertThrottle(defaults: d2, key: "other").shouldSend("a", now: back.addingTimeInterval(hour)))
    }
}
