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
    public static let mountBase = "/private/var/run/app.cryoframe/mnt"

    /// true only for a path genuinely inside the directory we mount snapshots into.
    /// The helper runs umount, `diskutil unmount force` and removeItem on whatever
    /// path a caller hands it, so this is what keeps that to mounts we made.
    ///
    /// Deliberately LEXICAL. Foundation's standardizedFileURL resolves /private/var
    /// to /var only when the path already exists, so the base normalised and a mount
    /// point under it did not — the guard rejected every legitimate unmount, which
    /// would have leaked mounts and walked straight back into the orphaned-device
    /// spiral 1.5.1 fixed. A containment check must not depend on what happens to be
    /// on disk at the instant it runs; that is also how these checks get raced.
    public static func isOwnMountPoint(_ path: String) -> Bool {
        let base = canonicalPath(mountBase), p = canonicalPath(path)
        return p != base && p.hasPrefix(base + "/")
    }

    /// resolve `.`, `..` and separator noise without touching the filesystem, and
    /// fold macOS's /private aliases so /private/var and /var compare equal.
    public static func canonicalPath(_ s: String) -> String {
        var out: [String] = []
        for comp in s.split(separator: "/", omittingEmptySubsequences: true) {
            switch comp {
            case ".":  continue
            case "..": if !out.isEmpty { out.removeLast() }
            default:   out.append(String(comp))
            }
        }
        if out.count >= 2, out[0] == "private", ["var", "tmp", "etc"].contains(out[1]) { out.removeFirst() }
        return "/" + out.joined(separator: "/")
    }

    let runner: CommandRunner
    public init(runner: CommandRunner = ProcessCommandRunner()) { self.runner = runner }

    // MARK: SnapshotBackend

    public func create(on volume: VolumeRef) throws -> SnapshotRef {
        // tmutil works per volume. This used to always say "/", so asking for a
        // snapshot of an external drive silently froze the boot disk instead and the
        // library was nowhere to be found inside it.
        let target = Self.tmutilPath(for: volume)
        let before = Self.parseSnapshotNames(try listOutput(target))
        try sh("/usr/bin/tmutil", ["localsnapshot", target])
        let after = Self.parseSnapshotNames(try listOutput(target))
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
        // after a Stop, the archiver may still be releasing the mount, so umount
        // returns "Resource busy". Retry briefly, then force with diskutil.
        for attempt in 0..<6 {
            if let r = try? runner.run("/sbin/umount", [mount.mountPoint]), r.ok {
                try? FileManager.default.removeItem(atPath: mount.mountPoint); return
            }
            if attempt < 5 { Thread.sleep(forTimeInterval: 0.5) }
        }
        let forced = try runner.run("/usr/sbin/diskutil", ["unmount", "force", mount.mountPoint])
        guard forced.ok else {
            throw SnapshotBackendError.commandFailed(tool: "diskutil", status: forced.status, stderr: forced.stderr)
        }
        try? FileManager.default.removeItem(atPath: mount.mountPoint)
    }

    public func delete(_ snapshot: SnapshotRef) throws {
        guard let date = Self.snapshotDate(fromName: snapshot.name) else {
            throw SnapshotBackendError.refusedForeignSnapshot(name: snapshot.name)
        }
        // `deletelocalsnapshots` takes EITHER a mount point (drop every snapshot on
        // that volume) OR a date (drop that one, wherever it lives). We want the date:
        // passing both, or passing the volume, would delete more than we made.
        try sh("/usr/bin/tmutil", ["deletelocalsnapshots", date])
    }

    /// the path tmutil wants for a volume: "/" for the boot disk (its data half is
    /// mounted at /System/Volumes/Data, which tmutil does not accept), the mount
    /// point for anything else.
    public static func tmutilPath(for volume: VolumeRef) -> String {
        let m = volume.mountPoint
        return (m.isEmpty || m == "/" || m == "/System/Volumes/Data") ? "/" : m
    }

    public func list(on volume: VolumeRef) throws -> [SnapshotRef] {
        Self.parseSnapshotNames(try listOutput(Self.tmutilPath(for: volume))).map {
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

    private func listOutput(_ volumePath: String = "/") throws -> String {
        let r = try runner.run("/usr/bin/tmutil", ["listlocalsnapshots", volumePath])
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
