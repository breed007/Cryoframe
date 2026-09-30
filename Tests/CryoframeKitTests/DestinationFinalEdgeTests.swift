//
//  DestinationFinalEdgeTests.swift
//  CryoframeKitTests
//
//  The last M5a fixes at their edges. A same-named drive is a 1.5 pair's other
//  drive only on evidence this job wrote there: one of its recorded runs, started
//  when a version there was stamped and of that version's size. The run history is
//  the newest 200 runs of every job together, so a busy job beside the rotating one
//  pushes out the runs that wrote to the drive that was away. And another job's
//  folder keeps its versions unless it is a mirror job's; a mirror job whose folder
//  holds another job's versions can become a sealed job.
//

import Testing
import Foundation
@testable import CryoframeKit

private let start = Date(timeIntervalSince1970: 1_790_000_000)
private let hour: TimeInterval = 3600, day: TimeInterval = 86_400
private let v1 = "2026-09-01-020000", v2 = "2026-09-02-020000", v3 = "2026-09-03-020000"

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-dfin-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

@discardableResult
private func archive(in dir: URL, bundle: String, mirror: Bool = false, version: String? = nil) throws -> URL {
    let at = version.map { dir.appendingPathComponent($0) } ?? dir
    try FileManager.default.createDirectory(at: at, withIntermediateDirectories: true)
    let result: ArchiveResult
    if mirror {
        let sb = at.appendingPathComponent(bundle + ".sparsebundle")
        try FileManager.default.createDirectory(at: sb.appendingPathComponent("bands"), withIntermediateDirectories: true)
        try Data("band".utf8).write(to: sb.appendingPathComponent("bands/0"))
        result = ArchiveResult(artifacts: [sb], format: .liveMirror)
    } else {
        let f = at.appendingPathComponent(bundle + ".zip")
        try Data("zip \(UUID())".utf8).write(to: f)
        result = ArchiveResult(artifacts: [f], format: .sealedZip)
    }
    _ = try ArchiveManifest.write(try ArchiveManifest.build(for: result), toDir: at)
    return at
}

private func names(_ dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
}

private func run(_ job: BackupJob, at: Date, library: String, bytes: UInt64) -> RunRecord {
    RunRecord(id: UUID().uuidString, jobID: job.id, jobName: job.name, startedAt: at, finishedAt: at.addingTimeInterval(300),
              trigger: "scheduled", outcome: .completed, summary: "",
              libraries: [LibraryOutcome(from: .completed(library: library, destination: "T7", parts: 1, bytes: bytes, verified: true))],
              bytes: bytes, warning: nil)
}

@Suite(.serialized) struct DestinationFinalEdgeTests {

    // MARK: the evidence a drive is this job's

