//
//  CopyMismatchTests.swift
//  CryoframeKitTests
//
//  A sealed version copied to a destination is checked against the build it came
//  from. A copy damaged on the way (a bad cable or hub) is found, split or not, and
//  its version folder goes: left there, its manifest, hashed from the damaged copy,
//  passed every later check, and the Keep rule counted it as the newest version.
//

import Testing
import Foundation
@testable import CryoframeKit

private func tempDir(_ tag: String) -> URL {
    let d = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        .appendingPathComponent("cf-mismatch-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func randomFile(_ url: URL, bytes: Int) throws {
    var data = Data(count: bytes)
    data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, bytes) }
    try data.write(to: url)
}

/// flip one byte of `url` at `offset`, keeping its size
private func damage(_ url: URL, at offset: UInt64) throws {
    let h = try FileHandle(forUpdating: url)
    defer { try? h.close() }
    try h.seek(toOffset: offset)
    let byte = try h.read(upToCount: 1) ?? Data([0])
    try h.seek(toOffset: offset)
    try h.write(contentsOf: Data([byte[0] ^ 0xFF]))
}

@Suite(.serialized) struct CopyMismatchTests {

    // split(1) is byte-exact, so the joined parts hash to the build's digest: a part
    // damaged on the way, whose size is still right, is caught.
    @Test func aDamagedPartOfASplitCopyDoesNotMatchTheBuild() throws {
        let base = tempDir("split")
        defer { try? FileManager.default.removeItem(at: base) }
        let built = base.appendingPathComponent("build/Docs.zip")
        try FileManager.default.createDirectory(at: built.deletingLastPathComponent(), withIntermediateDirectories: true)
        try randomFile(built, bytes: 10_000)
        let digest = try Checksum.sha256(of: built)
        let dest = base.appendingPathComponent("dest/2026-10-29_10-00-00")
        let result = try SealedArchiveEngine(.zip, split: .maxBytes(4_000)).distribute(builtFile: built, into: dest, encrypted: false)
        try #require(result.artifacts.count == 3)
        #expect(JobExecutor.copyMatches(result, expectedDigest: digest, expectedBytes: 10_000))

        try damage(result.artifacts[1], at: 100)
        #expect(!JobExecutor.copyMatches(result, expectedDigest: digest, expectedBytes: 10_000),
                "a split copy with a damaged part was taken for the build")
    }

    // A copy that doesn't match is removed with its manifest, so nothing later takes
    // it for a version: not a check, not the Keep rule, not Restore.
    @Test(arguments: [false, true]) func aCopyThatDoesNotMatchTheBuildIsRemoved(_ split: Bool) throws {
        let base = tempDir("remove")
        defer { try? FileManager.default.removeItem(at: base) }
        let built = base.appendingPathComponent("build/Docs.zip")
        try FileManager.default.createDirectory(at: built.deletingLastPathComponent(), withIntermediateDirectories: true)
        try randomFile(built, bytes: 10_000)
        let digest = try Checksum.sha256(of: built)
        // what reached the drive: another file of the same size, its manifest hashed
        // from it, as distribute writes it
        let arrived = base.appendingPathComponent("arrived/Docs.zip")
        try FileManager.default.createDirectory(at: arrived.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: built, to: arrived)
        try damage(arrived, at: 5_000)
        let library = base.appendingPathComponent("dest/Docs")
        let version = library.appendingPathComponent("2026-10-29_10-00-00")
        let engine = SealedArchiveEngine(.zip, split: split ? .maxBytes(4_000) : .none)
        let result = try engine.distribute(builtFile: arrived, into: version, encrypted: false)
        #expect(try ChecksumVerifier().reverify(archiveDir: version).passed, "the damaged copy's own manifest passes it")

        #expect(!JobExecutor.confirmCopy(result, in: version, expectedDigest: digest, expectedBytes: 10_000))
        #expect(!FileManager.default.fileExists(atPath: version.path), "the damaged version was left in place")
        #expect(RestoreDiscovery.archive(at: version) == nil)
    }

    // A copy that matches is left as it is.
    @Test func aCopyThatMatchesIsKept() throws {
        let base = tempDir("keep")
        defer { try? FileManager.default.removeItem(at: base) }
        let built = base.appendingPathComponent("build/Docs.zip")
        try FileManager.default.createDirectory(at: built.deletingLastPathComponent(), withIntermediateDirectories: true)
        try randomFile(built, bytes: 10_000)
        let version = base.appendingPathComponent("dest/Docs/2026-10-29_10-00-00")
        let result = try SealedArchiveEngine(.zip, split: .maxBytes(4_000)).distribute(builtFile: built, into: version, encrypted: false)
        #expect(JobExecutor.confirmCopy(result, in: version, expectedDigest: try Checksum.sha256(of: built), expectedBytes: 10_000))
        #expect(try ChecksumVerifier().reverify(archiveDir: version).passed)
    }
}
