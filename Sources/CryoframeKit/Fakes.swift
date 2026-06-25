//
//  Fakes.swift
//  CryoframeKit
//
//  Test doubles for the privilege seam. Let the lifecycle be exercised with no
//  root, no XPC, no real snapshots. Mirrors Crossbar's fake-backed PrivilegedToggle.
//

import Foundation
import CryoframeShared

/// Records the call sequence so tests can assert teardown ordering, and can be
/// told to fail at a chosen stage.
public actor FakePrivilegedHelper: PrivilegedHelper {
    public enum Stage: String, Sendable { case create, mount, unmount, delete }

    public private(set) var calls: [String] = []
    public private(set) var liveSnapshots: Set<String> = []
    public private(set) var liveMounts: Set<String> = []
    private let failAt: Stage?
    private var counter = 0

    public init(failAt: Stage? = nil) { self.failAt = failAt }

    struct Boom: Error {}

    private func record(_ s: String) { calls.append(s) }
    private func maybeFail(_ stage: Stage) throws { if failAt == stage { throw Boom() } }

    public func handshake() async throws -> HelperInfo { HelperInfo(version: "fake", pid: 0) }

    public func createSnapshot(on volume: VolumeRef) async throws -> SnapshotRef {
        record("create"); try maybeFail(.create)
        counter += 1
        let name = "app.cryoframe.snap.\(counter)"
        liveSnapshots.insert(name)
        return SnapshotRef(name: name, volume: volume, createdAt: Date(timeIntervalSince1970: 0))
    }

    public func mountSnapshot(_ snapshot: SnapshotRef, ownerUID: uid_t) async throws -> MountRef {
        record("mount"); try maybeFail(.mount)
        let mp = "/tmp/fake/\(snapshot.name)"
        liveMounts.insert(mp)
        return MountRef(mountPoint: mp, snapshot: snapshot)
    }

    public func unmount(_ mount: MountRef) async throws {
        record("unmount"); try maybeFail(.unmount)
        liveMounts.remove(mount.mountPoint)
    }

    public func deleteSnapshot(_ snapshot: SnapshotRef) async throws {
        record("delete"); try maybeFail(.delete)
        liveSnapshots.remove(snapshot.name)
    }

    public func listSnapshots(on volume: VolumeRef) async throws -> [SnapshotRef] {
        liveSnapshots.sorted().map { SnapshotRef(name: $0, volume: volume, createdAt: Date(timeIntervalSince1970: 0)) }
    }

    public func reconcile() async throws -> ReconcileReport {
        let unmounted = Array(liveMounts); let deleted = Array(liveSnapshots)
        liveMounts.removeAll(); liveSnapshots.removeAll()
        return ReconcileReport(unmounted: unmounted, deletedSnapshots: deleted)
    }

    public func mountNetworkTarget(_ spec: NetworkTargetSpec) async throws -> MountRef {
        MountRef(mountPoint: spec.mountPoint,
                 snapshot: SnapshotRef(name: "n/a", volume: VolumeRef(mountPoint: "", bsdDevice: ""),
                                       createdAt: Date(timeIntervalSince1970: 0)))
    }

    public func reloadForUpdate() async throws {}
    public func scheduleWake(at date: Date?) async throws {}
}

/// Scriptable CommandRunner for backend tests — maps argv to canned results.
public struct ScriptedCommandRunner: CommandRunner {
    let handler: @Sendable (_ launchPath: String, _ args: [String]) -> CommandResult
    public init(_ handler: @escaping @Sendable (_ launchPath: String, _ args: [String]) -> CommandResult) {
        self.handler = handler
    }
    public func run(_ launchPath: String, _ args: [String]) throws -> CommandResult {
        handler(launchPath, args)
    }
}
