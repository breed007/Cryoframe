//
//  HelperService.swift
//  CryoframeHelper (root LaunchDaemon)
//
//  Implements the XPC wire protocol by delegating to a SnapshotBackend, guarded
//  by a persisted ledger. Runs as root; does ONLY snapshot lifecycle + (later)
//  network mounts. It never reads library content — that's the FDA app's job.
//

import Foundation
import CryoframeShared
import CryoframeKit

final class HelperService: NSObject, CryoframeHelperXPC, @unchecked Sendable {
    private let backend: SnapshotBackend
    private let ledger: SnapshotLedger
    private let dataVolume = VolumeRef(mountPoint: "/System/Volumes/Data", bsdDevice: "")
    private static let mountBase = "/private/var/run/app.cryoframe/mnt"

    init(backend: SnapshotBackend = TMUtilSnapshotBackend(),
         ledger: SnapshotLedger = SnapshotLedger(path: "/private/var/db/app.cryoframe/ledger.json")) {
        self.backend = backend
        self.ledger = ledger
    }

    // MARK: wire protocol

    func handshake(reply: @escaping (Data?, Error?) -> Void) {
        respond(reply) {
            HelperInfo(version: HelperService.version, pid: ProcessInfo.processInfo.processIdentifier)
        }
    }

    func createSnapshot(volume: Data, reply: @escaping (Data?, Error?) -> Void) {
        respond(reply) {
            let vol = try Wire.decode(VolumeRef.self, from: volume)
            let snap = try self.backend.create(on: vol)
            self.ledger.record(snap.name)         // own it before anything can fail
            return snap
        }
    }

    func mountSnapshot(snapshot: Data, ownerUID: uid_t, reply: @escaping (Data?, Error?) -> Void) {
        respond(reply) {
            let snap = try Wire.decode(SnapshotRef.self, from: snapshot)
            return try self.backend.mount(snap, ownerUID: ownerUID)
        }
    }

    func unmount(mount: Data, reply: @escaping (Error?) -> Void) {
        respondVoid(reply) {
            let m = try Wire.decode(MountRef.self, from: mount)
            try self.backend.unmount(m)
        }
    }

    func deleteSnapshot(snapshot: Data, reply: @escaping (Error?) -> Void) {
        respondVoid(reply) {
            let snap = try Wire.decode(SnapshotRef.self, from: snapshot)
            // ownership guard: only delete what we recorded creating.
            guard self.ledger.all().contains(snap.name) else {
                throw HelperError.refusedForeignSnapshot(name: snap.name)
            }
            try self.backend.delete(snap)
            self.ledger.forget(snap.name)
        }
    }

    func listSnapshots(volume: Data, reply: @escaping (Data?, Error?) -> Void) {
        respond(reply) {
            let vol = try Wire.decode(VolumeRef.self, from: volume)
            return try self.backend.list(on: vol)
        }
    }

    func reconcile(reply: @escaping (Data?, Error?) -> Void) {
        respond(reply) { try self.runReconcile() }
    }

    func mountNetworkTarget(spec: Data, reply: @escaping (Data?, Error?) -> Void) {
        respond(reply) { () -> MountRef in
            throw HelperError.internalError("mountNetworkTarget: not implemented until M5")
        }
    }

    // MARK: reconcile-on-launch

    private func runReconcile() throws -> ReconcileReport {
        var unmounted: [String] = []
        let fm = FileManager.default

        // 1. tear down stale mounts left by a crashed run.
        if let entries = try? fm.contentsOfDirectory(atPath: Self.mountBase) {
            for e in entries {
                let mp = "\(Self.mountBase)/\(e)"
                let stale = MountRef(mountPoint: mp,
                                     snapshot: SnapshotRef(name: "", volume: dataVolume, createdAt: Date()))
                try? backend.unmount(stale)
                unmounted.append(mp)
            }
        }

        // 2. delete orphan snapshots WE created (ledger ∩ still-live). never TM's.
        var deleted: [String] = []
        let live = Set((try? backend.list(on: dataVolume))?.map(\.name) ?? [])
        for name in ledger.all() where live.contains(name) {
            let ref = SnapshotRef(name: name, volume: dataVolume, createdAt: Date())
            try? backend.delete(ref)
            ledger.forget(name)
            deleted.append(name)
        }
        return ReconcileReport(unmounted: unmounted, deletedSnapshots: deleted)
    }

    // MARK: reply plumbing

    static let version = "0.1.0-m1"

    private func respond<T: Encodable>(_ reply: (Data?, Error?) -> Void, _ work: () throws -> T) {
        do { reply(try Wire.encode(try work()), nil) }
        catch { reply(nil, Self.ns(error)) }
    }
    private func respondVoid(_ reply: (Error?) -> Void, _ work: () throws -> Void) {
        do { try work(); reply(nil) }
        catch { reply(Self.ns(error)) }
    }
    private static func ns(_ e: Error) -> NSError {
        NSError(domain: "app.cryoframe.helper", code: 1,
                userInfo: [NSLocalizedDescriptionKey: String(describing: e)])
    }
}