    // A 1.5 job backs up Papers daily to two drives named "T7" that take turns, a
    // week or so each (the rotation's own default allows 14 days). Beside it, a job
    // that runs hourly. Drive B comes home after 10 days: its newest version was made
    // by a run 10 days ago, and 240 hourly runs have pushed that run out of the
    // history (only Papers' newest good run, on drive A, is kept however old). With
    // no run to match, drive B is "a different drive" again, refused every week it
    // is the one at home.
    @Test func aPairsOtherDriveIsKnownWhenABusierJobFillsTheHistory() throws {
        let base = folder("trimmed"); defer { try? FileManager.default.removeItem(at: base) }
        let driveB = base.appendingPathComponent("B/Backups")
        let papers = ContentType.genericFolder(id: "papers", displayName: "Papers", path: .absolute("/Users/someone/Papers"))
        let job = BackupJob(name: "Papers", libraries: [papers], target: .externalDrive(id: "t7", name: "T7", dir: driveB),
                            format: .sealedZip, frequency: .daily(hour: 2, minute: 0), createdAt: start)
        let hourly = BackupJob(name: "Documents", libraries: [.genericFolder(id: "docs", displayName: "Documents",
                                                                              path: .absolute("/Users/someone/Documents"))],
                               target: .externalDrive(id: "ssd", name: "SSD", dir: base.appendingPathComponent("SSD")),
                               format: .liveMirror(sizeGB: 1), frequency: .everyHours(1), createdAt: start)
        // day 0, on drive B
        let onB = try archive(in: driveB.appendingPathComponent("Papers"), bundle: "Papers", version: VersionStamp.string(start))
        let bytes = try #require(RestoreDiscovery.archive(at: onB)).bytes
        let store = RunHistoryStore(url: base.appendingPathComponent("history.json"))
        store.append(run(job, at: start, library: "Papers", bytes: bytes))
        #expect(LibraryFolders.holdsBackups(of: job, in: driveB, runs: store.all()), "the evidence itself")
        // days 1 to 9 on drive A, and the hourly job
        for h in 1...(10 * 24) {
            let at = start.addingTimeInterval(TimeInterval(h) * hour)
            if h % 24 == 0 { store.append(run(job, at: at, library: "Papers", bytes: bytes + UInt64(h))) }
            store.append(run(hourly, at: at.addingTimeInterval(60), library: "Documents", bytes: 1000))
        }
        #expect(LibraryFolders.holdsBackups(of: job, in: driveB, runs: store.all()),
                "drive B's run is gone from a history of \(store.all().count) runs; \(store.all().filter { $0.jobID == job.id }.count) of them this job's")
    }

    // MARK: a mirror job made a sealed job

    // A 1.5 folder a mirror job and a sealed job shared, taken over by the mirror job
    // first. The sealed job is paused (or hasn't run since), so its versions are
    // still there. The mirror job is then made a sealed job (the job editor allows
    // it). The versions in its folder are now "its own", and its retention deletes
    // the other job's versions.
    @Test func aMirrorJobMadeSealedDoesntPruneAnotherJobsVersionsInItsFolder() throws {
        let dest = folder("convert"); defer { try? FileManager.default.removeItem(at: dest) }
        let photos = ContentType.genericFolder(id: "com.apple.photos", displayName: "Photos",
                                               path: .absolute("/Users/someone/Pictures/Photos Library.photoslibrary"))
        let legacy = dest.appendingPathComponent("Photos")
        try archive(in: legacy, bundle: "Photos Library.photoslibrary", mirror: true)
        for v in [v1, v2] { try archive(in: legacy, bundle: "Photos Library.photoslibrary", version: v) }
        var mirror = BackupJob(id: "m", name: "Photos mirror", libraries: [photos], target: .localVolume(id: "d", name: "Dest", dir: dest),
                               format: .liveMirror(sizeGB: 1), frequency: .manual, createdAt: start)
        var paused = BackupJob(id: "s", name: "Photos versions", libraries: [photos], target: .localVolume(id: "d", name: "Dest", dir: dest),
                               format: .sealedZip, frequency: .daily(hour: 2, minute: 0), createdAt: start)
        paused.enabled = false
        let m = try LibraryFolders.prepare(job: mirror, library: photos, in: dest, jobs: [mirror, paused], isOpen: { _ in false }).folder
        #expect(m.path == legacy.path)

        mirror.format = .sealedZip; mirror.retention = .keepLast(1)
        let now = try LibraryFolders.prepare(job: mirror, library: photos, in: dest, jobs: [mirror, paused], isOpen: { _ in false }).folder
        try archive(in: now, bundle: "Photos Library.photoslibrary", version: v3)
        JobExecutor.pruneVersions(folders: JobExecutor.prunable(mirror, ["d": [photos.id: now]]), policy: mirror.retention)
        let kept = [v1, v2].filter { v in FileManager.default.fileExists(atPath: legacy.appendingPathComponent(v).path)
            || (try? FileManager.default.contentsOfDirectory(atPath: dest.path))?.contains { FileManager.default.fileExists(atPath: dest.appendingPathComponent($0).appendingPathComponent(v).path) } == true }
        #expect(kept == [v1, v2], "the paused job's versions were pruned by the job that was a mirror: \(names(now))")
    }
}
