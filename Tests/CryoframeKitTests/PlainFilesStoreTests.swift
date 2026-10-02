//
//  PlainFilesStoreTests.swift
//  CryoframeKitTests
//
//  Plain-files jobs (new in 1.7) are kept only in jobs-files.json. 1.6.0 reads
//  jobs.json and jobs-drives.json, drops a job it can't decode and erases it at its
//  next write; it never opens the third file. So a return to 1.6.0 and back loses
//  nothing: 1.6.0 sees every job it can run, and the plain-files jobs come back with
//  their last runs and copies.
//

import Testing
import Foundation
@testable import CryoframeKit

private func folder() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-plainstore-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private let start = Date(timeIntervalSince1970: 1_790_000_000)

private func job(_ id: String, _ format: FormatChoice) -> BackupJob {
    var t = Target.externalDrive(id: "t-\(id)", name: "Card", dir: URL(fileURLWithPath: "/Volumes/Card/Backups"))
    t.volume = VolumeIdentity(uuid: "CARD", name: "Card", relativePath: "Backups", learnedAt: start)
    return BackupJob(id: id, name: id, libraries: [.genericFolder(id: "docs", displayName: "Documents", path: .home("Documents"))],
                     target: t, format: format, frequency: .daily(hour: 2, minute: 0), createdAt: start)
}

@Suite struct PlainFilesStoreTests {

    // A plain-files job and an image job saved together: jobs.json holds only the image
    // job (so every element decodes, as 1.6.0 decodes it), jobs-files.json the plain
    // one with its last run and copy, and loading puts them back together.
    @Test func plainFilesJobsAreKeptOnlyInTheirOwnFile() throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JobStore(url: dir.appendingPathComponent("jobs.json"))
        var state = ScheduleState(jobs: [job("image", .sealedDMG), job("plain", .plainFiles)])
        state.lastRun = ["image": start, "plain": start.addingTimeInterval(60)]
        state.lastCopy = ["plain": ["t-plain": start.addingTimeInterval(60)], "image": ["t-image": start]]
        store.save(state)

        let main = try Data(contentsOf: dir.appendingPathComponent("jobs.json"))
        #expect(!String(decoding: main, as: UTF8.self).contains("plainFiles"))
        let decoded = try JSONDecoder().decode(ScheduleState.self, from: main)
        #expect(decoded.jobs.map(\.id) == ["image"])
        #expect(decoded.droppedJobs == 0)
        #expect(decoded.lastRun.keys.sorted() == ["image"])
        let drives = try String(contentsOf: dir.appendingPathComponent("jobs-drives.json"), encoding: .utf8)
        #expect(!drives.contains("t-plain"))

        let files = try JSONDecoder().decode(ScheduleState.self, from: Data(contentsOf: dir.appendingPathComponent("jobs-files.json")))
        #expect(files.jobs.map(\.id) == ["plain"])
        #expect(files.jobs[0].target.volume?.uuid == "CARD")
        #expect(files.lastCopy["plain"]?["t-plain"] == start.addingTimeInterval(60))

        let loaded = store.load()
        #expect(loaded.jobs.map(\.id).sorted() == ["image", "plain"])
        #expect(loaded.lastRun == state.lastRun)
        #expect(loaded.lastCopy == state.lastCopy)
        #expect(loaded == state)
    }

    // What 1.6.0 does with jobs.json while it runs (records a run, saves an edit, adds
    // a job, deletes one): it rewrites jobs.json and jobs-drives.json from what it read
    // and never touches jobs-files.json. Back on 1.7, every plain-files job and what
    // was recorded of it is still there, beside 1.6.0's changes.
    @Test func aReturnTo160AndBackLosesNoPlainFilesJob() throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("jobs.json")
        let store = JobStore(url: url)
        var state = ScheduleState(jobs: [job("image", .sealedZip), job("gone", .sealedDMG), job("plain", .plainFiles)])
        state.lastRun = ["plain": start, "image": start]
        store.save(state)
        let sidecar = try Data(contentsOf: dir.appendingPathComponent("jobs-files.json"))

        // 1.6.0: decode jobs.json with the types it knows (all decode), change, write
        var old = try JSONDecoder().decode(ScheduleState.self, from: Data(contentsOf: url))
        #expect(old.droppedJobs == 0)
        old.lastRun["image"] = start.addingTimeInterval(3600)
        old.jobs.removeAll { $0.id == "gone" }
        old.jobs.append(job("new", .sealedDMG))
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(old).write(to: url, options: .atomic)
        try enc.encode(DriveRecords(old)).write(to: dir.appendingPathComponent("jobs-drives.json"), options: .atomic)
        #expect(try Data(contentsOf: dir.appendingPathComponent("jobs-files.json")) == sidecar)

        let back = store.load()
        #expect(back.jobs.map(\.id).sorted() == ["image", "new", "plain"])
        #expect(back.lastRun["plain"] == start)
        #expect(back.lastRun["image"] == start.addingTimeInterval(3600))
        #expect(back.jobs.first { $0.id == "plain" } == job("plain", .plainFiles))
    }

    // A job in both files (a crash between the two writes) is the sidecar's, and the
    // next write takes it out of jobs.json.
    @Test func aJobInBothFilesIsTakenFromTheSidecar() throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("jobs.json")
        let store = JobStore(url: url)
        store.save(ScheduleState(jobs: [job("plain", .plainFiles)]))
        var stale = job("plain", .sealedDMG); stale.name = "stale"
        try JSONEncoder().encode(ScheduleState(jobs: [stale, job("image", .sealedDMG)])).write(to: url)

        let loaded = store.load()
        #expect(loaded.jobs.filter { $0.id == "plain" }.count == 1)
        #expect(loaded.jobs.first { $0.id == "plain" }?.format == .plainFiles)
        store.recordRun(id: "image", at: start)
        let main = try JSONDecoder().decode(ScheduleState.self, from: Data(contentsOf: url))
        #expect(main.jobs.map(\.id) == ["image"])
    }

    // Deleting the last plain-files job empties the sidecar rather than leave it
    // holding a job that is gone.
    @Test func removingTheLastPlainFilesJobEmptiesItsFile() throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JobStore(url: dir.appendingPathComponent("jobs.json"))
        store.save(ScheduleState(jobs: [job("plain", .plainFiles), job("image", .sealedDMG)]))
        store.remove(id: "plain")
        let files = try JSONDecoder().decode(ScheduleState.self, from: Data(contentsOf: dir.appendingPathComponent("jobs-files.json")))
        #expect(files.jobs.isEmpty)
        #expect(store.load().jobs.map(\.id) == ["image"])
    }

    // Without a plain-files job there is no sidecar at all.
    @Test func noSidecarWithoutAPlainFilesJob() {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JobStore(url: dir.appendingPathComponent("jobs.json"))
        store.save(ScheduleState(jobs: [job("image", .sealedDMG)]))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("jobs-files.json").path))
    }
}
