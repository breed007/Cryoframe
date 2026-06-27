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

// MARK: - directory (sparsebundle) checksums — the mirror manifest fix

@Test func directoryDigestIsStableAndCatchesChanges() throws {
    let fm = FileManager.default
    let base = tmp(); defer { try? fm.removeItem(at: base) }
    let bundle = base.appendingPathComponent("Lib.sparsebundle")
    try fm.createDirectory(at: bundle.appendingPathComponent("bands"), withIntermediateDirectories: true)
    try Data("info".utf8).write(to: bundle.appendingPathComponent("Info.plist"))
    try Data("band-zero".utf8).write(to: bundle.appendingPathComponent("bands/0"))

    let d1 = try Checksum.digest(of: bundle)
    #expect(!d1.isEmpty)
    #expect(try Checksum.digest(of: bundle) == d1)        // stable across calls
    #expect(Checksum.byteSize(of: bundle) > 0)

    try fm.removeItem(at: bundle.appendingPathComponent("bands/0"))   // a dropped band
    #expect(try Checksum.digest(of: bundle) != d1)
}

@Test func manifestBuildsAndVerifiesADirectoryArtifact() throws {
    let fm = FileManager.default
    let base = tmp(); defer { try? fm.removeItem(at: base) }
    let dir = base.appendingPathComponent("out")
    let bundle = dir.appendingPathComponent("Lib.sparsebundle")
    try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
    try Data("token".utf8).write(to: bundle.appendingPathComponent("token"))

    // before the fix this threw (sha256 on a directory); now it works.
    try ArchiveManifest.write(try ArchiveManifest.build(for: ArchiveResult(artifacts: [bundle], format: .liveMirror)), toDir: dir)
    #expect(try ChecksumVerifier().reverify(archiveDir: dir).passed)

    try Data("tampered".utf8).write(to: bundle.appendingPathComponent("token"))
    #expect(try !ChecksumVerifier().reverify(archiveDir: dir).passed)
}

// MARK: - version pruning (filesystem only)

