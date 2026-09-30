//
//  SnapshotReconciler.swift
//  CryoframeKit
//
//  Cleans up snapshot mounts and snapshots a crashed run left behind. The root
//  helper runs this; it lives here so it can be tested with a fake backend.
//

import Foundation
import CryoframeShared

public struct SnapshotReconciler {
    /// the helper build that records owners and keeps what live processes own. The
    /// helper reports it in its handshake; see LeftoverCleanup.minimumHelperVersion.
    public static let helperVersion = "1.6.0"

    let backend: SnapshotBackend
    let ledger: SnapshotLedger
    let owners: SnapshotOwners
    let mountBase: String
    let dataVolume: VolumeRef
    let isAlive: (ProcessIdentity) -> Bool
    let now: Date
    let legacyGrace: TimeInterval
    /// where a recorded volume is mounted now, if it is (nil: unplugged)
    let locate: (SnapshotOwners.Volume) -> VolumeRef?

    public init(backend: SnapshotBackend, ledger: SnapshotLedger, owners: SnapshotOwners,
                mountBase: String, dataVolume: VolumeRef,
                isAlive: @escaping (ProcessIdentity) -> Bool = { $0.isAlive },
                now: Date = Date(), legacyGrace: TimeInterval = 72 * 3600,
                locate: @escaping (SnapshotOwners.Volume) -> VolumeRef? = SnapshotOwners.Volume.mounted) {
        self.backend = backend; self.ledger = ledger; self.owners = owners
        self.mountBase = mountBase; self.dataVolume = dataVolume
        self.isAlive = isAlive; self.now = now; self.legacyGrace = legacyGrace; self.locate = locate
    }

    /// Unmount and delete what a run left behind when its process died. Anything
    /// whose owner is still alive is kept: the helper can't see run locks, but the
    /// process holding a job's lock is the process that asked for its snapshot, and
    /// the kernel keeps the lock exactly as long as that process lives. A leftover
    /// with no recorded owner (made by a helper older than 1.6) is kept until it is
    /// older than any run could be.
    /// Unmount and delete what a run left behind when its process died. Anything
    /// whose owner is still alive is kept: the helper can't see run locks, but the
    /// process holding a job's run lock is the process that asked for its snapshot, and
    /// the kernel keeps the lock exactly as long as that process lives. A leftover
    /// with no recorded owner (made by a helper older than 1.6) is kept until it is
    /// older than any run could be.
    ///
    /// `snapshotLock` is the helper's lock around create, mount and delete. It is held
    /// while deciding and while deleting, never while unmounting: forcing off a stuck
    /// mount takes seconds each, and a live run's createSnapshot waits on that lock.
    /// What gets unmounted belongs to processes that are gone, so nothing else races
    /// for it; a mount made meanwhile isn't in the plan.
    public func run(snapshotLock: NSLock) -> ReconcileReport {
        snapshotLock.lock()
        let plan = self.plan()
        snapshotLock.unlock()

        var unmounted: [String] = []
        for mp in plan.mounts {
            let stale = MountRef(mountPoint: mp,
                                 snapshot: SnapshotRef(name: "", volume: dataVolume, createdAt: Date()))
            // left on the books if it won't come down, so the next pass retries it
            guard (try? backend.unmount(stale)) != nil else { continue }
            owners.forgetMount(mp)
            unmounted.append(mp)
        }

        snapshotLock.lock(); defer { snapshotLock.unlock() }
        var deleted: [String] = []
        var failed = Set<String>()
        for (name, volume) in plan.snapshots {
            let ref = SnapshotRef(name: name, volume: volume, createdAt: Date())
            guard (try? backend.delete(ref)) != nil else { failed.insert(name); continue }
            if !deleted.contains(name) { deleted.append(name) }
        }
        // off the books once gone from every volume it was on, and from none still
        // waiting (unplugged, or kept)
        for name in Set(plan.snapshots.map { $0.name }).union(plan.vanished) where !failed.contains(name) && !plan.pending.contains(name) {
            ledger.forget(name)
            owners.forgetSnapshot(name)
        }
        return ReconcileReport(unmounted: unmounted, deletedSnapshots: deleted, kept: plan.kept)
    }

