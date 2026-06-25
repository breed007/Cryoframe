//
//  PrivilegedHelper.swift
//  CryoframeShared — the privilege seam.
//
//  This is the M1 *contract*, not the implementation. It defines the protocol
//  boundary between the FDA GUI/reader (user) and the root helper, so the
//  privileged backend is swappable and unit-testable with a fake — same shape
//  as Crossbar's PrivilegedToggle.
//
//  Privilege split (see docs/M1-design.md):
//    - root helper  : create / mount / unmount / delete APFS snapshots,
//                     mount network targets. NOTHING that reads library content.
//    - FDA reader   : walks the mounted snapshot tree and builds the archive.
//                     Lives on the user side because root does NOT bypass TCC.
//

import Foundation

// MARK: - Value types (Codable so they cross XPC cleanly)

/// The Data volume to snapshot. `~/Pictures` etc. live here, not on the root volume.
public struct VolumeRef: Codable, Sendable, Equatable {
    /// e.g. "/System/Volumes/Data"
    public var mountPoint: String
    /// e.g. "/dev/disk3s5" — resolved by the helper; carried for logging/reconcile.
    public var bsdDevice: String
    public init(mountPoint: String, bsdDevice: String) {
        self.mountPoint = mountPoint
        self.bsdDevice = bsdDevice
    }
}

/// A snapshot owned entirely by Cryoframe. Name is deterministic:
/// `app.cryoframe.snap.<unix-ts>`. The prefix is how reconcile tells ours from
/// Time Machine's — we never touch `com.apple.TimeMachine.*`.
public struct SnapshotRef: Codable, Sendable, Equatable {
    public var name: String          // app.cryoframe.snap.1719240000
    public var volume: VolumeRef
    public var createdAt: Date
    public init(name: String, volume: VolumeRef, createdAt: Date) {
        self.name = name; self.volume = volume; self.createdAt = createdAt
    }
}

/// A live read-only mount of a snapshot.
public struct MountRef: Codable, Sendable, Equatable {
    public var mountPoint: String    // /private/var/run/app.cryoframe/mnt/<ts>, mode 0755
    public var snapshot: SnapshotRef
    public init(mountPoint: String, snapshot: SnapshotRef) {
        self.mountPoint = mountPoint; self.snapshot = snapshot
    }
}

public struct HelperInfo: Codable, Sendable {
    public var version: String       // helper build, must match GUI's expectation
    public var pid: Int32
    public init(version: String, pid: Int32) { self.version = version; self.pid = pid }
}

/// What reconcile-on-launch cleaned up after a crashed run.
public struct ReconcileReport: Codable, Sendable {
    public var unmounted: [String]   // stale mountpoints torn down
    public var deletedSnapshots: [String]
    public init(unmounted: [String], deletedSnapshots: [String]) {
        self.unmounted = unmounted; self.deletedSnapshots = deletedSnapshots
    }
}

/// Network target to mount as root (M5 — declared now so the contract is stable).
public struct NetworkTargetSpec: Codable, Sendable {
    public var url: URL              // smb:// afp:// etc.
    public var mountPoint: String
    public init(url: URL, mountPoint: String) { self.url = url; self.mountPoint = mountPoint }
}

public enum HelperError: Error, Codable, Sendable {
    case notAuthorized
    case versionMismatch(helper: String, expected: String)
    case snapshotCreateFailed(errno: Int32)
    case mountFailed(errno: Int32)
    case unmountFailed(errno: Int32)
    case deleteFailed(errno: Int32)
    case refusedForeignSnapshot(name: String)   // guard: someone asked us to touch a non-cryoframe snapshot
    case volumeNotFound(String)
    case internalError(String)
}

// MARK: - The swappable seam (Swift-facing, async)

/// The GUI talks to this. Real impl wraps NSXPCConnection to the root daemon;
/// `FakePrivilegedHelper` lets the snapshot lifecycle be unit-tested with no root.
public protocol PrivilegedHelper: Sendable {
    func handshake() async throws -> HelperInfo

    /// 1. freeze: fs_snapshot_create on the Data volume with a deterministic name.
    func createSnapshot(on volume: VolumeRef) async throws -> SnapshotRef

    /// 2. mount read-only. `ownerUID` is the FDA user that must be able to
    ///    traverse the mountpoint to read the frozen library.
    func mountSnapshot(_ snapshot: SnapshotRef, ownerUID: uid_t) async throws -> MountRef

    /// 5a. tear down the mount (after the FDA reader is done archiving).
    func unmount(_ mount: MountRef) async throws

    /// 5b. delete the snapshot. Refuses any name without the app.cryoframe.snap. prefix.
    func deleteSnapshot(_ snapshot: SnapshotRef) async throws

    /// reconcile: list our snapshots (for the GUI), used to detect orphans.
    func listSnapshots(on volume: VolumeRef) async throws -> [SnapshotRef]

    /// 6. reconcile-on-launch: sweep stale mounts + orphan app.cryoframe.snap.* snapshots.
    func reconcile() async throws -> ReconcileReport

    /// M5: mount a network target as root. Declared now to freeze the contract.
    func mountNetworkTarget(_ spec: NetworkTargetSpec) async throws -> MountRef

    /// ask the daemon to exit so launchd respawns the updated on-disk binary. The
    /// on-demand daemon otherwise runs resident forever (dispatchMain) and an app
    /// update never takes effect until reboot. Called only at app launch (no job
    /// in flight). Old helpers predating this method just error — caller falls back.
    func reloadForUpdate() async throws
}

// MARK: - XPC wire protocol (NSXPCConnection needs @objc + reply blocks)

/// The over-the-wire face. `XPCPrivilegedHelper` (GUI side) adapts this to the
/// async `PrivilegedHelper` above; the daemon vends an object conforming to it.
/// Codable payloads cross as Data to avoid a sprawling NSSecureCoding surface.
@objc public protocol CryoframeHelperXPC {
    func handshake(reply: @escaping (Data?, Error?) -> Void)
    func createSnapshot(volume: Data, reply: @escaping (Data?, Error?) -> Void)
    func mountSnapshot(snapshot: Data, ownerUID: uid_t, reply: @escaping (Data?, Error?) -> Void)
    func unmount(mount: Data, reply: @escaping (Error?) -> Void)
    func deleteSnapshot(snapshot: Data, reply: @escaping (Error?) -> Void)
    func listSnapshots(volume: Data, reply: @escaping (Data?, Error?) -> Void)
    func reconcile(reply: @escaping (Data?, Error?) -> Void)
    func mountNetworkTarget(spec: Data, reply: @escaping (Data?, Error?) -> Void)
    func reloadForUpdate(reply: @escaping (Error?) -> Void)
}

public enum CryoframeHelper {
    /// Mach service name the daemon registers and the GUI connects to.
    public static let machServiceName = "app.cryoframe.helper"
    /// Deterministic snapshot-name prefix — the reconcile ownership boundary.
    public static let snapshotPrefix = "app.cryoframe.snap."
}
