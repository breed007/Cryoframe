//
//  VolumeReconcileTests.swift
//  CryoframeKitTests
//
//  Cleanup after a crashed run, for snapshots of external source drives: each is
//  looked for on the volume it was made on (wherever that drive is mounted now),
//  a drive that isn't connected keeps its entries for later, and an owner record
//  written before 1.6 still means the Data volume.
//

import Testing
import Foundation
import CryoframeShared
@testable import CryoframeKit

/// snapshots per volume (by mount point); a volume missing from `listable` can't be listed
private final class VolumesBackend: SnapshotBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var live: [String: Set<String>]
    private(set) var deleted: [(String, String)] = []
    init(_ live: [String: Set<String>]) { self.live = live }
    func create(on volume: VolumeRef) throws -> SnapshotRef { throw SnapshotBackendError.dataVolumeNotFound }
    func mount(_ snapshot: SnapshotRef, ownerUID: uid_t) throws -> MountRef { throw SnapshotBackendError.dataVolumeNotFound }
    func unmount(_ mount: MountRef) throws {}
    func delete(_ snapshot: SnapshotRef) throws {
        lock.lock(); defer { lock.unlock() }
        guard live[snapshot.volume.mountPoint]?.remove(snapshot.name) != nil else { throw SnapshotBackendError.dataVolumeNotFound }
        deleted.append((snapshot.volume.mountPoint, snapshot.name))
    }
    func list(on volume: VolumeRef) throws -> [SnapshotRef] {
        lock.lock(); defer { lock.unlock() }
        guard let names = live[volume.mountPoint] else { throw SnapshotBackendError.dataVolumeNotFound }
        return names.map { SnapshotRef(name: $0, volume: volume, createdAt: Date(timeIntervalSince1970: 0)) }
    }
}

private let data = VolumeRef(mountPoint: "/System/Volumes/Data", bsdDevice: "")
private let dead = ProcessIdentity(pid: 999_001, startedAt: 1), alive = ProcessIdentity(pid: 999_002, startedAt: 2)

private func snapName(_ offset: TimeInterval) -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd-HHmmss"
    return "com.apple.TimeMachine.\(f.string(from: Date().addingTimeInterval(offset))).local"
}

private struct Books {
    let base: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-vrec-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    var ledger: SnapshotLedger { SnapshotLedger(path: base.appendingPathComponent("ledger.json").path) }
    var owners: SnapshotOwners { SnapshotOwners(path: base.appendingPathComponent("owners.json").path) }
    func record(_ name: String, owner: ProcessIdentity, on volume: SnapshotOwners.Volume?) {
        ledger.record(name); owners.recordSnapshot(name, owner: owner)
        if let volume { owners.recordSnapshotVolume(name, volume: volume) }
    }
    /// `mounted`: UUID → where that drive is mounted now
    func reconcile(_ backend: VolumesBackend, mounted: [String: String]) -> ReconcileReport {
        SnapshotReconciler(backend: backend, ledger: ledger, owners: owners, mountBase: base.appendingPathComponent("mnt").path,
                           dataVolume: data, isAlive: { $0 == alive }, now: Date(),
                           locate: { v in v.uuid.flatMap { mounted[$0] }.map { VolumeRef(mountPoint: $0, bsdDevice: "") } }).run()
    }
    func cleanUp() { try? FileManager.default.removeItem(at: base) }
}

@Suite(.serialized) struct VolumeReconcileTests {

    // Before 1.6 only the Data volume was listed, so a crashed run's snapshot of an
    // external source drive stayed on the ledger, and on the drive, for good.
    @Test func aCrashedRunsSnapshotOfAnExternalDriveIsCleanedUp() {
        let b = Books(); defer { b.cleanUp() }
        let name = snapName(-600)
        b.record(name, owner: dead, on: .init(mountPoint: "/Volumes/Media", uuid: "MEDIA"))
        let backend = VolumesBackend(["/Volumes/Media": [name], "/System/Volumes/Data": []])
        let report = b.reconcile(backend, mounted: ["MEDIA": "/Volumes/Media"])
        #expect(report.deletedSnapshots == [name])
        #expect(backend.deleted.map(\.0) == ["/Volumes/Media"])
        #expect(b.ledger.all().isEmpty && b.owners.snapshotVolumes(name).isEmpty)
    }

    // Mounted as "Media 1" today: found by its UUID.
    @Test func aDriveMountedSomewhereNewIsFoundByItsUUID() {
        let b = Books(); defer { b.cleanUp() }
        let name = snapName(-600)
        b.record(name, owner: dead, on: .init(mountPoint: "/Volumes/Media", uuid: "MEDIA"))
        let backend = VolumesBackend(["/Volumes/Media 1": [name]])
        #expect(b.reconcile(backend, mounted: ["MEDIA": "/Volumes/Media 1"]).deletedSnapshots == [name])
    }

