//
//  VerificationTests.swift
//  CryoframeKitTests
//
//  Checksum + manifest (cheap / periodic mode) and real mount-and-open strong
//  verification against a tiny sqlite "library" fixture (no root needed).
//

import Testing
import Foundation
@testable import CryoframeKit

private func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-vrf-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// a minimal Photos-shaped library: database/Photos.sqlite, valid or corrupt.
private func makeLibraryFixture(valid: Bool) throws -> URL {
    let lib = tempDir()
    let dbDir = lib.appendingPathComponent("database")
    try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
    let db = dbDir.appendingPathComponent("Photos.sqlite")
    if valid {
        let r = try ProcessCommandRunner().run("/usr/bin/sqlite3",
            [db.path, "CREATE TABLE asset(id INTEGER PRIMARY KEY, name TEXT); INSERT INTO asset(name) VALUES('a'),('b');"])
        #expect(r.ok)
    } else {
        try Data([UInt8](repeating: 0xFF, count: 4096)).write(to: db)   // not a database
    }
    return lib
}

private let liveDBType = ContentType(id: "test.photos", displayName: "TestPhotos", paths: [],
                                     owningProcess: nil, kind: .liveDB, integrityProbe: "database/Photos.sqlite")

// MARK: - checksum + manifest

@Test func sha256MatchesKnownVector() throws {
    let f = tempDir().appendingPathComponent("abc.txt")
    try Data("abc".utf8).write(to: f)
    #expect(try Checksum.sha256(of: f) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
}

@Test func manifestRoundTripsAndVerifies() throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    try Data("hello".utf8).write(to: dir.appendingPathComponent("a.bin"))
    try Data("world".utf8).write(to: dir.appendingPathComponent("b.bin"))
    let result = ArchiveResult(artifacts: [dir.appendingPathComponent("a.bin"),
                                           dir.appendingPathComponent("b.bin")], format: .sealedZip)

    let manifest = try ArchiveManifest.build(for: result)
    #expect(manifest.artifacts.count == 2)
    let url = try ArchiveManifest.write(manifest, toDir: dir)
    #expect(try ArchiveManifest.read(url) == manifest)
    #expect(try ChecksumVerifier().verify(manifest, in: dir).passed)
    #expect(try ChecksumVerifier().reverify(archiveDir: dir).passed)        // sidecar path
}

@Test func checksumVerifyDetectsTamperAndMissing() throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let a = dir.appendingPathComponent("a.bin")
    try Data("hello".utf8).write(to: a)
    let manifest = try ArchiveManifest.build(for: ArchiveResult(artifacts: [a], format: .sealedZip))

    try Data("HELLO world".utf8).write(to: a)                              // tamper
    #expect(!(try ChecksumVerifier().verify(manifest, in: dir).passed))

    try FileManager.default.removeItem(at: a)                              // missing
    let rep = try ChecksumVerifier().verify(manifest, in: dir)
    #expect(!rep.passed)
    #expect(rep.failures.contains { $0.contains("missing") })
}

// MARK: - mount-and-open (real)

@Test func strongVerifyDMGReopensCleanLibrary() throws {
    let lib = try makeLibraryFixture(valid: true); defer { try? FileManager.default.removeItem(at: lib) }
    let out = tempDir(); defer { try? FileManager.default.removeItem(at: out) }
    let result = try SealedArchiveEngine(.dmg).archive(ArchiveSource(name: "Lib", root: lib), to: out)

    let rep = try StrongVerifier().verify(result, type: liveDBType)
    #expect(rep.level == .mountAndOpen)
    #expect(rep.passed)
}

@Test func strongVerifyDMGDetectsCorruptLibrary() throws {
    let lib = try makeLibraryFixture(valid: false); defer { try? FileManager.default.removeItem(at: lib) }
    let out = tempDir(); defer { try? FileManager.default.removeItem(at: out) }
    let result = try SealedArchiveEngine(.dmg).archive(ArchiveSource(name: "Lib", root: lib), to: out)

    let rep = try StrongVerifier().verify(result, type: liveDBType)
    #expect(!rep.passed)
}

@Test func strongVerifyZipFindsLibraryUnderKeepParent() throws {
    let lib = try makeLibraryFixture(valid: true); defer { try? FileManager.default.removeItem(at: lib) }
    let out = tempDir(); defer { try? FileManager.default.removeItem(at: out) }
    let result = try SealedArchiveEngine(.zip).archive(ArchiveSource(name: "Lib", root: lib), to: out)

    let rep = try StrongVerifier().verify(result, type: liveDBType)   // probe is one level down in a zip
    #expect(rep.passed)
}

@Test func strongVerifyStaticRootPassesWhenNonEmpty() throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    try Data("x".utf8).write(to: dir.appendingPathComponent("file.txt"))
    let out = tempDir(); defer { try? FileManager.default.removeItem(at: out) }
    let result = try SealedArchiveEngine(.dmg).archive(ArchiveSource(name: "Docs", root: dir), to: out)

    let staticType = ContentType.genericFolder(id: "d", displayName: "Docs", path: .home("Docs"))
    let rep = try StrongVerifier().verify(result, type: staticType)
    #expect(rep.passed)
}
