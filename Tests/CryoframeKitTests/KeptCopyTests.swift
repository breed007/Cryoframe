//
//  KeptCopyTests.swift
//  CryoframeKitTests
//
//  A format change deletes nothing. A mirror job made a sealed job leaves its
//  up-to-date copy where it was: kept, marked so in the folder's identity, found by
//  Restore (shown as kept), and never read as the job's current copy. Made a mirror
//  job again, its runs keep that copy up to date again.
//

import Testing
import Foundation
@testable import CryoframeKit

private let start = Date(timeIntervalSince1970: 1_790_000_000)
private let bundle = "Photos Library.photoslibrary"

private func scratch(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-kept-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return TempTracker.track(d) }
    defer { free(real) }
    return TempTracker.track(URL(fileURLWithPath: String(cString: real), isDirectory: true))
}

private func mirrorTop(in dir: URL) throws {
    let sb = dir.appendingPathComponent(bundle + ".sparsebundle")
    try FileManager.default.createDirectory(at: sb.appendingPathComponent("bands"), withIntermediateDirectories: true)
    try Data("band".utf8).write(to: sb.appendingPathComponent("bands/0"))
    _ = try ArchiveManifest.write(try ArchiveManifest.build(for: ArchiveResult(artifacts: [sb], format: .liveMirror)), toDir: dir)
}

private func version(in dir: URL, _ name: String) throws {
    let at = dir.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: at, withIntermediateDirectories: true)
    let f = at.appendingPathComponent(bundle + ".zip")
    try Data("zip \(name)".utf8).write(to: f)
    _ = try ArchiveManifest.write(try ArchiveManifest.build(for: ArchiveResult(artifacts: [f], format: .sealedZip)), toDir: at)
}

@Suite struct KeptCopyTests {
    let photos = ContentType.genericFolder(id: "com.apple.photos", displayName: "Photos",
                                           path: .absolute("/Users/someone/Pictures/\(bundle)"))

    @Test func theCopyAMirrorJobLeavesIsMarkedKeptAndNotReadAsCurrent() throws {
        let dest = scratch("mirror")
        var job = BackupJob(id: "a", name: "Photos", libraries: [photos], target: .localVolume(id: "d", name: "Dest", dir: dest),
                            format: .liveMirror(sizeGB: 1), frequency: .manual, createdAt: start)
        let folder = try LibraryFolders.prepare(job: job, library: photos, in: dest, jobs: [job], isOpen: { _ in false }).folder
        try mirrorTop(in: folder)
        #expect(LibraryFolders.kept(in: folder).isEmpty)

        job.format = .sealedZip
        _ = try LibraryFolders.prepare(job: job, library: photos, in: dest, jobs: [job], isOpen: { _ in false })
        let kept = LibraryFolders.kept(in: folder)
        #expect(kept.mirror?.name == bundle + ".sparsebundle")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(bundle + ".sparsebundle").path))
        #expect(LibraryFolders.archives(job: job, library: photos, in: dest).isEmpty)       // not its current copy
        let found = RestoreDiscovery.scan(dest)
        #expect(found.count == 1 && found.allSatisfy(LibraryFolders.isKept))

        // a later run keeps the mark and its date
        let first = kept.mirror?.keptAt
        try version(in: folder, "2026-10-01-020000")
        _ = try LibraryFolders.prepare(job: job, library: photos, in: dest, jobs: [job], isOpen: { _ in false })
        #expect(LibraryFolders.kept(in: folder).mirror?.keptAt == first)
        let newest = LibraryFolders.archives(job: job, library: photos, in: dest)
        #expect(newest.count == 1 && !newest.contains(where: LibraryFolders.isKept))

        // made a mirror job again: its copy is current again
        job.format = .liveMirror(sizeGB: 1)
        _ = try LibraryFolders.prepare(job: job, library: photos, in: dest, jobs: [job], isOpen: { _ in false })
        #expect(LibraryFolders.kept(in: folder).mirror == nil)
        #expect(!RestoreDiscovery.scan(dest).contains { $0.format == .liveMirror && LibraryFolders.isKept($0) })
    }

    @Test func versionsHeldByAFormatChangeAreShownKept() throws {
        let dest = scratch("held")
        var job = BackupJob(id: "a", name: "Photos", libraries: [photos], target: .localVolume(id: "d", name: "Dest", dir: dest),
                            format: .sealedZip, frequency: .manual, createdAt: start)
        let folder = try LibraryFolders.prepare(job: job, library: photos, in: dest, jobs: [job], isOpen: { _ in false }).folder
        try version(in: folder, "2026-09-01-020000")
        job.format = .liveMirror(sizeGB: 1)
        _ = try LibraryFolders.prepare(job: job, library: photos, in: dest, jobs: [job], isOpen: { _ in false })
        #expect(LibraryFolders.kept(in: folder).versions == ["2026-09-01-020000"])
        #expect(RestoreDiscovery.scan(dest).filter { $0.version != nil }.allSatisfy(LibraryFolders.isKept))
    }
}
