//
//  SnapshotCoordinator.swift
//  CryoframeKit
//
//  GUI-side orchestration of one backup run over the PrivilegedHelper XPC seam.
//  The reader closure runs in the FDA process (it walks the frozen mount); the
//  helper owns create/mount/unmount/delete. Teardown is guaranteed even if the
//  reader throws — this is the whole point of owning the snapshot lifecycle.
//

import Foundation
import CryoframeShared

public struct SnapshotCoordinator: Sendable {
    let helper: PrivilegedHelper
    public init(helper: PrivilegedHelper) { self.helper = helper }

    /// freeze `volume`, hand the read-only mount to `reader`, then always tear
    /// down. `ownerUID` is the FDA user that must be able to read the mount.
    @discardableResult
    public func withFrozenSnapshot<T: Sendable>(
        of volume: VolumeRef,
        ownerUID: uid_t,
        _ reader: @Sendable (MountRef) async throws -> T
    ) async throws -> T {
        let snapshot = try await helper.createSnapshot(on: volume)

        let mount: MountRef
        do {
            mount = try await helper.mountSnapshot(snapshot, ownerUID: ownerUID)
        } catch {
            // mount failed — don't leak the snapshot.
            try? await helper.deleteSnapshot(snapshot)
            throw error
        }

        do {
            let result = try await reader(mount)
            try await tearDown(mount, snapshot)   // surface teardown errors on success
            return result
        } catch {
            try? await tearDown(mount, snapshot)  // best-effort on the failure path
            throw error
        }
    }

    private func tearDown(_ mount: MountRef, _ snapshot: SnapshotRef) async throws {
        try await helper.unmount(mount)
        try await helper.deleteSnapshot(snapshot)
    }
}