@Test func pruneVersionsKeepsNewestCompleteAndSweepsPartials() throws {
    let fm = FileManager.default
    let base = tmp(); defer { try? fm.removeItem(at: base) }
    let lib = base.appendingPathComponent("target/Photos")
    // four completed versions (have a manifest) …
    for s in ["2026-06-21-120000", "2026-06-22-120000", "2026-06-23-120000", "2026-06-24-120000"] {
        let v = lib.appendingPathComponent(s)
        try fm.createDirectory(at: v, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: v.appendingPathComponent(ArchiveManifest.sidecarName))
    }
    // … and one empty partial from a failed run (no manifest), which is the newest by name.
    try fm.createDirectory(at: lib.appendingPathComponent("2026-06-25-120000"), withIntermediateDirectories: true)

    JobExecutor.pruneVersions(target: base.appendingPathComponent("target"), libraries: [.photos], policy: .keepLast(2))

    let remaining = (try fm.contentsOfDirectory(atPath: lib.path)).sorted()
    // partial swept; the two newest COMPLETE versions kept (not the empty husk).
    #expect(remaining == ["2026-06-23-120000", "2026-06-24-120000"])
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

@Test func healthCheckCatchesTamperedArchive() throws {
    let fm = FileManager.default
    let base = tmp(); defer { try? fm.removeItem(at: base) }
    let lib = try makeLibrary(in: base)
    let target = base.appendingPathComponent("target")
    let versionDir = target.appendingPathComponent("Photos/2026-06-25-120000")
    _ = try archive(.zip, lib, to: versionDir)
    let job = BackupJob(name: "j", libraries: [.photos],
                        target: .localVolume(id: "t", name: "Disk", dir: target),
                        format: .sealedZip, frequency: .manual, createdAt: Date(timeIntervalSince1970: 0))

    var report = HealthChecker().check(job: job)
    #expect(report.checks.count == 1)
    #expect(report.passed)                                          // freshly made, intact

    try Data("corrupted".utf8).write(to: versionDir.appendingPathComponent("MyLib.photoslibrary.zip"))
    report = HealthChecker().check(job: job)
    #expect(!report.passed)                                         // checksum mismatch detected
    #expect(HealthRecord.from(job: job, report: report, at: Date()).failures.count == 1)
}

@Test func restoreMirrorRoundTripsLibrary() throws {
    let base = tmp(); defer { try? FileManager.default.removeItem(at: base) }
    let lib = try makeLibrary(in: base)
    let dir = base.appendingPathComponent("out")
    let result = try SparseBundleMirrorEngine(sizeGB: 1)
        .archive(ArchiveSource(name: lib.lastPathComponent, root: lib), to: dir)
    try ArchiveManifest.write(try ArchiveManifest.build(for: result), toDir: dir)

    let a = try #require(RestoreDiscovery.archive(at: dir))
    #expect(a.format == .liveMirror)
    let restored = try RestoreEngine().restore(a, to: base.appendingPathComponent("restored"))
    #expect(restored.lastPathComponent == "MyLib.photoslibrary")
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

/// build-once-distribute: one sealed archive copied to several destinations, each
/// with a valid manifest, and restorable — proves the multi-destination fast path.
@Test func sealedBuiltOnceDistributesToManyAndEachRestores() throws {
    let base = tmp(); defer { try? FileManager.default.removeItem(at: base) }
    let lib = try makeLibrary(in: base)
    let built = try SealedArchiveEngine(.zip).archive(ArchiveSource(name: lib.lastPathComponent, root: lib),
                                                      to: base.appendingPathComponent("build"))
    let file = try #require(built.artifacts.first)

    let d1 = base.appendingPathComponent("dest1/Photos")
    let d2 = base.appendingPathComponent("dest2/Photos")
    let r1 = try SealedArchiveEngine(.zip).distribute(builtFile: file, into: d1, encrypted: false)
    let r2 = try SealedArchiveEngine(.zip).distribute(builtFile: file, into: d2, encrypted: false)
    #expect(r1.format == .sealedZip && r2.format == .sealedZip)

    // every distributed copy carries a manifest and reverifies clean
    #expect(try ChecksumVerifier().reverify(archiveDir: d1).passed)
    #expect(try ChecksumVerifier().reverify(archiveDir: d2).passed)

    // and a copy restores to the original content
    let arch = try #require(RestoreDiscovery.scan(base.appendingPathComponent("dest2")).first)
    let restored = try RestoreEngine().restore(arch, to: base.appendingPathComponent("restored"))
    let text = try String(contentsOf: restored.appendingPathComponent("database/index.db"), encoding: .utf8)
    #expect(text == "hello")
}

/// a restore drill opens a good archive and fails a corrupt one — proving it exercises
/// the restore path, not just the checksum.
@Test func restoreDrillOpensGoodArchiveAndFailsCorruptOne() throws {
    let base = tmp(); defer { try? FileManager.default.removeItem(at: base) }
    let lib = try makeLibrary(in: base, name: "Docs.bundle")
    let target = base.appendingPathComponent("target")
    _ = try archive(.zip, lib, to: target.appendingPathComponent("Docs"))

    let type = ContentType.genericFolder(id: "docs", displayName: "Docs", path: .absolute(lib.path))
    let job = BackupJob(name: "J", libraries: [type],
                        target: .localVolume(id: "t", name: "Disk", dir: target),
                        format: .sealedZip, frequency: .manual, createdAt: Date(timeIntervalSince1970: 0))

    let good = RestoreDriller().drill(job: job)
    #expect(good.passed)
    #expect(good.checks.count == 1)
    #expect(good.checks.first?.detail.contains("reopened clean") == true)   // it actually opened

    // corrupt the artifact's bytes → the drill catches it at the checksum step
    let dir = target.appendingPathComponent("Docs")
    let zip = try #require(try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .first { $0.pathExtension == "zip" })
    try Data("garbage".utf8).write(to: zip)
    #expect(!RestoreDriller().drill(job: job).passed)
}

}   // RestoreRoundTrips
