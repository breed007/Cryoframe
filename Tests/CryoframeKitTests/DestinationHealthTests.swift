//
//  DestinationHealthTests.swift
//  CryoframeKitTests
//
//  The per-destination trend: a bounded ring per (job, destination), rings of gone
//  jobs and destinations dropped on load, two writers losing nothing, the line and
//  "slower than usual", and what a finished run adds.
//

import Testing
import Foundation
@testable import CryoframeKit

private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-dh-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

private func run(_ i: Int, good: Bool = true, seconds: Double = 100) -> DestinationRun {
    DestinationRun(at: t0.addingTimeInterval(Double(i) * 3600), good: good, bytes: UInt64(i), seconds: seconds,
                   freeAfter: nil, checkPassed: nil)
}

@Suite struct DestinationHealthTests {
    @Test func eachRingKeepsItsLastHundred() throws {
        let dir = folder("ring"); defer { try? FileManager.default.removeItem(at: dir) }
        let store = DestinationHealthStore(url: dir.appendingPathComponent("dh.json"))
        let a = DestinationKey(jobID: "j", targetID: "a"), b = DestinationKey(jobID: "j", targetID: "b")
        for i in 0..<130 { store.append(run(i), for: a) }
        store.append(run(0), for: b)
        let runs = store.runs(for: a)
        #expect(runs.count == DestinationHealthStore.defaultCap)
        #expect(runs.first?.bytes == 129 && runs.last?.bytes == 30, "newest first, oldest dropped")
        #expect(store.runs(for: b).count == 1, "one ring's cap took from another")
    }

    @Test func goneJobsAndDestinationsArePrunedOnLoad() throws {
        let dir = folder("prune"); defer { try? FileManager.default.removeItem(at: dir) }
        let store = DestinationHealthStore(url: dir.appendingPathComponent("dh.json"))
        let keep = DestinationKey(jobID: "j", targetID: "a")
        let goneTarget = DestinationKey(jobID: "j", targetID: "removed"), goneJob = DestinationKey(jobID: "deleted", targetID: "a")
        for k in [keep, goneTarget, goneJob] { store.append(run(1), for: k) }
        let loaded = store.load(keeping: [keep])
        #expect(Array(loaded.keys) == [keep])
        #expect(store.runs(for: goneTarget).isEmpty && store.runs(for: goneJob).isEmpty, "not dropped from the file")
        let raw = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(!raw.contains("deleted") && !raw.contains("removed"))
    }

    @Test func twoWritersLoseNothing() async throws {
        let dir = folder("writers"); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("dh.json")
        let key = DestinationKey(jobID: "j", targetID: "a")
        await withTaskGroup(of: Void.self) { group in
            for w in 0..<2 {
                group.addTask {
                    let store = DestinationHealthStore(url: url)          // its own lock, as the agent has
                    for i in 0..<40 { store.append(run(w * 1000 + i), for: key) }
                }
            }
        }
        #expect(DestinationHealthStore(url: url).runs(for: key).count == 80)
    }

    @Test func theLineCountsTheLastThirty() throws {
        var runs = (0..<40).map { run($0, good: $0 % 10 != 3) }.reversed().map { $0 }
        var trend = try #require(DestinationTrend(runs))
        #expect(trend.runs.count == 30 && trend.good + trend.failed == 30)
        #expect(trend.line == "Last 30 runs: 27 good, 3 failed")
        #expect(trend.runs.first!.at < trend.runs.last!.at, "oldest first")
        runs = [run(1)]
        trend = try #require(DestinationTrend(runs))
        #expect(trend.line == "Last run: good")
        #expect(DestinationTrend([run(1, good: false), run(0, good: false)])?.line == "Last 2 runs: all failed")
        #expect(DestinationTrend([]) == nil)
    }

