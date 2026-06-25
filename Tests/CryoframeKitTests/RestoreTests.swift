//
//  RestoreTests.swift
//  CryoframeKitTests
//
//  Bundle-name recovery, archive discovery, and real archive→restore round trips
//  (zip via ditto, dmg via hdiutil) — the library comes back byte-for-byte and
//  with its wrapper folder intact.
//

import Testing
import Foundation
@testable import CryoframeKit

private func tmp() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-restore-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// build a fake library folder with one nested file; returns (libraryURL, name).
private func makeLibrary(in base: URL, name: String = "MyLib.photoslibrary") throws -> URL {
    let lib = base.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: lib.appendingPathComponent("database"), withIntermediateDirectories: true)
    try Data("hello".utf8).write(to: lib.appendingPathComponent("database/index.db"))
    return lib
}

private func archive(_ kind: SealedArchiveEngine.Sealed, _ lib: URL, to dir: URL) throws -> RestorableArchive {
    let result = try SealedArchiveEngine(kind).archive(ArchiveSource(name: lib.lastPathComponent, root: lib), to: dir)
    try ArchiveManifest.write(try ArchiveManifest.build(for: result), toDir: dir)
    return try #require(RestoreDiscovery.archive(at: dir))
}

// MARK: - bundle name

@Test func bundleNameStripsSplitSuffixAndExtension() {
    func name(_ artifacts: [String]) -> String {
        RestorableArchive(dir: URL(fileURLWithPath: "/x"), libraryName: "L", format: .sealedDMG, bytes: 0, artifactNames: artifacts).bundleName
    }
    #expect(name(["Photos Library.photoslibrary.dmg"]) == "Photos Library.photoslibrary")
    #expect(name(["Photos Library.photoslibrary.dmg.part.000", "….part.001"]) == "Photos Library.photoslibrary")
    #expect(name(["Music.zip"]) == "Music")
    #expect(name(["Music.sparsebundle"]) == "Music")
}

// MARK: - version pruning (filesystem only)

@Test func pruneVersionsKeepsNewestPerPolicy() throws {
    let fm = FileManager.default
    let base = tmp(); defer { try? fm.removeItem(at: base) }
    let lib = base.appendingPathComponent("target/Photos")
    let stamps = ["2026-06-21-120000", "2026-06-22-120000", "2026-06-23-120000", "2026-06-24-120000", "2026-06-25-120000"]
    for s in stamps { try fm.createDirectory(at: lib.appendingPathComponent(s), withIntermediateDirectories: true) }

    JobExecutor.pruneVersions(target: base.appendingPathComponent("target"), libraries: [.photos], policy: .keepLast(2))

    let remaining = (try fm.contentsOfDirectory(atPath: lib.path)).sorted()
    #expect(remaining == ["2026-06-24-120000", "2026-06-25-120000"])
}

// MARK: - discovery + round trips
//
// Serialized: each spawns hdiutil/ditto, and running many disk-image operations at
// once makes hdiutil return "Resource busy". Serializing keeps the suite stable.

