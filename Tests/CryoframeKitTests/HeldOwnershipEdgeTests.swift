//
//  HeldOwnershipEdgeTests.swift
//  CryoframeKitTests
//
//  Whose a held version is, across mirror -> sealed -> mirror -> sealed with
//  another job's versions arriving in between (as 1.5.6 writes them into a
//  mirror job's folder), and the same from an identity written before
//  ownHeldVersions was recorded.
//

import Testing
import Foundation
@testable import CryoframeKit

private let start = Date(timeIntervalSince1970: 1_790_000_000)
private let a1 = "2026-09-03-020000", b1 = "2026-09-01-020000", b2 = "2026-09-04-020000"
private let bundle = "Photos Library.photoslibrary"

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-heldedge-\(tag)-\(UUID().uuidString.prefix(8))")
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

@Suite(.serialized) struct HeldOwnershipEdgeTests {
    let photos = ContentType.genericFolder(id: "com.apple.photos", displayName: "Photos",
                                           path: .absolute("/Users/someone/Pictures/Photos Library.photoslibrary"))

    private func read(_ job: BackupJob, _ dest: URL) -> Set<String> {
        Set(LibraryFolders.archives(job: job, library: photos, in: dest).compactMap { $0.version.map(VersionStamp.string) })
    }

    // Job A: mirror, sealed, mirror, sealed. Job B (sealed, same library name) has a
    // version 1.5.6 wrote into A's folder at each mirror stage. A only ever reads its
    // own a1; B always reads b1 and b2 and never a1; A's retention never deletes
    // anything of B's. With `legacyIdentity`, the identity A's folder had after its
    // first change to sealed is rewritten without ownHeldVersions (a file from before
    // it was recorded).
    @Test(arguments: [false, true])
    func ownershipHoldsAcrossFourChangesOfKind(legacyIdentity: Bool) throws {
        let dest = folder("four"); defer { try? FileManager.default.removeItem(at: dest) }
        var a = BackupJob(id: "a", name: "Photos A", libraries: [photos], target: .localVolume(id: "d", name: "Dest", dir: dest),
                          format: .liveMirror(sizeGB: 1), frequency: .manual, createdAt: start)
        var b = BackupJob(id: "b", name: "Photos B", libraries: [photos], target: .localVolume(id: "d", name: "Dest", dir: dest),
                          format: .sealedZip, frequency: .manual, createdAt: start)
        a.retention = .keepLast(1); b.retention = .keepLast(5)
        func prepA() throws -> URL { try LibraryFolders.prepare(job: a, library: photos, in: dest, jobs: [a, b], isOpen: { _ in false }).folder }

        // 1. mirror job; 1.5.6 writes B's b1 into its folder
        let mine = try prepA()
        try mirrorTop(in: mine)
        try version(in: mine, b1)
        #expect(read(b, dest).contains(b1))

        // 2. sealed; A makes a1
        a.format = .sealedZip
        #expect(try prepA() == mine)
        try version(in: mine, a1)
        if legacyIdentity {
            var id = try #require(LibraryIdentity.read(in: mine))
            id.ownHeldVersions = nil
            try id.write(in: mine)
        }
        #expect(read(a, dest) == [a1], "stage 2: A reads only its own")
        #expect(read(b, dest).contains(b1) && !read(b, dest).contains(a1), "stage 2: B reads b1, not a1")
        JobExecutor.pruneVersions(folders: JobExecutor.prunable(a, ["d": [photos.id: mine]]), policy: a.retention, confirmed: { _, _ in true })
        #expect(versions(mine) == [b1, a1].sorted(), "stage 2: nothing of B's pruned")

        // 3. mirror again; 1.5.6 writes b2
        a.format = .liveMirror(sizeGB: 1)
        #expect(try prepA() == mine)
        try version(in: mine, b2)
        let seen3 = read(b, dest)
        #expect(seen3.isSuperset(of: [b1, b2]) && !seen3.contains(a1), "stage 3: B reads \(seen3.sorted())")

        // 4. sealed again
        a.format = .sealedZip
        #expect(try prepA() == mine)
        let id4 = try #require(LibraryIdentity.read(in: mine))
        #expect(id4.owns(a1) && !id4.owns(b1) && !id4.owns(b2), "stage 4: held \(id4.heldVersions ?? []), own \(id4.ownHeldVersions ?? [])")
        #expect(read(a, dest) == [a1], "stage 4: A reads \(read(a, dest).sorted())")
        let seen4 = read(b, dest)
        #expect(seen4.isSuperset(of: [b1, b2]) && !seen4.contains(a1), "stage 4: B reads \(seen4.sorted())")
        JobExecutor.pruneVersions(folders: JobExecutor.prunable(a, ["d": [photos.id: mine]]), policy: a.retention, confirmed: { _, _ in true })
        #expect(versions(mine) == [a1, b1, b2].sorted(), "stage 4: nothing pruned")

        // B's own run: nothing of A's taken, B's still readable
        let theirs = try LibraryFolders.prepare(job: b, library: photos, in: dest, jobs: [a, b], isOpen: { _ in false }).folder
        #expect(!versions(theirs).contains(a1))
        #expect(versions(mine).contains(a1))
        #expect(read(b, dest).isSuperset(of: [b1, b2]))
    }
}
