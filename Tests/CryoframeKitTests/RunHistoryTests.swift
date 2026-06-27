//
//  RunHistoryTests.swift
//  CryoframeKitTests
//
//  Run summarisation, record building, and the durable history store.
//

import Testing
import Foundation
@testable import CryoframeKit
import CryoframeShared

private func tmpFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("cf-hist-\(UUID().uuidString).json")
}

private func job(_ name: String = "Job") -> BackupJob {
    BackupJob(name: name, libraries: [.photos],
              target: .localVolume(id: "t", name: "Disk", dir: URL(fileURLWithPath: "/x")),
              format: .sealedZip, frequency: .manual, createdAt: Date(timeIntervalSince1970: 0))
}

// MARK: - summarizeRun

@Test func summaryIsVerifiedWhenEveryLibraryVerifies() {
    let s = summarizeRun([.completed(library: "A", destination: "Disk", parts: 1, bytes: 10, verified: true),
                          .completed(library: "B", destination: "Disk", parts: 1, bytes: 20, verified: true)])
    #expect(s.kind == .verified)
    #expect(s.text == "2 libraries verified")        // single destination: wording unchanged
}

@Test func summaryIsCompletedWhenArchivedWithoutVerify() {
    let s = summarizeRun([.completed(library: "A", destination: "Disk", parts: 1, bytes: 10, verified: nil)])
    #expect(s.kind == .completed)
    #expect(s.text == "1 library archived")
}

@Test func summaryIsFailedWhenEverythingFails() {
    let s = summarizeRun([.notFound(library: "B"),
                          .failed(library: "C", destination: "Disk", error: "boom")])
    #expect(s.kind == .failed)                        // nothing landed
    #expect(s.text.contains("0/2"))
}

/// the new multi-destination state: some copies land, some don't.
@Test func summaryIsPartialWhenSomeCopiesLandAndSomeFail() {
    let s = summarizeRun([.completed(library: "Photos", destination: "Local", parts: 1, bytes: 10, verified: true),
                          .failed(library: "Photos", destination: "NAS", error: "offline")])
    #expect(s.kind == .partial)
    #expect(s.text.contains("1/2 copies archived"))
    #expect(s.text.contains("1 failed"))
}

@Test func summaryNamesDestinationCountOnMultiDestSuccess() {
    let s = summarizeRun([.completed(library: "Photos", destination: "Local", parts: 1, bytes: 10, verified: true),
                          .completed(library: "Photos", destination: "NAS", parts: 1, bytes: 10, verified: true)])
    #expect(s.kind == .verified)
    #expect(s.text == "1 library verified → 2 destinations")
}

// MARK: - RunRecord.make

@Test func recordFromFinishedSumsBytesAndMapsLibraries() {
    let outcome = JobOutcome.finished(results: [
        .completed(library: "Photos", destination: "Disk", parts: 3, bytes: 1_000, verified: true),
        .notFound(library: "Music")], warning: "heads up")
    let r = RunRecord.make(job: job("Nightly"), outcome: outcome,
                           startedAt: Date(timeIntervalSince1970: 0), finishedAt: Date(timeIntervalSince1970: 90),
                           trigger: "scheduled")
    #expect(r.outcome == .partial)              // Photos archived, Music not found — degraded, not dead
    #expect(r.bytes == 1_000)
    #expect(r.duration == 90)
    #expect(r.trigger == "scheduled")
    #expect(r.libraries.count == 2)
    #expect(r.libraries.first(where: { $0.library == "Photos" })?.status == "verified")
    #expect(r.libraries.first(where: { $0.library == "Music" })?.status == "not found")
    #expect(r.warning == "heads up")
}

@Test func recordFromDeferredAndCancelled() {
    let d = RunRecord.make(job: job(), outcome: .deferred("Photos is open"),
                           startedAt: Date(), finishedAt: Date(), trigger: "manual")
    #expect(d.outcome == .deferred)
    #expect(d.summary == "Photos is open")

    let c = RunRecord.make(job: job(), outcome: .cancelled,
                           startedAt: Date(), finishedAt: Date(), trigger: "manual")
    #expect(c.outcome == .cancelled)
    #expect(c.summary == "stopped")
}

// MARK: - RunHistoryStore

@Test func historyStoreKeepsNewestFirstAndCaps() {
    let url = tmpFile(); defer { try? FileManager.default.removeItem(at: url) }
    let store = RunHistoryStore(url: url, cap: 3)
    for i in 0..<5 {
        store.append(RunRecord(id: "\(i)", jobID: "j", jobName: "J",
                               startedAt: Date(timeIntervalSince1970: Double(i)),
                               finishedAt: Date(timeIntervalSince1970: Double(i) + 1),
                               trigger: "manual", outcome: .completed, summary: "ok",
                               libraries: [], bytes: 0, warning: nil))
    }
    let all = store.all()
    #expect(all.count == 3)                     // capped
    #expect(all.map(\.id) == ["4", "3", "2"])   // newest first
    #expect(store.latest(forJob: "j")?.id == "4")
}

@Test func historyStoreRoundTripsAcrossInstances() {
    let url = tmpFile(); defer { try? FileManager.default.removeItem(at: url) }
    RunHistoryStore(url: url).append(RunRecord.make(job: job("Roundtrip"),
        outcome: .finished(results: [.completed(library: "Photos", destination: "Disk", parts: 1, bytes: 42, verified: nil)], warning: nil),
        startedAt: Date(timeIntervalSince1970: 0), finishedAt: Date(timeIntervalSince1970: 5), trigger: "manual"))

    let reloaded = RunHistoryStore(url: url).all()
    #expect(reloaded.count == 1)
    #expect(reloaded[0].jobName == "Roundtrip")
    #expect(reloaded[0].bytes == 42)
}