    // Unplugged: nothing to list, so the entry waits on the books for the drive.
    @Test func anUnpluggedDrivesEntriesWait() {
        let b = Books(); defer { b.cleanUp() }
        let name = snapName(-600)
        b.record(name, owner: dead, on: .init(mountPoint: "/Volumes/Media", uuid: "MEDIA"))
        let backend = VolumesBackend(["/System/Volumes/Data": []])
        let report = b.reconcile(backend, mounted: [:])
        #expect(report.deletedSnapshots.isEmpty && b.ledger.all() == [name])
        // plugged back in: cleaned up then
        let back = VolumesBackend(["/Volumes/Media": [name]])
        #expect(b.reconcile(back, mounted: ["MEDIA": "/Volumes/Media"]).deletedSnapshots == [name])
        #expect(b.ledger.all().isEmpty)
    }

    // A live run's snapshot on an external drive is kept, as on the Data volume.
    @Test func aLiveRunsSnapshotOnAnExternalDriveIsKept() {
        let b = Books(); defer { b.cleanUp() }
        let name = snapName(-60)
        b.record(name, owner: alive, on: .init(mountPoint: "/Volumes/Media", uuid: "MEDIA"))
        let backend = VolumesBackend(["/Volumes/Media": [name]])
        let report = b.reconcile(backend, mounted: ["MEDIA": "/Volumes/Media"])
        #expect(report.deletedSnapshots.isEmpty && (report.kept ?? []).contains(name) && b.ledger.all() == [name])
    }

    // A job freezing two drives in one second makes two snapshots of one name.
    @Test func oneNameOnTwoVolumesIsCleanedFromBoth() {
        let b = Books(); defer { b.cleanUp() }
        let name = snapName(-600)
        b.record(name, owner: dead, on: .init(mountPoint: "/System/Volumes/Data", uuid: "DATA"))
        b.record(name, owner: dead, on: .init(mountPoint: "/Volumes/Media", uuid: "MEDIA"))
        let backend = VolumesBackend(["/System/Volumes/Data": [name], "/Volumes/Media": [name]])
        _ = b.reconcile(backend, mounted: ["DATA": "/System/Volumes/Data", "MEDIA": "/Volumes/Media"])
        #expect(Set(backend.deleted.map(\.0)) == ["/System/Volumes/Data", "/Volumes/Media"])
        #expect(b.ledger.all().isEmpty)
    }

    // An owner record from before 1.6 has no volume: the Data volume, as always.
    @Test func anEntryWithoutAVolumeIsTheDataVolumes() {
        let b = Books(); defer { b.cleanUp() }
        let name = snapName(-600)
        b.record(name, owner: dead, on: nil)
        let backend = VolumesBackend(["/System/Volumes/Data": [name]])
        #expect(b.reconcile(backend, mounted: [:]).deletedSnapshots == [name])
    }

    // A crashed run's entry whose snapshot is gone already (deleted by hand, or the
    // drive was erased) comes off the books instead of staying forever.
    @Test func anEntryWhoseSnapshotIsGoneComesOffTheBooks() {
        let b = Books(); defer { b.cleanUp() }
        let name = snapName(-600)
        b.record(name, owner: dead, on: .init(mountPoint: "/Volumes/Media", uuid: "MEDIA"))
        let report = b.reconcile(VolumesBackend(["/Volumes/Media": []]), mounted: ["MEDIA": "/Volumes/Media"])
        #expect(report.deletedSnapshots.isEmpty && b.ledger.all().isEmpty)
    }

    // The Data volume isn't among the volumes macOS lists ("/" is the sealed system
    // volume). Recorded with its UUID, a Data-volume snapshot must still be found, or
    // a crashed run's snapshot of the home folder would never be cleaned up.
    @Test func theDataVolumeIsFoundOnThisMac() {
        let data = SnapshotOwners.Volume.at("/System/Volumes/Data")
        #expect(data.uuid != nil)
        #expect(SnapshotOwners.Volume.mounted(data)?.mountPoint == "/System/Volumes/Data")
        #expect(SystemVolumeTable().mounted().contains { $0.uuid == data.uuid && $0.mountPoint.path == "/System/Volumes/Data" })
    }

    // owners.json from a 1.6.0 helper (no volumes) still reads, and one with volumes
    // loses nothing when read back.
    @Test func theOwnersBookReadsWithAndWithoutVolumes() throws {
        let b = Books(); defer { b.cleanUp() }
        let old = #"{"snapshots":{"s1":{"pid":5,"startedAt":7}},"mounts":{}}"#
        try Data(old.utf8).write(to: b.base.appendingPathComponent("owners.json"))
        #expect(b.owners.snapshotOwner("s1") == ProcessIdentity(pid: 5, startedAt: 7))
        b.owners.recordSnapshotVolume("s1", volume: .init(mountPoint: "/Volumes/M", uuid: "M"))
        #expect(b.owners.snapshotOwner("s1") != nil && b.owners.snapshotVolumes("s1") == [.init(mountPoint: "/Volumes/M", uuid: "M")])
    }
}
