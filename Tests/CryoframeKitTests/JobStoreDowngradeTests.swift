//
//  JobStoreDowngradeTests.swift
//  CryoframeKitTests
//
//  A return to 1.5.6 and back. 1.5.6 re-saves jobs.json with its own types every
//  time it records a run, and so drops what it doesn't know: each destination's
//  drive and rotation, a folder's drive, and each drive's last copy. Back on 1.6, a
//  rotation had become two destinations that each had to be connected, and every
//  destination and folder was known by its path again. 1.6 keeps those in a file of
//  its own beside jobs.json, which 1.5.6 never touches, and puts back what is
//  missing from jobs.json.
//

import Testing
import Foundation
@testable import CryoframeKit

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-jsdown-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private let start = Date(timeIntervalSince1970: 1_790_000_000)

private func member(_ id: String, _ name: String) -> Target {
    var t = Target.externalDrive(id: id, name: name, dir: URL(fileURLWithPath: "/Volumes/\(name)/Backups"))
    t.volume = VolumeIdentity(uuid: "UUID-\(id)", name: name, relativePath: "Backups", learnedAt: start)
    t.otherVolumes = [VolumeIdentity(uuid: "UUID-\(id)2", name: name, relativePath: "Backups", learnedAt: start)]
    t.rotation = Rotation(group: "offsite", addedAt: start)
    return t
}

private func papers() -> ContentType {
    var lib = ContentType.genericFolder(id: "/Volumes/Work SSD/Papers", displayName: "Papers", path: .absolute("/Volumes/Work SSD/Papers"))
    lib.volume = VolumeIdentity(uuid: "WORK-SSD", name: "Work SSD", relativePath: "Papers")
    return lib
}

/// what 1.5.6's JobStore.recordRun leaves: jobs.json with only the fields it knows
private func resaveAs156(_ url: URL, editing: ((inout [String: Any]) -> Void)? = nil) throws {
    var state = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    func strip(_ target: inout [String: Any]) { for k in ["volume", "rotation", "otherVolumes"] { target[k] = nil } }
    var jobs = try #require(state["jobs"] as? [[String: Any]])
    for i in jobs.indices {
        var targets = try #require(jobs[i]["targets"] as? [[String: Any]])
        for t in targets.indices { strip(&targets[t]) }
        jobs[i]["targets"] = targets
        if var legacy = jobs[i]["target"] as? [String: Any] { strip(&legacy); jobs[i]["target"] = legacy }
        var libs = try #require(jobs[i]["libraries"] as? [[String: Any]])
        for l in libs.indices { libs[l]["volume"] = nil }
        jobs[i]["libraries"] = libs
        editing?(&jobs[i])
    }
    state["jobs"] = jobs
    state["lastCopy"] = nil
    try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted]).write(to: url)
}

@Suite struct JobStoreDowngradeTests {

    @Test func whatARunOn156DroppedIsPutBack() throws {
        let dir = folder("back"); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("jobs.json")
        let store = JobStore(url: url)
        let job = BackupJob(id: "job-1", name: "Papers", libraries: [papers()], targets: [member("a", "T7 A"), member("b", "T7 B")],
                            format: .sealedZip, frequency: .daily(hour: 2, minute: 0), createdAt: start)
        store.upsert(job)
        store.recordCopies(jobID: "job-1", targetIDs: ["a"], at: start.addingTimeInterval(100))
        try resaveAs156(url)
        let back = store.load()
        #expect(back.jobs.first == job, "\(String(describing: back.jobs.first))")
        #expect(back.lastCopy["job-1"]?["a"] == start.addingTimeInterval(100))
        #expect(back.jobs.first?.places.count == 1, "the rotation came back as separate destinations")
    }

    // A destination 1.5.6 pointed somewhere else under the same id isn't given the
    // drive it had, and what 1.6 itself took away stays away.
    @Test func onlyWhatWasDroppedIsPutBack() throws {
        let dir = folder("only"); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("jobs.json")
        let store = JobStore(url: url)
        var job = BackupJob(id: "job-1", name: "Papers", libraries: [papers()], targets: [member("a", "T7 A"), member("b", "T7 B")],
                            format: .sealedZip, frequency: .daily(hour: 2, minute: 0), createdAt: start)
        store.upsert(job)
        job.targets[1].rotation = nil                     // taken out of the rotation on 1.6
        store.upsert(job)
        try resaveAs156(url) { job in
            var targets = job["targets"] as! [[String: Any]]
            targets[0]["destinationDir"] = URL(fileURLWithPath: "/Volumes/Other/Backups").absoluteString
            job["targets"] = targets
        }
        let back = try #require(store.load().jobs.first)
        #expect(back.targets[0].destinationDir.path == "/Volumes/Other/Backups")
        #expect(back.targets[0].volume == nil && back.targets[0].rotation == nil, "another place was given the old drive")
        #expect(back.targets[1].volume == job.targets[1].volume && back.targets[1].rotation == nil)
        #expect(back.libraries[0].volume == papers().volume)
    }
}
