//
//  ArchiveEngineTests.swift
//  CryoframeKitTests
//
//  Pure command-planner argv checks + real end-to-end runs against tiny temp
//  fixtures (no root, no snapshot — engines are source-agnostic).
//

import Testing
import Foundation
import Security
@testable import CryoframeKit

// MARK: - fixtures

private func makeFixture(bytes: Int) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cf-fixt-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var buf = [UInt8](repeating: 0, count: bytes)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &buf)   // incompressible → predictable sizes
    try Data(buf).write(to: dir.appendingPathComponent("payload.bin"))
    return dir
}

private func tempOutDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("cf-out-\(UUID().uuidString)")
}

// MARK: - pure planners (argv)

@Test func dmgPlanIsReadOnlyUDZO() {
    let c = ArchivePlan.dmg(root: URL(fileURLWithPath: "/m/lib"),
                            output: URL(fileURLWithPath: "/out/Lib.dmg"))
    #expect(c.tool == "/usr/bin/hdiutil")
    #expect(c.args == ["create", "-srcfolder", "/m/lib", "-format", "UDZO", "-ov", "/out/Lib.dmg"])
}

@Test func splitPlanUsesByteCapAndPrefix() {
    let c = ArchivePlan.split(file: URL(fileURLWithPath: "/out/Lib.dmg"),
                              cap: 524_288, prefix: "/out/Lib.dmg.part.")
    #expect(c.tool == "/usr/bin/split")
    #expect(c.args == ["-b", "524288", "/out/Lib.dmg", "/out/Lib.dmg.part."])
}

@Test func zipPlanUsesDittoWithMetadataFlags() {
    let c = ArchivePlan.zip(root: URL(fileURLWithPath: "/m/lib"), output: URL(fileURLWithPath: "/out/Lib.zip"))
    #expect(c.tool == "/usr/bin/ditto")
    #expect(c.args == ["-c", "-k", "--sequesterRsrc", "--keepParent", "/m/lib", "/out/Lib.zip"])
}

@Test func sparseBundleCreatePlanHasBandSizeAndAPFS() {
    let c = ArchivePlan.sparseBundleCreate(output: URL(fileURLWithPath: "/out/M.sparsebundle"),
                                           name: "M", sizeGB: 500, bandSectors: 16384)
    #expect(c.args.contains("SPARSEBUNDLE"))
    #expect(c.args.contains("APFS"))
    #expect(c.args.contains("sparse-band-size=16384"))
    #expect(c.args.contains("-size") && c.args.contains("500g"))
}

@Test func rsyncPlanIsArchiveDeleteWithTrailingSlashes() {
    let c = ArchivePlan.rsync(root: URL(fileURLWithPath: "/m/lib"), into: URL(fileURLWithPath: "/v/lib"))
    #expect(c.tool == "/usr/bin/rsync")
    #expect(c.args == ["-aE", "--delete", "--partial", "/m/lib/", "/v/lib/"])
}

/// The argv check above would keep passing if -E stopped meaning what we think it
/// means, so this runs the real tool. A mirror that drops extended attributes and
/// resource forks is not a copy of the library — it is a copy of the file contents
/// with the Finder tags, and anything else macOS keeps beside a file, thrown away.
@Test func theMirrorSyncCarriesExtendedAttributesAndResourceForks() throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("cf-xattr-\(UUID().uuidString)")
    let src = base.appendingPathComponent("src"), dst = base.appendingPathComponent("dst")
    defer { try? fm.removeItem(at: base) }
    try fm.createDirectory(at: src, withIntermediateDirectories: true)
    try fm.createDirectory(at: dst, withIntermediateDirectories: true)

    let file = src.appendingPathComponent("photo.jpg")
    try "content".write(to: file, atomically: true, encoding: .utf8)
    try #require("tagged".withCString { setxattr(file.path, "com.apple.metadata:cf_test", $0, strlen($0), 0, 0) } == 0)
    try Data("RESOURCEFORK".utf8).write(to: file.appendingPathComponent("..namedfork/rsrc"))

    let plan = ArchivePlan.rsync(root: src, into: dst)
    let r = try ProcessCommandRunner().run(plan.tool, plan.args)
    try #require(r.ok, "rsync failed: \(r.stderr)")

    let copied = dst.appendingPathComponent("photo.jpg")
    var value = [CChar](repeating: 0, count: 64)
    let got = getxattr(copied.path, "com.apple.metadata:cf_test", &value, 64, 0, 0)
    #expect(got > 0, "extended attribute did not survive the sync")
    let fork = (try? Data(contentsOf: copied.appendingPathComponent("..namedfork/rsrc")))?.count ?? 0
    #expect(fork == 12, "resource fork did not survive the sync (\(fork) bytes)")
}