    /// the same, for a caller that holds no lock of its own.
    public func run() -> ReconcileReport { run(snapshotLock: NSLock()) }

    struct Plan {
        var mounts: [String] = [], kept: [String] = []
        /// leftovers to delete, each on the volume it's on now
        var snapshots: [(name: String, volume: VolumeRef)] = []
        /// leftovers gone from their volumes already: only the books need clearing
        var vanished: [String] = []
        /// names that stay on the books: kept, or on a volume that isn't connected or
        /// couldn't be listed
        var pending: Set<String> = []
    }

    /// which mounts and snapshots are leftovers, and which are kept.
    func plan() -> Plan {
        var plan = Plan()
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: mountBase) {
            for e in entries.sorted() {
                let mp = "\(mountBase)/\(e)"
                if isOrphan(owner: owners.mountOwner(mp), madeAt: Self.mountDate(e)) { plan.mounts.append(mp) }
                else { plan.kept.append(mp) }
            }
        }
        // Only snapshots WE created (on the ledger) and still there, never Time
        // Machine's. Each is looked for on the volume it was made on: the helper
        // records it (an owner record from before 1.6 has none, which means the Data
        // volume, all 1.5 froze). A volume that isn't connected keeps its entries for
        // when it is; one mounted somewhere new is found by its UUID.
        var listed: [String: Set<String>?] = [:]
        func live(on v: VolumeRef) -> Set<String>? {
            if let cached = listed[v.mountPoint] { return cached }
            let names = (try? backend.list(on: v)).map { Set($0.map(\.name)) }
            listed[v.mountPoint] = names
            return names
        }
        for name in ledger.all().sorted() {
            let recorded = owners.snapshotVolumes(name)
            let volumes = recorded.isEmpty ? [SnapshotOwners.Volume(mountPoint: dataVolume.mountPoint, uuid: nil)] : recorded
            let orphan = isOrphan(owner: owners.snapshotOwner(name), madeAt: Self.snapshotDate(name))
            var here: [VolumeRef] = [], waiting = false
            for v in volumes {
                // the Data volume, as recorded before 1.6, is where it always is
                guard let ref = recorded.isEmpty ? dataVolume : locate(v), let names = live(on: ref) else { waiting = true; continue }
                if names.contains(name) { here.append(ref) }
            }
            if !orphan {
                if !here.isEmpty || waiting { plan.kept.append(name) }
                plan.pending.insert(name)
                continue
            }
            if waiting { plan.pending.insert(name) }
            if here.isEmpty { if !waiting { plan.vanished.append(name) } }
            else { plan.snapshots += here.map { (name: name, volume: $0) } }
        }
        return plan
    }

    private func isOrphan(owner: ProcessIdentity?, madeAt: Date?) -> Bool {
        if let owner { return !isAlive(owner) }
        guard let madeAt else { return false }          // can't tell how old: leave it
        return now.timeIntervalSince(madeAt) > legacyGrace
    }

    /// mount points are named `<snapshot epoch>-<random>` (TMUtilSnapshotBackend.mount).
    static func mountDate(_ entry: String) -> Date? {
        guard let head = entry.split(separator: "-").first, let t = Double(head) else { return nil }
        return Date(timeIntervalSince1970: t)
    }

    /// tmutil names snapshots by local time: com.apple.TimeMachine.2026-06-24-142308.local
    static func snapshotDate(_ name: String) -> Date? {
        guard let stamp = TMUtilSnapshotBackend.snapshotDate(fromName: name) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.date(from: stamp)
    }
}

