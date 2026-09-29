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
}
