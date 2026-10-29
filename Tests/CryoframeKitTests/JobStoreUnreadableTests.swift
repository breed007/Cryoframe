//
//  JobStoreUnreadableTests.swift
//  CryoframeKitTests
//
//  A job this version can't decode (one a newer version wrote, before a return to
//  this one) used to be dropped on loading and erased from disk at the next write,
//  which the agent makes within the hour. A job file that can't be read at all came
//  back as no jobs, and the next write replaced it with an empty list. Now the job
//  is written back as it was found, and an unreadable file is left alone, copied
//  beside itself, and reported.
//

import Testing
import Foundation
@testable import CryoframeKit

private let start = Date(timeIntervalSince1970: 1_790_000_000)

private func scratch(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-unreadable-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return TempTracker.track(d)
}

private let nas = Target.localVolume(id: "/Volumes/NAS/Backups", name: "Backups on NAS", dir: URL(fileURLWithPath: "/Volumes/NAS/Backups"))
private let papers = ContentType.genericFolder(id: "/Volumes/Work/Papers", displayName: "Papers", path: .absolute("/Volumes/Work/Papers"))

private func job(_ id: String, _ format: FormatChoice = .sealedDMG) -> BackupJob {
    BackupJob(id: id, name: id, libraries: [papers], target: nas, format: format,
              frequency: .daily(hour: 2, minute: 0), createdAt: start)
}

/// `job` as a newer version might write it: a format this one doesn't know, and a
/// field it has never heard of, holding every kind of JSON value
private func futureJob(_ id: String) throws -> [String: Any] {
    var obj = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(job(id))) as? [String: Any])
    obj["format"] = ["tape": ["drive": "LTO-9"]]
    obj["notices"] = ["list": [1, 2.5, true, false, NSNull(), "x", 9_007_199_254_740_993], "empty": [String: Any]()]
    return obj
}

private func jobsArray(_ url: URL) throws -> [[String: Any]] {
    let state = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    return try #require(state["jobs"] as? [[String: Any]])
}

private func writeState(_ jobs: [[String: Any]], to url: URL) throws {
    try JSONSerialization.data(withJSONObject: ["jobs": jobs, "lastRun": [String: Double]()]).write(to: url)
}

@Suite struct JobStoreUnreadableTests {

    @Test func aJobThisVersionCantDecodeIsWrittenBackAsItWas() throws {
        let dir = scratch("job")
        let url = dir.appendingPathComponent("jobs.json")
        let good = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(job("good"))) as? [String: Any])
        let future = try futureJob("future")
        try writeState([good, future], to: url)

        let store = JobStore(url: url)
        #expect(store.load().jobs.map(\.id) == ["good"])
        #expect(store.load().droppedJobs == 1)
        store.recordRun(id: "good", at: start)                 // the agent's next write

        let written = try jobsArray(url)
        #expect(written.count == 2)
        let kept = try #require(written.first { $0["id"] as? String == "future" })
        #expect(NSDictionary(dictionary: kept).isEqual(to: future))
        #expect(store.load().lastRun["good"] == start)
        #expect(store.load().droppedJobs == 1)
    }

    @Test func aPlainFilesJobThisVersionCantDecodeStaysInItsOwnFile() throws {
        let dir = scratch("files")
        let store = JobStore(url: dir.appendingPathComponent("jobs.json"))
        store.save(ScheduleState(jobs: [job("image"), job("plain", .plainFiles)]))
        var plain = try jobsArray(store.filesURL)
        plain.append(try futureJob("future"))
        try writeState(plain, to: store.filesURL)

        store.recordRun(id: "image", at: start)
        #expect(try jobsArray(store.filesURL).map { $0["id"] as? String } == ["plain", "future"])
        #expect(try jobsArray(dir.appendingPathComponent("jobs.json")).map { $0["id"] as? String } == ["image"])
    }

    @Test(arguments: ["jobs.json", "jobs-files.json"])
    func aFileThatCantBeReadIsNeverWrittenOver(name: String) throws {
        let dir = scratch("whole")
        let store = JobStore(url: dir.appendingPathComponent("jobs.json"))
        store.save(ScheduleState(jobs: [job("image"), job("plain", .plainFiles)]))
        let broken = Data(#"{"jobs": {"written by": "a version from the future"}"#.utf8)
        let url = dir.appendingPathComponent(name)
        try broken.write(to: url)
        let other = dir.appendingPathComponent(name == "jobs.json" ? "jobs-files.json" : "jobs.json")
        let otherBefore = try Data(contentsOf: other)

        #expect(store.load().unreadableFiles == [name])
        store.upsert(job("new"))
        store.recordRun(id: "image", at: start)
        #expect(try Data(contentsOf: url) == broken)            // left as it was
        #expect(try Data(contentsOf: other) == otherBefore)     // and so is the other one
        #expect(!store.load().jobs.contains { $0.id == "new" })

        let copies = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(name + ".unreadable-") }
        #expect(copies.count == 1)                               // one copy, however many writes were refused
        let copy = try #require(copies.first)
        #expect(try Data(contentsOf: dir.appendingPathComponent(copy)) == broken)
        // no run could be recorded, so none is due: each pass would start it again
        #expect(Scheduler().dueJobs(store.load(), now: start.addingTimeInterval(7 * 86_400)).isEmpty)
    }

    @Test func savingAJobIntoAnUnreadableFileSaysSoAndKeepsNoKey() throws {
        let dir = scratch("commit")
        let url = dir.appendingPathComponent("jobs.json")
        try Data("not json".utf8).write(to: url)
        let store = JobStore(url: url)
        var d = JobDraftState(libraries: [papers], targets: [nas], now: start, newID: "new-job")
        d.selectedLibraryIDs = [papers.id]
        d.encrypt = true; d.passphrase = "horse battery"; d.passphraseConfirm = "horse battery"; d.formatKind = "dmg"
        let result = d.commit(to: store, now: start) { _, _ in Issue.record("a key for a job that can't be saved") }
        #expect(result == .unreadable)
        #expect(try Data(contentsOf: url) == Data("not json".utf8))
    }
}
