//
//  SnapshotLifecycleTests.swift
//  CryoframeKitTests
//
//  Exercises the snapshot lifecycle with fakes — no root, no XPC, no real
//  snapshots. The teardown-on-failure guarantees are the load-bearing ones.
//

import Testing
import Foundation
@testable import CryoframeKit
import CryoframeShared

private let vol = VolumeRef(mountPoint: "/System/Volumes/Data", bsdDevice: "/dev/disk3s5")

// MARK: - SnapshotCoordinator lifecycle

@Test func happyPathRunsInOrderAndTearsDown() async throws {
    let helper = FakePrivilegedHelper()
    let coord = SnapshotCoordinator(helper: helper)

    let read = try await coord.withFrozenSnapshot(of: vol, ownerUID: 501) { mount in
        #expect(mount.mountPoint.contains("app.cryoframe.snap"))
        return "archived"
    }

    #expect(read == "archived")
    #expect(await helper.calls == ["create", "mount", "unmount", "delete"])
    #expect(await helper.liveSnapshots.isEmpty)   // nothing leaked
    #expect(await helper.liveMounts.isEmpty)
}

@Test func readerThrowsButTeardownStillRuns() async throws {
    let helper = FakePrivilegedHelper()
    let coord = SnapshotCoordinator(helper: helper)

    struct ReaderError: Error {}
    await #expect(throws: ReaderError.self) {
        try await coord.withFrozenSnapshot(of: vol, ownerUID: 501) { _ in
            throw ReaderError()
        }
    }
    // create+mount happened, then teardown despite the reader failure
    #expect(await helper.calls == ["create", "mount", "unmount", "delete"])
    #expect(await helper.liveSnapshots.isEmpty)
    #expect(await helper.liveMounts.isEmpty)
}

@Test func mountFailureDeletesSnapshotAndDoesNotUnmount() async throws {
    let helper = FakePrivilegedHelper(failAt: .mount)
    let coord = SnapshotCoordinator(helper: helper)

    await #expect(throws: (any Error).self) {
        try await coord.withFrozenSnapshot(of: vol, ownerUID: 501) { _ in "unreached" }
    }
    // no mount succeeded => no unmount; but the orphan snapshot is deleted
    #expect(await helper.calls == ["create", "mount", "delete"])
    #expect(await helper.liveSnapshots.isEmpty)
}

// MARK: - TMUtil name parsing (pure)

@Test func parsesSnapshotNamesFromTmutilOutput() {
    let out = """
    Snapshots for disk /:
    com.apple.TimeMachine.2026-06-24-044719.local
    com.apple.TimeMachine.2026-06-24-142308.local
    """
    let names = TMUtilSnapshotBackend.parseSnapshotNames(out)
    #expect(names.count == 2)
    #expect(names.last == "com.apple.TimeMachine.2026-06-24-142308.local")
}

@Test func identifiesTheNewlyCreatedSnapshot() {
    let before = ["com.apple.TimeMachine.2026-06-24-044719.local"]
    let after = before + ["com.apple.TimeMachine.2026-06-24-142308.local"]
    #expect(TMUtilSnapshotBackend.identifyNewSnapshot(before: before, after: after)
            == "com.apple.TimeMachine.2026-06-24-142308.local")
}

@Test func coalescedSnapshotFallsBackToNewest() {
    let names = ["com.apple.TimeMachine.2026-06-24-142308.local"]
    // no delta (tmutil coalesced) => adopt newest rather than failing
    #expect(TMUtilSnapshotBackend.identifyNewSnapshot(before: names, after: names) == names[0])
}

@Test func extractsDateAndRejectsForeignNames() {
    #expect(TMUtilSnapshotBackend.snapshotDate(fromName: "com.apple.TimeMachine.2026-06-24-142308.local")
            == "2026-06-24-142308")
    #expect(TMUtilSnapshotBackend.snapshotDate(fromName: "app.cryoframe.snap.123") == nil)
    #expect(TMUtilSnapshotBackend.snapshotDate(fromName: "garbage") == nil)
}

// MARK: - TMUtil delete guard + create wiring (scripted runner, no root)

@Test func deleteRefusesAForeignSnapshotName() {
    let backend = TMUtilSnapshotBackend(runner: ScriptedCommandRunner { _, _ in
        CommandResult(status: 0, stdout: "", stderr: "")
    })
    let foreign = SnapshotRef(name: "not-a-tm-snapshot", volume: vol, createdAt: Date())
    #expect(throws: SnapshotBackendError.self) { try backend.delete(foreign) }
}

@Test func createIdentifiesSnapshotFromBeforeAfterDiff() throws {
    // first listlocalsnapshots -> [A]; localsnapshot -> ""; second list -> [A,B]
    let seq = ListSequencer(outputs: [
        "Snapshots for disk /:\ncom.apple.TimeMachine.2026-06-24-044719.local",
        "Snapshots for disk /:\ncom.apple.TimeMachine.2026-06-24-044719.local\ncom.apple.TimeMachine.2026-06-24-142308.local",
    ])
    let backend = TMUtilSnapshotBackend(runner: ScriptedCommandRunner { tool, args in
        if args.first == "listlocalsnapshots" { return CommandResult(status: 0, stdout: seq.next(), stderr: "") }
        return CommandResult(status: 0, stdout: "", stderr: "")   // localsnapshot
    })
    let snap = try backend.create(on: vol)
    #expect(snap.name == "com.apple.TimeMachine.2026-06-24-142308.local")
}

/// returns successive canned outputs for repeated identical commands.
private final class ListSequencer: @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [String]
    private var i = 0
    init(outputs: [String]) { self.outputs = outputs }
    func next() -> String {
        lock.lock(); defer { lock.unlock() }
        defer { i += 1 }
        return outputs[min(i, outputs.count - 1)]
    }
}
