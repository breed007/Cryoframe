//
//  HeldOwnershipTests.swift
//  CryoframeKitTests
//
//  Whose a held version is (a job's own, or another job's) is settled when it is
//  held and kept, however often the job is changed between a mirror and sealed
//  versions after that. Held keeps a version from the folder's own retention; it
//  never hides a version from the job it belongs to.
//

import Testing
import Foundation
@testable import CryoframeKit

private let start = Date(timeIntervalSince1970: 1_790_000_000)
private let v1 = "2026-09-01-020000", v2 = "2026-09-02-020000"
private let bundle = "Photos Library.photoslibrary"

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-own-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

private func version(in dir: URL, _ name: String) throws {
    let at = dir.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: at, withIntermediateDirectories: true)
    let f = at.appendingPathComponent(bundle + ".zip")
    try Data("zip \(UUID())".utf8).write(to: f)
    _ = try ArchiveManifest.write(try ArchiveManifest.build(for: ArchiveResult(artifacts: [f], format: .sealedZip)), toDir: at)
}

private func mirrorTop(in dir: URL) throws {
    let sb = dir.appendingPathComponent(bundle + ".sparsebundle")
    try FileManager.default.createDirectory(at: sb.appendingPathComponent("bands"), withIntermediateDirectories: true)
    try Data("band".utf8).write(to: sb.appendingPathComponent("bands/0"))
    _ = try ArchiveManifest.write(try ArchiveManifest.build(for: ArchiveResult(artifacts: [sb], format: .liveMirror)), toDir: dir)
}

private func versions(_ dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { VersionStamp.date($0) != nil }.sorted()
}

@Suite(.serialized) struct HeldOwnershipTests {
    let photos = ContentType.genericFolder(id: "com.apple.photos", displayName: "Photos",
                                           path: .absolute("/Users/someone/Pictures/Photos Library.photoslibrary"))

    private func jobs(_ dest: URL) -> (a: BackupJob, b: BackupJob) {
        let a = BackupJob(id: "a", name: "Photos A", libraries: [photos], target: .localVolume(id: "d", name: "Dest", dir: dest),
                          format: .sealedZip, frequency: .manual, createdAt: start)
        var b = BackupJob(id: "b", name: "Photos B", libraries: [photos], target: .localVolume(id: "d", name: "Dest", dir: dest),
                          format: .sealedZip, frequency: .manual, createdAt: start)
        b.retention = .keepLast(1)
        return (a, b)
    }

    // A sealed job's versions, the job made a mirror job, a sealed job, and a mirror
    // job again: they are its own throughout. As a sealed job it reads them (checks,
    // drills, storage) and its retention leaves them; as a mirror job again another
    // sealed job neither reads them nor takes them.
    @Test func aJobsOwnVersionsStayItsOwnThroughEveryChange() throws {
        let dest = folder("own"); defer { try? FileManager.default.removeItem(at: dest) }
        var (a, b) = jobs(dest)
        let mine = try LibraryFolders.prepare(job: a, library: photos, in: dest, jobs: [a, b], isOpen: { _ in false }).folder
        for v in [v1, v2] { try version(in: mine, v) }
        a.format = .liveMirror(sizeGB: 1)
        _ = try LibraryFolders.prepare(job: a, library: photos, in: dest, jobs: [a, b], isOpen: { _ in false })
        try mirrorTop(in: mine)
        #expect(LibraryIdentity.read(in: mine)?.ownHeldVersions == [v1, v2])

        a.format = .sealedZip
        _ = try LibraryFolders.prepare(job: a, library: photos, in: dest, jobs: [a, b], isOpen: { _ in false })
        #expect(Set(LibraryFolders.archives(job: a, library: photos, in: dest).compactMap { $0.version.map(VersionStamp.string) }) == [v1, v2],
                "the job reads its own held versions")
        a.retention = .keepLast(1)
        JobExecutor.pruneVersions(folders: JobExecutor.prunable(a, ["d": [photos.id: mine]]), policy: a.retention)
        #expect(versions(mine) == [v1, v2], "held: its retention leaves them")

        a.format = .liveMirror(sizeGB: 1)
        _ = try LibraryFolders.prepare(job: a, library: photos, in: dest, jobs: [a, b], isOpen: { _ in false })
        let theirs = try LibraryFolders.prepare(job: b, library: photos, in: dest, jobs: [a, b], isOpen: { _ in false }).folder
        #expect(versions(mine) == [v1, v2], "not taken by another job")
        #expect(versions(theirs).isEmpty)
        #expect(LibraryFolders.archives(job: b, library: photos, in: dest).isEmpty, "not read by another job")
    }

    // An identity written before whose held versions are was recorded: a held version
    // is the job's own when the folder is a mirror job's (not taken or read by another
    // job), and another job's when it is a sealed job's (read by the other job).
    @Test func heldVersionsWithoutARecordReadAsBefore() throws {
        let dest = folder("old"); defer { try? FileManager.default.removeItem(at: dest) }
        var (a, b) = jobs(dest)
        a.format = .liveMirror(sizeGB: 1)
        let mine = try LibraryFolders.prepare(job: a, library: photos, in: dest, jobs: [a, b], isOpen: { _ in false }).folder
        try mirrorTop(in: mine)
        for v in [v1, v2] { try version(in: mine, v) }
        var id = try #require(LibraryIdentity.read(in: mine))
        id.heldVersions = [v1]
        try id.write(in: mine)
        #expect(!id.owns(v2) && id.owns(v1))

        _ = try LibraryFolders.prepare(job: b, library: photos, in: dest, jobs: [a, b], isOpen: { _ in false })
        #expect(versions(mine) == [v1], "the job's own held version stays; the other moves home")

        id.mirror = nil
        #expect(!id.owns(v1), "held in a sealed job's folder: another job's")
    }
}