/// An existing mirror was written without -E, so its files already lack the
/// metadata. They must heal on the next run even though their size and mtime are
/// unchanged — otherwise a library whose files never change never recovers.
@Test func anExistingMirrorRegainsMetadataWithoutAFullResync() throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("cf-heal-\(UUID().uuidString)")
    let src = base.appendingPathComponent("src"), dst = base.appendingPathComponent("dst")
    defer { try? fm.removeItem(at: base) }
    try fm.createDirectory(at: src, withIntermediateDirectories: true)
    try fm.createDirectory(at: dst, withIntermediateDirectories: true)

    let file = src.appendingPathComponent("photo.jpg")
    try "content".write(to: file, atomically: true, encoding: .utf8)
    try #require("tagged".withCString { setxattr(file.path, "com.apple.metadata:cf_test", $0, strlen($0), 0, 0) } == 0)

    // the 1.5 mirror: -a, which drops the attribute
    let runner = ProcessCommandRunner()
    _ = try runner.run("/usr/bin/rsync", ["-a", "--delete", src.path + "/", dst.path + "/"])
    let copied = dst.appendingPathComponent("photo.jpg")
    var probe = [CChar](repeating: 0, count: 64)
    #expect(getxattr(copied.path, "com.apple.metadata:cf_test", &probe, 64, 0, 0) < 0)

    // the next run under 1.5.1 repairs it, with the file otherwise untouched
    let plan = ArchivePlan.rsync(root: src, into: dst)
    let r = try runner.run(plan.tool, plan.args)
    try #require(r.ok, "rsync failed: \(r.stderr)")
    #expect(getxattr(copied.path, "com.apple.metadata:cf_test", &probe, 64, 0, 0) > 0,
            "an existing mirror never regains its metadata")
}

// MARK: - real runs

@Test func sealedZipProducesArtifact() throws {
    let src = try makeFixture(bytes: 40_000); defer { try? FileManager.default.removeItem(at: src) }
    let out = tempOutDir(); defer { try? FileManager.default.removeItem(at: out) }

    let result = try SealedArchiveEngine(.zip).archive(ArchiveSource(name: "Lib", root: src), to: out)
    #expect(result.format == .sealedZip)
    #expect(result.artifacts.count == 1)
    #expect(FileManager.default.fileExists(atPath: result.artifacts[0].path))
}

@Test func sealedDMGProducesValidImage() throws {
    let src = try makeFixture(bytes: 40_000); defer { try? FileManager.default.removeItem(at: src) }
    let out = tempOutDir(); defer { try? FileManager.default.removeItem(at: out) }

    let result = try SealedArchiveEngine(.dmg).archive(ArchiveSource(name: "Lib", root: src), to: out)
    #expect(result.format == .sealedDMG)
    #expect(result.artifacts.count == 1)
    // hdiutil imageinfo validates it's a real image, without mounting.
    let info = try ProcessCommandRunner().run("/usr/bin/hdiutil", ["imageinfo", result.artifacts[0].path])
    #expect(info.ok)
}

@Test func sealedDMGSplitsIntoParts() throws {
    let src = try makeFixture(bytes: 2_000_000); defer { try? FileManager.default.removeItem(at: src) }
    let out = tempOutDir(); defer { try? FileManager.default.removeItem(at: out) }

    let result = try SealedArchiveEngine(.dmg, split: .maxBytes(512 * 1024))
        .archive(ArchiveSource(name: "Lib", root: src), to: out)
    #expect(result.artifacts.count > 1)                         // split into volumes
    #expect(result.artifacts.allSatisfy { $0.lastPathComponent.contains(".dmg.part.") })
    #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("Lib.dmg").path)) // original gone
}

@Test func sealedZipSplitsIntoPartsAndRemovesOriginal() throws {
    let src = try makeFixture(bytes: 200_000); defer { try? FileManager.default.removeItem(at: src) }
    let out = tempOutDir(); defer { try? FileManager.default.removeItem(at: out) }

    let result = try SealedArchiveEngine(.zip, split: .maxBytes(64_000))
        .archive(ArchiveSource(name: "Lib", root: src), to: out)
    #expect(result.artifacts.count > 1)
    #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("Lib.zip").path)) // original gone
    #expect(result.artifacts.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
}

@Test func sparseBundleMirrorRunsAndIsIncremental() throws {
    let src = try makeFixture(bytes: 40_000); defer { try? FileManager.default.removeItem(at: src) }
    let out = tempOutDir(); defer { try? FileManager.default.removeItem(at: out) }
    let engine = SparseBundleMirrorEngine(sizeGB: 1)

    let first = try engine.archive(ArchiveSource(name: "Mirror", root: src), to: out)
    #expect(first.format == .liveMirror)
    #expect(FileManager.default.fileExists(atPath: first.artifacts[0].path))
    #expect(first.artifacts[0].lastPathComponent == "Mirror.sparsebundle")

    // second run is incremental: bundle already exists, no error, same artifact.
    let second = try engine.archive(ArchiveSource(name: "Mirror", root: src), to: out)
    #expect(second.artifacts == first.artifacts)
}