    @Test func slowerThanUsualIsTwiceTheMedianAndInformationOnly() {
        let usual = (0..<10).map { run($0, seconds: 300) }.reversed().map { $0 }
        #expect(DestinationTrend([run(11, seconds: 700)] + usual)?.slowerThanUsual == true)
        #expect(DestinationTrend([run(11, seconds: 590)] + usual)?.slowerThanUsual == false)
        #expect(DestinationTrend([run(11, good: false, seconds: 9000)] + usual)?.slowerThanUsual == false, "a failed run is a failure, not slow")
        #expect(DestinationTrend([run(11, seconds: 700)] + usual.prefix(3))?.slowerThanUsual == false, "too few runs to know usual")
        let quick = (0..<10).map { run($0, seconds: 4) }
        #expect(DestinationTrend([run(11, seconds: 20)] + quick)?.slowerThanUsual == false, "seconds, not minutes")
    }

    // A run adds one line per destination it reached, under the destination's own
    // key, read by the name the run gave it (two of one name told apart), and none
    // for a run that never got to a destination.
    @Test func aFinishedRunAddsALinePerDestinationItReached() throws {
        let dir = folder("followup"); defer { try? FileManager.default.removeItem(at: dir) }
        let d1 = dir.appendingPathComponent("one"), d2 = dir.appendingPathComponent("two")
        for d in [d1, d2] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let notes = ContentType.genericFolder(id: "n", displayName: "Notes", path: .absolute("/Users/someone/Notes"))
        let job = BackupJob(id: "job", name: "Job", libraries: [notes],
                            targets: [.localVolume(id: "a", name: "Backups", dir: d1), .localVolume(id: "b", name: "Backups", dir: d2)],
                            format: .sealedZip, frequency: .manual, createdAt: t0)
        let labels = job.destinationLabels
        try #require(labels["a"] != labels["b"])
        let record = RunRecord.make(job: job, outcome: .finished(results: [
            .completed(library: "Notes", destination: labels["a"]!, parts: 1, bytes: 500, verified: true),
            .failed(library: "Notes", destination: labels["b"]!, error: "full"),
        ], warning: nil), startedAt: t0, finishedAt: t0.addingTimeInterval(90), trigger: "manual")
        let store = DestinationHealthStore(url: dir.appendingPathComponent("dh.json"))
        RunFollowUp.record(record, job: job, health: store, uploads: nil, lastCheck: nil,
                           volumes: FixedVolumeTable([]), freeSpace: { _ in 12345 })
        let a = store.runs(for: DestinationKey(jobID: "job", targetID: "a"))
        let b = store.runs(for: DestinationKey(jobID: "job", targetID: "b"))
        #expect(a.count == 1 && a[0].good && a[0].bytes == 500 && a[0].seconds == 90 && a[0].freeAfter == 12345)
        #expect(b.count == 1 && !b[0].good)
        // stopped before it wrote anything: no line
        let early = RunRecord.failure(job: job, error: "no snapshot", startedAt: t0, finishedAt: t0, trigger: "manual")
        RunFollowUp.record(early, job: job, health: store, uploads: nil, lastCheck: nil, volumes: FixedVolumeTable([]))
        #expect(store.runs(for: DestinationKey(jobID: "job", targetID: "a")).count == 1)
    }

