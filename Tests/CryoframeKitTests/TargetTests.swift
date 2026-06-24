//
//  TargetTests.swift
//  CryoframeKitTests
//
//  Target constraints, availability preflight, engine selection, and the
//  preflight-gates-the-run wiring (fake-backed, no root).
//

import Testing
import Foundation
@testable import CryoframeKit
import CryoframeShared

private func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-tgt-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private final class RecordingEngine: ArchiveEngine, @unchecked Sendable {
    var ran = false
    func archive(_ source: ArchiveSource, to destinationDir: URL) throws -> ArchiveResult {
        ran = true
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        let a = destinationDir.appendingPathComponent("out.zip"); try Data("z".utf8).write(to: a)
        return ArchiveResult(artifacts: [a], format: .sealedZip)
    }
}

// MARK: - constraints

@Test func cloudTargetCapsTriggerSplitButLocalDoesNot() {
    let cloud = Target.cloudSyncFolder(id: "c", name: "OneDrive", dir: URL(fileURLWithPath: "/c"))
    let local = Target.localVolume(id: "l", name: "Disk", dir: URL(fileURLWithPath: "/l"))
    #expect(cloud.constraints.splitPolicy == .maxBytes(240 * 1_000_000_000))
    #expect(local.constraints.splitPolicy == .none)
}

// MARK: - preflight

@Test func preflightFailsForUnmountedShare() {
    let target = Target.networkShare(id: "n", name: "NAS", dir: URL(fileURLWithPath: "/Volumes/NAS/backups"),
                                     mount: NetworkMountSpec(url: URL(string: "smb://nas/backups")!,
                                                             mountpoint: "/Volumes/NAS-not-here-\(UUID().uuidString)"))
    let avail = FileSystemTargetProbe().availability(of: target)
    #expect(!avail.ok)
    #expect(avail.reason?.contains("not mounted") == true)
}

@Test func preflightPassesForWritableLocalDir() {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let target = Target.localVolume(id: "l", name: "Disk", dir: dir)
    #expect(FileSystemTargetProbe().availability(of: target).ok)
}

// MARK: - engine selection

@Test func engineFactoryRejectsLiveMirrorOnNonIncrementalTarget() {
    let target = Target.networkShare(id: "n", name: "NAS", dir: URL(fileURLWithPath: "/Volumes/NAS"),
                                     mount: NetworkMountSpec(url: URL(string: "smb://nas/s")!, mountpoint: "/Volumes/NAS"),
                                     supportsIncremental: false)
    #expect(throws: TargetError.self) {
        _ = try EngineFactory.engine(for: .liveMirror(sizeGB: 100), target: target)
    }
}

// MARK: - targeted run wiring

@Test func targetedRunGatesOnAvailabilityAndNeverTouchesSnapshot() async throws {
    let helper = FakePrivilegedHelper()
    let engine = RecordingEngine()
    let runner = TargetedBackupRunner(
        backup: BackupRunner(helper: helper, locator: ContentLocator(exists: { _ in true })),
        probe: FakeTargetProbe(TargetAvailability(reachable: false, writable: false, reason: "offline")),
        engineProvider: { _, _ in engine })

    let target = Target.localVolume(id: "l", name: "Disk", dir: URL(fileURLWithPath: "/nope"))
    await #expect(throws: TargetError.self) {
        try await runner.run(.photos, format: .sealedZip, to: target, ownerUID: 501)
    }
    #expect(!engine.ran)
    #expect(await helper.calls.isEmpty)                 // no snapshot was even created
}

@Test func targetedRunProceedsWhenAvailable() async throws {
    let helper = FakePrivilegedHelper()
    let engine = RecordingEngine()
    let out = tempDir(); defer { try? FileManager.default.removeItem(at: out) }
    let runner = TargetedBackupRunner(
        backup: BackupRunner(helper: helper, locator: ContentLocator(exists: { _ in true })),
        probe: FakeTargetProbe(TargetAvailability(reachable: true, writable: true)),
        engineProvider: { _, _ in engine })

    let target = Target.localVolume(id: "l", name: "Disk", dir: out)
    let outcome = try await runner.run(.photos, format: .sealedZip, to: target, ownerUID: 501)

    #expect(engine.ran)
    #expect(FileManager.default.fileExists(atPath: outcome.manifestURL.path))
    #expect(await helper.calls == ["create", "mount", "unmount", "delete"])
}
