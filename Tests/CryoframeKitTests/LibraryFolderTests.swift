//
//  LibraryFolderTests.swift
//  CryoframeKitTests
//
//  Library folders found by identity, not name: new folders, 1.5 folders taken over
//  in place, folders two jobs shared, names that follow a rename, a run that died
//  half way, a return to 1.5.6 and back, and what Restore finds.
//

import Testing
import Foundation
@testable import CryoframeKit

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-libf-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

/// a stand-in archive (no disk image tools): a sealed version folder, or a mirror at
/// the folder's top, each with its manifest
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

private func lib(_ id: String, _ name: String, root: String? = nil) -> ContentType {
    .genericFolder(id: id, displayName: name, path: .absolute("/Users/someone/\(root ?? name)"))
}

private func job(_ id: String, _ libs: [ContentType], dest: URL, mirror: Bool = false) -> BackupJob {
    BackupJob(id: id, name: "Job \(id)", libraries: libs, target: .localVolume(id: "d", name: "Dest", dir: dest),
              format: mirror ? .liveMirror(sizeGB: 1) : .sealedZip, frequency: .manual, createdAt: Date(timeIntervalSince1970: 0))
}

private let v1 = "2026-09-01-020000", v2 = "2026-09-02-020000", v3 = "2026-09-03-020000"
private func names(_ dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
}

@Suite struct LibraryFolderTests {

    // MARK: versions beside a mirror

    // A folder holding a mirror and sealed versions (a 1.5 folder two jobs shared) was
    // a leaf to discovery: the manifest at its top hid every version under it.
    @Test func versionsBesideAMirrorAreFound() throws {
        let dest = folder("leaf"); defer { try? FileManager.default.removeItem(at: dest) }
        let legacy = dest.appendingPathComponent("Photos")
        try archive(in: legacy, bundle: "Photos Library.photoslibrary", mirror: true)
        try archive(in: legacy, bundle: "Photos Library.photoslibrary", version: v1)
        try archive(in: legacy, bundle: "Photos Library.photoslibrary", version: v3)
        let found = RestoreDiscovery.scan(dest)
        #expect(found.count == 3, "\(found.map(\.dir.lastPathComponent))")
        #expect(RestoreDiscovery.scan(legacy).count == 3)
    }
}
