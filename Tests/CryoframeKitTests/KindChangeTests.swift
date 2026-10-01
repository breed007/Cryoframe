//
//  KindChangeTests.swift
//  CryoframeKitTests
//
//  A job changed between a mirror and sealed versions holds the versions in its
//  folder where they are: neither its retention nor another job's takes them. And
//  the run history keeps the runs 1.5 recorded that made versions for a month,
//  however busy the jobs beside it, within a bound.
//

import Testing
import Foundation
@testable import CryoframeKit

private let start = Date(timeIntervalSince1970: 1_790_000_000)
private let v1 = "2026-09-01-020000", v2 = "2026-09-02-020000", v3 = "2026-09-03-020000"

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-kind-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

private func version(in dir: URL, _ name: String, bundle: String = "Photos Library.photoslibrary") throws {
    let at = dir.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: at, withIntermediateDirectories: true)
    let f = at.appendingPathComponent(bundle + ".zip")
    try Data("zip \(UUID())".utf8).write(to: f)
    _ = try ArchiveManifest.write(try ArchiveManifest.build(for: ArchiveResult(artifacts: [f], format: .sealedZip)), toDir: at)
}

private func mirrorTop(in dir: URL, bundle: String = "Photos Library.photoslibrary") throws {
    let sb = dir.appendingPathComponent(bundle + ".sparsebundle")
    try FileManager.default.createDirectory(at: sb.appendingPathComponent("bands"), withIntermediateDirectories: true)
    try Data("band".utf8).write(to: sb.appendingPathComponent("bands/0"))
    _ = try ArchiveManifest.write(try ArchiveManifest.build(for: ArchiveResult(artifacts: [sb], format: .liveMirror)), toDir: dir)
}

private func versions(_ dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { VersionStamp.date($0) != nil }.sorted()
}

@Suite(.serialized) struct KindChangeTests {
    let photos = ContentType.genericFolder(id: "com.apple.photos", displayName: "Photos",
                                           path: .absolute("/Users/someone/Pictures/Photos Library.photoslibrary"))