@Suite(.serialized) struct RestoreRoundTrips {

@Test func discoveryFindsArchivesInSubfolders() throws {
    let base = tmp(); defer { try? FileManager.default.removeItem(at: base) }
    let lib = try makeLibrary(in: base)
    _ = try archive(.zip, lib, to: base.appendingPathComponent("out/Photos"))

    let found = RestoreDiscovery.scan(base.appendingPathComponent("out"))
    #expect(found.count == 1)
    #expect(found.first?.libraryName == "Photos")
    #expect(found.first?.format == .sealedZip)
    #expect(RestoreDiscovery.scan(base.appendingPathComponent("nope")).isEmpty)
}

// MARK: - round trips

@Test func restoreZipRoundTripsLibraryWithWrapper() throws {
    let base = tmp(); defer { try? FileManager.default.removeItem(at: base) }
    let a = try archive(.zip, try makeLibrary(in: base), to: base.appendingPathComponent("out"))
    #expect(a.bundleName == "MyLib.photoslibrary")

    let restored = try RestoreEngine().restore(a, to: base.appendingPathComponent("restored"))
    #expect(restored.lastPathComponent == "MyLib.photoslibrary")
    let text = try String(contentsOf: restored.appendingPathComponent("database/index.db"), encoding: .utf8)
    #expect(text == "hello")
}

@Test func restoreDmgRebuildsWrapperFromFlattenedContents() throws {
    let base = tmp(); defer { try? FileManager.default.removeItem(at: base) }
    let a = try archive(.dmg, try makeLibrary(in: base), to: base.appendingPathComponent("out"))

    let restored = try RestoreEngine().restore(a, to: base.appendingPathComponent("restored"))
    #expect(restored.lastPathComponent == "MyLib.photoslibrary")     // wrapper rebuilt
    let text = try String(contentsOf: restored.appendingPathComponent("database/index.db"), encoding: .utf8)
    #expect(text == "hello")
}

@Test func restoreRefusesToOverwriteExisting() throws {
    let base = tmp(); defer { try? FileManager.default.removeItem(at: base) }
    let a = try archive(.zip, try makeLibrary(in: base), to: base.appendingPathComponent("out"))
    let into = base.appendingPathComponent("restored")
    _ = try RestoreEngine().restore(a, to: into)
    #expect(throws: RestoreError.self) { try RestoreEngine().restore(a, to: into) }   // already there
}

// MARK: - encryption

@Test func encryptedDmgOpensWithPassphraseAndRejectsWrongOne() throws {
    let base = tmp(); defer { try? FileManager.default.removeItem(at: base) }
    let lib = try makeLibrary(in: base)
    let result = try SealedArchiveEngine(.dmg, passphrase: "s3cret-pass")
        .archive(ArchiveSource(name: lib.lastPathComponent, root: lib), to: base.appendingPathComponent("out"))

    #expect(throws: (any Error).self) { _ = try ArchiveReader().open(result, passphrase: "wrong") }

    let opened = try ArchiveReader().open(result, passphrase: "s3cret-pass")
    defer { opened.close() }
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: opened.root.path)) ?? []
    #expect(!entries.isEmpty)            // mounted with the right key; layout handled by RestoreEngine
}

@Test func restoreEncryptedArchiveEndToEnd() throws {
    let base = tmp(); defer { try? FileManager.default.removeItem(at: base) }
    let lib = try makeLibrary(in: base)
    let dir = base.appendingPathComponent("out")
    let result = try SealedArchiveEngine(.dmg, passphrase: "pw")
        .archive(ArchiveSource(name: lib.lastPathComponent, root: lib), to: dir)
    try ArchiveManifest.write(try ArchiveManifest.build(for: result, encrypted: true), toDir: dir)

    let a = try #require(RestoreDiscovery.archive(at: dir))
    #expect(a.encrypted)
    let restored = try RestoreEngine().restore(a, to: base.appendingPathComponent("restored"), passphrase: "pw")
    #expect(try String(contentsOf: restored.appendingPathComponent("database/index.db"), encoding: .utf8) == "hello")
}

@Test func discoveryFindsVersionedArchivesNewestFirst() throws {
    let base = tmp(); defer { try? FileManager.default.removeItem(at: base) }
    let lib = try makeLibrary(in: base)
    let libDir = base.appendingPathComponent("target/Photos")
    _ = try archive(.zip, lib, to: libDir.appendingPathComponent("2026-06-24-120000"))
    _ = try archive(.zip, lib, to: libDir.appendingPathComponent("2026-06-25-120000"))

    let found = RestoreDiscovery.scan(base.appendingPathComponent("target"))
    #expect(found.count == 2)
    #expect(found.allSatisfy { $0.libraryName == "Photos" && $0.version != nil })
    #expect((found[0].version ?? .distantPast) > (found[1].version ?? .distantPast))   // newest first
}

}   // RestoreRoundTrips
