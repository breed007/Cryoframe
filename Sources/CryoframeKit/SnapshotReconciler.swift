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

    public init(backend: SnapshotBackend, ledger: SnapshotLedger, owners: SnapshotOwners,
                mountBase: String, dataVolume: VolumeRef,
                isAlive: @escaping (ProcessIdentity) -> Bool = { $0.isAlive },
                now: Date = Date(), legacyGrace: TimeInterval = 72 * 3600) {
        self.backend = backend; self.ledger = ledger; self.owners = owners
        self.mountBase = mountBase; self.dataVolume = dataVolume
        self.isAlive = isAlive; self.now = now; self.legacyGrace = legacyGrace
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
        for name in plan.snapshots {
            let ref = SnapshotRef(name: name, volume: dataVolume, createdAt: Date())
            guard (try? backend.delete(ref)) != nil else { continue }
            ledger.forget(name)
            owners.forgetSnapshot(name)
            deleted.append(name)
        }
        return ReconcileReport(unmounted: unmounted, deletedSnapshots: deleted, kept: plan.kept)
    }

    /// the same, for a caller that holds no lock of its own.
    public func run() -> ReconcileReport { run(snapshotLock: NSLock()) }

    struct Plan { var mounts: [String] = [], snapshots: [String] = [], kept: [String] = [] }

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
        // only snapshots WE created (ledger ∩ still-live). never TM's.
        let live = Set((try? backend.list(on: dataVolume))?.map(\.name) ?? [])
        for name in ledger.all().sorted() where live.contains(name) {
            if isOrphan(owner: owners.snapshotOwner(name), madeAt: Self.snapshotDate(name)) { plan.snapshots.append(name) }
            else { plan.kept.append(name) }
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
    struct Book: Codable {
        var snapshots: [String: ProcessIdentity] = [:]
        var mounts: [String: ProcessIdentity] = [:]
    }

    private let url: URL
    private let lock = NSLock()

    public init(path: String) { self.url = URL(fileURLWithPath: path) }

    public func recordSnapshot(_ name: String, owner: ProcessIdentity) { mutate { $0.snapshots[name] = owner } }
    public func recordMount(_ path: String, owner: ProcessIdentity) { mutate { $0.mounts[path] = owner } }
    public func forgetSnapshot(_ name: String) { mutate { $0.snapshots[name] = nil } }
    public func forgetMount(_ path: String) { mutate { $0.mounts[path] = nil } }

    public func snapshotOwner(_ name: String) -> ProcessIdentity? { read().snapshots[name] }
    public func mountOwner(_ path: String) -> ProcessIdentity? { read().mounts[path] }

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