    // A sealed job made a mirror job keeps its versions: another sealed job of the
    // same library at the destination doesn't take them into its folder (where its
    // retention would delete them), before the changed job has run or after.
    @Test func aSealedJobMadeAMirrorKeepsItsVersions() throws {
        let dest = folder("to-mirror"); defer { try? FileManager.default.removeItem(at: dest) }
        var a = BackupJob(id: "a", name: "Photos A", libraries: [photos], target: .localVolume(id: "d", name: "Dest", dir: dest),
                          format: .sealedZip, frequency: .manual, createdAt: start)
        var b = BackupJob(id: "b", name: "Photos B", libraries: [photos], target: .localVolume(id: "d", name: "Dest", dir: dest),
                          format: .sealedZip, frequency: .manual, createdAt: start)
        b.retention = .keepLast(1)
        let mine = try LibraryFolders.prepare(job: a, library: photos, in: dest, jobs: [a, b], isOpen: { _ in false }).folder
        for v in [v1, v2] { try version(in: mine, v) }

        a.format = .liveMirror(sizeGB: 1)
        let theirs = try LibraryFolders.prepare(job: b, library: photos, in: dest, jobs: [a, b], isOpen: { _ in false }).folder
        #expect(theirs.path != mine.path)
        #expect(versions(mine) == [v1, v2], "taken before the changed job ran")

        #expect(try LibraryFolders.prepare(job: a, library: photos, in: dest, jobs: [a, b], isOpen: { _ in false }).folder.path == mine.path)
        #expect(LibraryIdentity.read(in: mine)?.heldVersions == [v1, v2])
        try mirrorTop(in: mine)
        _ = try LibraryFolders.prepare(job: b, library: photos, in: dest, jobs: [a, b], isOpen: { _ in false })
        try version(in: theirs, v3)
        JobExecutor.pruneVersions(folders: JobExecutor.prunable(b, ["d": [photos.id: theirs]]), policy: b.retention, confirmed: { _, _ in true })
        #expect(versions(mine) == [v1, v2], "taken after the changed job ran")
        #expect(versions(theirs) == [v3])
        #expect(!LibraryFolders.archives(job: b, library: photos, in: dest).contains { [v1, v2].contains($0.dir.lastPathComponent) },
                "the other job reads them as its own")
    }

    // A mirror job made a sealed job: the versions its folder held (another job's) are
    // held, read by that job and not by this one, and this job's own new versions are
    // pruned as usual.
    @Test func aMirrorJobMadeSealedHoldsWhatItsFolderHad() throws {
        let dest = folder("to-sealed"); defer { try? FileManager.default.removeItem(at: dest) }
        let legacy = dest.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try mirrorTop(in: legacy)
        for v in [v1, v2] { try version(in: legacy, v) }
        var m = BackupJob(id: "m", name: "Photos mirror", libraries: [photos], target: .localVolume(id: "d", name: "Dest", dir: dest),
                          format: .liveMirror(sizeGB: 1), frequency: .manual, createdAt: start)
        var s = BackupJob(id: "s", name: "Photos versions", libraries: [photos], target: .localVolume(id: "d", name: "Dest", dir: dest),
                          format: .sealedZip, frequency: .manual, createdAt: start)
        s.enabled = false
        _ = try LibraryFolders.prepare(job: m, library: photos, in: dest, jobs: [m, s], isOpen: { _ in false })
        #expect(LibraryIdentity.read(in: legacy)?.mirror == true)

        m.format = .sealedZip; m.retention = .keepLast(1)
        _ = try LibraryFolders.prepare(job: m, library: photos, in: dest, jobs: [m, s], isOpen: { _ in false })
        #expect(LibraryIdentity.read(in: legacy)?.heldVersions == [v1, v2])
        #expect(LibraryIdentity.read(in: legacy)?.mirror == nil)
        let at = { (d: Int) in VersionStamp.string(start.addingTimeInterval(Double(d) * 86_400)) }
        for d in [1, 2] {
            try version(in: legacy, at(d))
            _ = try LibraryFolders.prepare(job: m, library: photos, in: dest, jobs: [m, s], isOpen: { _ in false })
            JobExecutor.pruneVersions(folders: [(photos, legacy)], policy: m.retention, confirmed: { _, _ in true })
        }
        #expect(versions(legacy) == [v1, v2, at(2)], "its own older version is pruned, the held ones stay")
        #expect(LibraryIdentity.read(in: legacy)?.heldVersions == [v1, v2], "held still, after runs as a sealed job")
        let seen = Set(LibraryFolders.archives(job: s, library: photos, in: dest).map(\.dir.lastPathComponent))
        #expect(seen == [v1, v2], "the paused job reads what may be its own, and not the other job's")
        #expect(LibraryFolders.archives(job: m, library: photos, in: dest).map(\.dir.lastPathComponent) == [at(2)],
                "the changed job reads only its own")
    }

    // The history keeps the runs 1.5 recorded that made versions for a month, all of
    // them (1.5 kept its newest 200), and past that only the cap and the newest good
    // run: a run 1.6 made isn't needed as evidence, as its folders carry their identity.
    @Test func theHistoryKeepsEvidenceWithinABound() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cf-kind-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = RunHistoryStore(url: url, cap: 20)
        let job = BackupJob(name: "Hourly", libraries: [photos], target: .localVolume(id: "d", name: "Dest", dir: URL(fileURLWithPath: "/tmp")),
                            format: .sealedZip, frequency: .everyHours(1), createdAt: start)
        let made = JobOutcome.finished(results: [.completed(library: "Photos", destination: "T7", parts: 1, bytes: 1, verified: true)], warning: nil)
        let old = (0..<200).map { h in
            let at = start.addingTimeInterval(Double(h) * 3600)
            return RunRecord(id: UUID().uuidString, jobID: job.id, jobName: job.name, startedAt: at, finishedAt: at.addingTimeInterval(60),
                             trigger: "scheduled", outcome: .completed, summary: "",
                             libraries: [LibraryOutcome(from: .completed(library: "Photos", destination: "T7", parts: 1, bytes: 1, verified: true))],
                             bytes: 1, warning: nil)
        }
        for r in old.reversed() { store.append(r) }       // the newest first, as 1.5 left them
        let upgraded = start.addingTimeInterval(200 * 3600)
        for h in 0..<(60 * 24) {
            let at = upgraded.addingTimeInterval(Double(h) * 3600)
            store.append(RunRecord.make(job: job, outcome: made, startedAt: at, finishedAt: at.addingTimeInterval(60), trigger: "scheduled"))
            if h == 10 * 24 {
                let all = store.all()
                #expect(all.filter { $0.identityFolders != true }.count == 200, "a month of 1.5's evidence")
                #expect(all.count <= 20 + 1 + 200, "\(all.count) records")
            }
        }
        let all = store.all()
        #expect(all.count <= 20 + 1, "\(all.count) records")
        #expect(!all.contains { $0.identityFolders != true }, "1.5's evidence ages out")
    }
}
