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
}
