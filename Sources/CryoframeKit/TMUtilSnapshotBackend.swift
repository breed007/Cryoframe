//
//  TMUtilSnapshotBackend.swift
//  CryoframeKit
//
//  Ships now. Creates snapshots via `tmutil localsnapshot` (no entitlement),
//  mounts via `mount_apfs`, deletes via `tmutil deletelocalsnapshots`. The
//  snapshot lives in Time Machine's namespace, so "ours" is identified by a
//  before/after set-diff and the helper tracks what it created. Purge-mid-run is
//  neutralized by mounting immediately (an active mount pins the data).
//

import Foundation
import CryoframeShared

public struct TMUtilSnapshotBackend: SnapshotBackend {
    static let tmName = "com.apple.TimeMachine."          // namespace we create into
    static let mountBase = "/private/var/run/app.cryoframe/mnt"

    let runner: CommandRunner
    public init(runner: CommandRunner = ProcessCommandRunner()) { self.runner = runner }

    // MARK: SnapshotBackend

    public func create(on volume: VolumeRef) throws -> SnapshotRef {
        let before = Self.parseSnapshotNames(try listOutput())
        try sh("/usr/bin/tmutil", ["localsnapshot", "/"])
        let after = Self.parseSnapshotNames(try listOutput())
        guard let name = Self.identifyNewSnapshot(before: before, after: after) else {
            throw SnapshotBackendError.couldNotIdentifyNewSnapshot
        }
        return SnapshotRef(name: name, volume: volume, createdAt: Date())
    }

    public func mount(_ snapshot: SnapshotRef, ownerUID: uid_t) throws -> MountRef {
        let dev = try resolvedDevice(snapshot.volume)
        let mnt = "\(Self.mountBase)/\(Int(snapshot.createdAt.timeIntervalSince1970))-\(ProcessInfo.processInfo.globallyUniqueString.prefix(8))"
        try FileManager.default.createDirectory(
            atPath: mnt, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        // read-only snapshot mount; ownership preserved so ownerUID can traverse.
        try sh("/sbin/mount_apfs", ["-o", "rdonly", "-s", snapshot.name, dev, mnt])
        return MountRef(mountPoint: mnt, snapshot: snapshot)
    }

    public func unmount(_ mount: MountRef) throws {
        try sh("/sbin/umount", [mount.mountPoint])
        try? FileManager.default.removeItem(atPath: mount.mountPoint)
    }

    public func delete(_ snapshot: SnapshotRef) throws {
        guard let date = Self.snapshotDate(fromName: snapshot.name) else {
            throw SnapshotBackendError.refusedForeignSnapshot(name: snapshot.name)
        }
        try sh("/usr/bin/tmutil", ["deletelocalsnapshots", date])
    }

    public func list(on volume: VolumeRef) throws -> [SnapshotRef] {
        Self.parseSnapshotNames(try listOutput()).map {
            SnapshotRef(name: $0, volume: volume, createdAt: Date(timeIntervalSince1970: 0))
        }
    }

    // MARK: pure helpers (unit-tested with no root)

    /// lines of `tmutil listlocalsnapshots /` that are actual snapshot names.
    public static func parseSnapshotNames(_ output: String) -> [String] {
        output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix(tmName) }
    }

    /// the snapshot present in `after` but not `before`. nil if none (tmutil can
    /// coalesce a same-second snapshot) — caller falls back to newest.
    public static func identifyNewSnapshot(before: [String], after: [String]) -> String? {
        let added = Set(after).subtracting(before)
        if let only = added.sorted().last { return only }
        return after.sorted().last       // coalesced: adopt newest
    }

    /// "com.apple.TimeMachine.2026-06-24-142308.local" -> "2026-06-24-142308".
    /// returns nil for anything not in our create namespace — the delete guard.
    public static func snapshotDate(fromName name: String) -> String? {
        guard name.hasPrefix(tmName), name.hasSuffix(".local") else { return nil }
        let date = String(name.dropFirst(tmName.count).dropLast(".local".count))
        // sanity: YYYY-MM-DD-HHMMSS
        let parts = date.split(separator: "-")
        guard parts.count == 4, date.allSatisfy({ $0.isNumber || $0 == "-" }) else { return nil }
        return date
    }

    // MARK: plumbing

    private func listOutput() throws -> String {
        let r = try runner.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"])
        guard r.ok else { throw SnapshotBackendError.commandFailed(tool: "tmutil", status: r.status, stderr: r.stderr) }
        return r.stdout
    }

    @discardableResult
    private func sh(_ tool: String, _ args: [String]) throws -> String {
        let r = try runner.run(tool, args)
        guard r.ok else {
            throw SnapshotBackendError.commandFailed(tool: (tool as NSString).lastPathComponent,
                                                     status: r.status, stderr: r.stderr)
        }
        return r.stdout
    }

    private func resolvedDevice(_ volume: VolumeRef) throws -> String {
        if !volume.bsdDevice.isEmpty { return volume.bsdDevice }
        let r = try runner.run("/usr/sbin/diskutil", ["info", volume.mountPoint])
        for line in r.stdout.split(separator: "\n") where line.contains("Device Node") {
            if let dev = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces), !dev.isEmpty {
                return dev
            }
        }
        throw SnapshotBackendError.dataVolumeNotFound
    }
}