/// who asked for each snapshot and mount the helper made, so cleanup can tell a
/// crashed run's leftovers from a run still using them. Kept beside the ledger, in
/// its own file, so an older helper reading the ledger is unaffected.
public final class SnapshotOwners: @unchecked Sendable {
    /// the volume a snapshot was made on: where it was mounted, and its UUID so it's
    /// found again when it mounts somewhere else
    public struct Volume: Codable, Sendable, Equatable {
        public var mountPoint: String
        public var uuid: String?
        public init(mountPoint: String, uuid: String?) { self.mountPoint = mountPoint; self.uuid = uuid }

        /// the volume as it is on this Mac now: by UUID when recorded, else at its
        /// mount point if something is mounted there
        public static func mounted(_ v: Volume) -> VolumeRef? {
            // the startup disk's Data volume is always where it is
            if v.mountPoint == "/System/Volumes/Data" { return VolumeRef(mountPoint: v.mountPoint, bsdDevice: "") }
            let table = SystemVolumeTable()
            if let uuid = v.uuid {
                return table.mounted().first { $0.uuid == uuid }.map { VolumeRef(mountPoint: $0.mountPoint.path, bsdDevice: "") }
            }
            return MountPoint.isMounted(URL(fileURLWithPath: v.mountPoint)) ? VolumeRef(mountPoint: v.mountPoint, bsdDevice: "") : nil
        }

        /// the volume mounted at `mountPoint`, with its UUID
        public static func at(_ mountPoint: String) -> Volume {
            Volume(mountPoint: mountPoint, uuid: SystemVolumeTable().volume(containing: URL(fileURLWithPath: mountPoint))?.uuid)
        }
    }

    struct Book: Codable {
        var snapshots: [String: ProcessIdentity] = [:]
        var mounts: [String: ProcessIdentity] = [:]
        /// the volume(s) each snapshot is on: a name can be on two (tmutil names
        /// snapshots by the second, and a job freezing two volumes can make both in one)
        var volumes: [String: [Volume]] = [:]

        init() {}
        enum CodingKeys: String, CodingKey { case snapshots, mounts, volumes }
        // a book written before 1.6 has no volumes; one a later helper wrote may have
        // more than this one knows about
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            snapshots = try c.decodeIfPresent([String: ProcessIdentity].self, forKey: .snapshots) ?? [:]
            mounts = try c.decodeIfPresent([String: ProcessIdentity].self, forKey: .mounts) ?? [:]
            volumes = (try? c.decodeIfPresent([String: [Volume]].self, forKey: .volumes)) ?? [:]
        }
    }

    private let url: URL
    private let lock = NSLock()

    public init(path: String) { self.url = URL(fileURLWithPath: path) }

    public func recordSnapshot(_ name: String, owner: ProcessIdentity) { mutate { $0.snapshots[name] = owner } }
    /// record the volume a snapshot was made on
    public func recordSnapshotVolume(_ name: String, volume: Volume) {
        mutate { if !($0.volumes[name] ?? []).contains(volume) { $0.volumes[name, default: []].append(volume) } }
    }
    public func recordMount(_ path: String, owner: ProcessIdentity) { mutate { $0.mounts[path] = owner } }
    public func forgetSnapshot(_ name: String) { mutate { $0.snapshots[name] = nil; $0.volumes[name] = nil } }
    public func forgetMount(_ path: String) { mutate { $0.mounts[path] = nil } }

    public func snapshotOwner(_ name: String) -> ProcessIdentity? { read().snapshots[name] }
    public func mountOwner(_ path: String) -> ProcessIdentity? { read().mounts[path] }
    public func snapshotVolumes(_ name: String) -> [Volume] { read().volumes[name] ?? [] }

    private func read() -> Book {
        lock.lock(); defer { lock.unlock() }
        return load()
    }

    private func mutate(_ change: (inout Book) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var book = load()
        change(&book)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(book) { try? data.write(to: url, options: .atomic) }
    }

    private func load() -> Book {
        guard let data = try? Data(contentsOf: url), let book = try? JSONDecoder().decode(Book.self, from: data) else { return Book() }
        return book
    }
}
