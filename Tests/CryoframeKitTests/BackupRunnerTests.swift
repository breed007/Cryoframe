//
//  BackupRunnerTests.swift
//  CryoframeKitTests
//
//  The M1+M2+M3 wiring: a backup run archives the located library FROM the
//  snapshot mount, seals a checksum manifest, then tears down — even on failure.
//

import Testing
import Foundation
@testable import CryoframeKit
import CryoframeShared

/// records what it was asked to archive and writes a real artifact so the
/// manifest can be built.
private final class RecordingEngine: ArchiveEngine, @unchecked Sendable {
    var lastSource: ArchiveSource?
    var shouldThrow = false
    func archive(_ source: ArchiveSource, to destinationDir: URL) throws -> ArchiveResult {
        lastSource = source
        if shouldThrow { throw ArchiveError.noArtifactProduced(destinationDir) }
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        let artifact = destinationDir.appendingPathComponent(source.name + ".zip")
        try Data("archive".utf8).write(to: artifact)
        return ArchiveResult(artifacts: [artifact], format: .sealedZip)
    }
}

private func tempOut() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("cf-bk-\(UUID().uuidString)")
}

@Test func backupRunArchivesFromMountAndSealsManifest() async throws {
    let helper = FakePrivilegedHelper()
    let locator = ContentLocator(home: "/Users/breed", user: "breed", exists: { _ in true })
    let engine = RecordingEngine()
    let out = tempOut(); defer { try? FileManager.default.removeItem(at: out) }

    let outcome = try await BackupRunner(helper: helper, locator: locator)
        .run(.photos, engine: engine, to: out, ownerUID: 501)

    let root = try #require(engine.lastSource?.root.path)
    #expect(root.contains("/tmp/fake/"))                                   // archived from the mount
    #expect(root.hasSuffix("/Users/breed/Pictures/Photos Library.photoslibrary"))
    #expect(outcome.result.format == .sealedZip)
    #expect(FileManager.default.fileExists(atPath: outcome.manifestURL.path))  // checksum always
    #expect(outcome.strong == nil)                                         // checksumOnly default
    #expect(await helper.calls == ["create", "mount", "unmount", "delete"])
    #expect(await helper.liveSnapshots.isEmpty)
}

@Test func backupRunTearsDownEvenIfArchivingFails() async throws {
    let helper = FakePrivilegedHelper()
    let locator = ContentLocator(home: "/Users/breed", user: "breed", exists: { _ in true })
    let engine = RecordingEngine(); engine.shouldThrow = true
    let out = tempOut(); defer { try? FileManager.default.removeItem(at: out) }

    await #expect(throws: ArchiveError.self) {
        try await BackupRunner(helper: helper, locator: locator).run(.photos, engine: engine, to: out, ownerUID: 501)
    }
    #expect(await helper.calls == ["create", "mount", "unmount", "delete"])
    #expect(await helper.liveSnapshots.isEmpty)
}

@Test func backupRunThrowsWhenLibraryAbsentFromSnapshot() async throws {
    let helper = FakePrivilegedHelper()
    let locator = ContentLocator(home: "/Users/breed", user: "breed", exists: { _ in false })
    let out = tempOut(); defer { try? FileManager.default.removeItem(at: out) }

    await #expect(throws: BackupError.self) {
        try await BackupRunner(helper: helper, locator: locator).run(.photos, engine: RecordingEngine(), to: out, ownerUID: 501)
    }
    #expect(await helper.calls == ["create", "mount", "unmount", "delete"])  // still tears down
}