    // A run into a cloud folder puts its new versions on the upload list; a run to
    // a drive doesn't.
    // 1.6.0 doesn't know plain-files jobs (they are only in jobs-files.json), and its
    // Storage window drops the rings of jobs it doesn't know from destination-health.json.
    // A plain-files job's runs go in a file of their own, which 1.6.0 never reads, and
    // a ring an earlier build kept in the first file moves over with the next run.
    @Test func aPlainFilesJobsTrendOutlivesAnOlderStorageWindow() throws {
        let dir = folder("plain"); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("destination-health.json")
        let store = DestinationHealthStore(url: url)
        #expect(store.plainFilesURL.lastPathComponent == "destination-health-files.json")
        let sealed = DestinationKey(jobID: "sealed", targetID: "d"), plain = DestinationKey(jobID: "plain", targetID: "d")
        store.append(run(1), for: sealed)
        store.append(run(1), for: plain)                       // as a build before this one kept it
        store.append(run(2), for: plain, plainFiles: true)
        store.append(run(3), for: plain, plainFiles: true)
        #expect(store.runs(for: plain).map(\.bytes) == [3, 2, 1])

        // 1.6.0's Storage: every ring but the jobs it knows, dropped from the first file
        struct Old: Codable { var rings: [String: [DestinationRun]] }
        var old = try JSONDecoder().decode(Old.self, from: Data(contentsOf: url))
        #expect(old.rings[plain.string] == nil, "the plain job's ring is still in the file 1.6.0 prunes")
        old.rings = old.rings.filter { $0.key == sealed.string }
        try JSONEncoder().encode(old).write(to: url)

        #expect(store.runs(for: plain).map(\.bytes) == [3, 2, 1])
        let loaded = store.load(keeping: [sealed, plain])
        #expect(loaded[plain]?.count == 3 && loaded[sealed]?.count == 1)
        // and this build's Storage still drops a gone job's ring from both
        store.load(keeping: [sealed])
        #expect(store.runs(for: plain).isEmpty)

        // what a finished run adds goes to the file of the job's kind
        let notes = ContentType.genericFolder(id: "n", displayName: "Notes", path: .absolute("/Users/someone/Notes"))
        let dest = dir.appendingPathComponent("Card")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let job = BackupJob(id: "pj", name: "Plain", libraries: [notes], target: .localVolume(id: "c", name: "Card", dir: dest),
                            format: .plainFiles, frequency: .manual, createdAt: t0)
        let record = RunRecord.make(job: job, outcome: .finished(results: [
            .completed(library: "Notes", destination: "Card", parts: 1, bytes: 7, verified: nil)], warning: nil),
            startedAt: t0, finishedAt: t0, trigger: "scheduled")
        RunFollowUp.record(record, job: job, health: store, uploads: nil, lastCheck: nil, volumes: FixedVolumeTable([]))
        let key = DestinationKey(jobID: "pj", targetID: "c")
        #expect(store.runs(for: key).map(\.bytes) == [7])
        #expect((try? JSONDecoder().decode(Old.self, from: Data(contentsOf: url)))?.rings[key.string] == nil)
    }

    @Test func aCloudRunRecordsItsVersionForTheUploadCheck() throws {
        let dir = folder("cloudrun"); defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("Dropbox")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let notes = ContentType.genericFolder(id: "n", displayName: "Notes", path: .absolute("/Users/someone/Notes"))
        let job = BackupJob(id: "cj", name: "Cloud", libraries: [notes],
                            target: .cloudSyncFolder(id: "c", name: "Dropbox", dir: dest, provider: .dropbox),
                            format: .sealedZip, frequency: .manual, createdAt: t0)
        let f = try LibraryFolders.prepare(job: job, library: notes, in: dest, jobs: [job], isOpen: { _ in false }).folder
        let at = f.appendingPathComponent("2026-09-01-020000")
        try FileManager.default.createDirectory(at: at, withIntermediateDirectories: true)
        let zip = at.appendingPathComponent("Notes.zip"); try Data("z".utf8).write(to: zip)
        _ = try ArchiveManifest.write(try ArchiveManifest.build(for: ArchiveResult(artifacts: [zip], format: .sealedZip)), toDir: at)
        let record = RunRecord.make(job: job, outcome: .finished(results: [
            .completed(library: "Notes", destination: "Dropbox", parts: 1, bytes: 1, verified: nil)], warning: nil),
            startedAt: t0, finishedAt: t0, trigger: "scheduled")
        let ledger = UploadLedger(url: dir.appendingPathComponent("up.json"))
        RunFollowUp.record(record, job: job, health: DestinationHealthStore(url: dir.appendingPathComponent("dh.json")),
                           uploads: ledger, lastCheck: nil, volumes: FixedVolumeTable([]))
        let entries = ledger.destination(DestinationKey(jobID: "cj", targetID: "c"))?.entries ?? []
        #expect(entries.map(\.version) == [at.path])
        #expect(entries.first?.runAt == VersionStamp.date("2026-09-01-020000"))
    }
}
