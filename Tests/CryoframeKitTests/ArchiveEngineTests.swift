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
    #expect(c.args == ["-a", "--delete", "--partial", "/m/lib/", "/v/lib/"])
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
