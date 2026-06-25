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

/// A reported 0 (network shares, many non-APFS volumes) means "this filesystem
/// doesn't answer," not "the disk is full." If we read 0 as full we false-fail
/// every NAS backup with "only Zero KB free" — the regression that shipped in the
/// free-space preflight.
@Test func usableFreeTreatsZeroAsUnknownNotFull() {
    #expect(JobExecutor.usableFree(importantUsage: 0, available: 0) == nil)        // share answers all-zero
    #expect(JobExecutor.usableFree(importantUsage: nil, available: nil) == nil)    // key absent
    #expect(JobExecutor.usableFree(importantUsage: 0, available: 500) == 500)      // fall back to plain avail
    #expect(JobExecutor.usableFree(importantUsage: 1_000, available: 9) == 1_000)  // prefer important-usage
    #expect(JobExecutor.usableFree(importantUsage: nil, available: 42) == 42)
}

/// A live volume that genuinely reports space still gates correctly.
@Test func freeSpaceReturnsAPositiveNumberForTheBootVolume() {
    let free = JobExecutor.freeSpace(for: URL(fileURLWithPath: NSHomeDirectory()))
    #expect(free != nil && free! > 0)
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

// MARK: - run gating

@Test func executorGatesOnAvailabilityAndNeverTouchesSnapshot() async throws {
    let helper = FakePrivilegedHelper()
    let exec = JobExecutor(helper: helper, detector: FakeProcessDetector(),
                           probe: FakeTargetProbe(TargetAvailability(reachable: false, writable: false, reason: "offline")))
    let j = BackupJob(name: "gated", libraries: [.photos],
                      target: .localVolume(id: "l", name: "Disk", dir: URL(fileURLWithPath: "/nope")),
                      format: .sealedZip, frequency: .manual, createdAt: Date(timeIntervalSince1970: 0))

    await #expect(throws: TargetError.self) {
        try await exec.run(j, ownerUID: 501, now: Date(timeIntervalSince1970: 0))
    }
    #expect(await helper.calls.isEmpty)                 // preflight failed before any snapshot
}
