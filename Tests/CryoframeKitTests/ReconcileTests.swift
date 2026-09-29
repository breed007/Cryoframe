//
//  ReconcileTests.swift
//  CryoframeKitTests
//
//  Cleaning up after a crashed run must never tear down a run that is still going.
//  The helper can't see anyone's run locks, but it knows which process asked for
//  each snapshot and mount, and whether that process is still alive.
//

import Testing
import Foundation
import CryoframeShared
@testable import CryoframeKit

private func tempDir(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private final class RecordingBackend: SnapshotBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var live: Set<String>
    private(set) var unmounted: [String] = []
    private(set) var deleted: [String] = []

    init(live: Set<String>) { self.live = live }

    func create(on volume: VolumeRef) throws -> SnapshotRef { throw SnapshotBackendError.dataVolumeNotFound }
    func mount(_ snapshot: SnapshotRef, ownerUID: uid_t) throws -> MountRef { throw SnapshotBackendError.dataVolumeNotFound }
    func unmount(_ mount: MountRef) throws {
        lock.lock(); unmounted.append(mount.mountPoint); lock.unlock()
        MountPoint.removeDirectory(URL(fileURLWithPath: mount.mountPoint))
    }
    func delete(_ snapshot: SnapshotRef) throws {
        lock.lock(); deleted.append(snapshot.name); live.remove(snapshot.name); lock.unlock()
    }
    func list(on volume: VolumeRef) throws -> [SnapshotRef] {
        lock.lock(); defer { lock.unlock() }
        return live.map { SnapshotRef(name: $0, volume: volume, createdAt: Date(timeIntervalSince1970: 0)) }
    }
}

private let now = Date()
private let data = VolumeRef(mountPoint: "/System/Volumes/Data", bsdDevice: "")

/// a tmutil-style snapshot name for `date`, the way the helper records them.
private func snapName(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd-HHmmss"
    return "com.apple.TimeMachine.\(f.string(from: date)).local"
}

private struct World {
    let base = tempDir("reconcile")
    var mountBase: String { base.appendingPathComponent("mnt").path }
    var ledger: SnapshotLedger { SnapshotLedger(path: base.appendingPathComponent("ledger.json").path) }
    var owners: SnapshotOwners { SnapshotOwners(path: base.appendingPathComponent("owners.json").path) }

    /// a run's snapshot and its mount, as the helper records them.
    func run(at date: Date, owner: ProcessIdentity?) throws -> (snapshot: String, mount: String) {
        let name = snapName(date)
        let mount = "\(mountBase)/\(Int(date.timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: mount, withIntermediateDirectories: true)
        ledger.record(name)
        if let owner {
            owners.recordSnapshot(name, owner: owner)
            owners.recordMount(mount, owner: owner)
        }
        return (name, mount)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: base) }

    func reconcile(_ backend: RecordingBackend, alive: Set<Int32>) -> ReconcileReport {
        SnapshotReconciler(backend: backend, ledger: ledger, owners: owners, mountBase: mountBase,
                           dataVolume: data, isAlive: { alive.contains($0.pid) }, now: now).run()
    }
}

private let appRun = ProcessIdentity(pid: 101, startedAt: 1_000)
private let agentRun = ProcessIdentity(pid: 202, startedAt: 2_000)

@Test func reconcileLeavesARunInProgressAlone() throws {
    let w = World(); defer { w.cleanUp() }
    let r = try w.run(at: now.addingTimeInterval(-60), owner: agentRun)
    let backend = RecordingBackend(live: [r.snapshot])

    let report = w.reconcile(backend, alive: [agentRun.pid])

    #expect(backend.unmounted.isEmpty)
    #expect(backend.deleted.isEmpty)
    #expect(FileManager.default.fileExists(atPath: r.mount))
    #expect(w.ledger.all().contains(r.snapshot))
    #expect(report.unmounted.isEmpty && report.deletedSnapshots.isEmpty)
    #expect(Set(report.kept ?? []) == [r.snapshot, r.mount])
}

@Test func reconcileCleansUpAfterARunWhoseProcessIsGone() throws {
    let w = World(); defer { w.cleanUp() }
    let r = try w.run(at: now.addingTimeInterval(-60), owner: agentRun)
    let backend = RecordingBackend(live: [r.snapshot])

    let report = w.reconcile(backend, alive: [])

    #expect(backend.unmounted == [r.mount] && backend.deleted == [r.snapshot])
    #expect(report.unmounted == [r.mount] && report.deletedSnapshots == [r.snapshot])
    #expect(!w.ledger.all().contains(r.snapshot))
    #expect(w.owners.snapshotOwner(r.snapshot) == nil && w.owners.mountOwner(r.mount) == nil)
}

@Test func reconcileSortsTwoRunsByWhetherTheirProcessLives() throws {
    let w = World(); defer { w.cleanUp() }
    let crashed = try w.run(at: now.addingTimeInterval(-3_600), owner: appRun)
    let running = try w.run(at: now.addingTimeInterval(-30), owner: agentRun)
    let backend = RecordingBackend(live: [crashed.snapshot, running.snapshot])

    _ = w.reconcile(backend, alive: [agentRun.pid])

    #expect(backend.unmounted == [crashed.mount])
    #expect(backend.deleted == [crashed.snapshot])
    #expect(w.ledger.all() == [running.snapshot])
}

// Snapshots and mounts made by a helper older than 1.6 have no recorded owner. One
// may belong to an old agent still mid-run across the update, so it's only cleaned
// once it is older than any run could be.
@Test func unownedLeftoversAreCleanedOnlyOnceTheyAreOld() throws {
    let w = World(); defer { w.cleanUp() }
    let recent = try w.run(at: now.addingTimeInterval(-2 * 3_600), owner: nil)
    let ancient = try w.run(at: now.addingTimeInterval(-5 * 24 * 3_600), owner: nil)
    let backend = RecordingBackend(live: [recent.snapshot, ancient.snapshot])

    _ = w.reconcile(backend, alive: [])

    #expect(backend.unmounted == [ancient.mount])
    #expect(backend.deleted == [ancient.snapshot])
    #expect(w.ledger.all() == [recent.snapshot])
}

@Test func aMountWhoseNameCantBeDatedIsLeftAlone() throws {
    let w = World(); defer { w.cleanUp() }
    let odd = "\(w.mountBase)/not-ours"
    try FileManager.default.createDirectory(atPath: odd, withIntermediateDirectories: true)
    let backend = RecordingBackend(live: [])
    _ = w.reconcile(backend, alive: [])
    #expect(backend.unmounted.isEmpty)
}

@Test func reconcileNeverTouchesASnapshotItDidNotMake() throws {
    let w = World(); defer { w.cleanUp() }
    let timeMachine = snapName(now.addingTimeInterval(-10 * 24 * 3_600))
    let backend = RecordingBackend(live: [timeMachine])
    _ = w.reconcile(backend, alive: [])
    #expect(backend.deleted.isEmpty)
}

// MARK: - telling a live process from a gone one

@Test func thisProcessIsAlive() throws {
    let me = try #require(ProcessIdentity.current)
    #expect(me.pid == getpid() && me.isAlive)
}

@Test func aProcessThatExitedIsNotAlive() throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try p.run()
    let id = ProcessIdentity.of(pid: p.processIdentifier)
    p.waitUntilExit()
    // it may already have exited before we looked; either way it is gone now
    #expect(id?.isAlive != true)
    #expect(ProcessIdentity.of(pid: p.processIdentifier) == nil || id == nil)
}

@Test func aRecycledPidIsNotTheSameProcess() throws {
    let me = try #require(ProcessIdentity.current)
    #expect(!ProcessIdentity(pid: me.pid, startedAt: me.startedAt - 3_600).isAlive)
}

// MARK: - when the app and agent ask for it

@Test func cleanupWaitsWhileAnyJobIsRunning() async throws {
    let helper = FakePrivilegedHelper(version: SnapshotReconciler.helperVersion)
    let locks = RunLocks(directory: tempDir("gate"))
    defer { try? FileManager.default.removeItem(at: locks.directory) }
    let run = try locks.acquire(jobID: "b", trigger: .scheduled)
    let outcome = await LeftoverCleanup.run(helper: helper, locks: locks, jobIDs: ["a", "b"])
    #expect(outcome == .skippedRunInProgress("b"))
    #expect(await helper.calls.isEmpty)
    run.release()
    guard case .cleaned = await LeftoverCleanup.run(helper: helper, locks: locks, jobIDs: ["a", "b"]) else {
        Issue.record("cleanup didn't run once nothing was running"); return
    }
    #expect(await helper.calls == ["reconcile"])
}

@Test func cleanupRefusesAHelperThatPredatesOwnership() async throws {
    let helper = FakePrivilegedHelper(version: "1.5.2")
    let dir = tempDir("gate"); defer { try? FileManager.default.removeItem(at: dir) }
    let outcome = await LeftoverCleanup.run(helper: helper, locks: RunLocks(directory: dir), jobIDs: [])
    #expect(outcome == .skippedOldHelper("1.5.2"))
    #expect(await helper.calls.isEmpty)
}

@Test func helperVersionsCompareNumerically() {
    #expect(LeftoverCleanup.isAtLeast("1.6.0", "1.6.0"))
    #expect(LeftoverCleanup.isAtLeast("1.10.0", "1.6.0"))
    #expect(LeftoverCleanup.isAtLeast("2.0", "1.6.0"))
    #expect(!LeftoverCleanup.isAtLeast("1.5.2", "1.6.0"))
    #expect(!LeftoverCleanup.isAtLeast("fake", "1.6.0"))
    #expect(!LeftoverCleanup.isAtLeast("", "1.6.0"))
}

// MARK: - not stalling a live run

/// unmount blocks until the test lets it go, the way a stuck mount does.
private final class StuckUnmountBackend: SnapshotBackend, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let letGo = DispatchSemaphore(value: 0)
    private let live: Set<String>
    init(live: Set<String>) { self.live = live }
    func create(on volume: VolumeRef) throws -> SnapshotRef { throw SnapshotBackendError.dataVolumeNotFound }
    func mount(_ snapshot: SnapshotRef, ownerUID: uid_t) throws -> MountRef { throw SnapshotBackendError.dataVolumeNotFound }
    func unmount(_ mount: MountRef) throws {
        entered.signal()
        letGo.wait()
        MountPoint.removeDirectory(URL(fileURLWithPath: mount.mountPoint))
    }
    func delete(_ snapshot: SnapshotRef) throws {}
    func list(on volume: VolumeRef) throws -> [SnapshotRef] {
        live.map { SnapshotRef(name: $0, volume: volume, createdAt: Date(timeIntervalSince1970: 0)) }
    }
}

private final class ReportBox: @unchecked Sendable { var report: ReconcileReport? }

// The helper's snapshot lock also guards createSnapshot and mountSnapshot. A stuck
// mount takes seconds to force off; holding the lock through that would stall a
// live run's snapshot for as long.
@Test func reconcileDoesNotHoldTheSnapshotLockWhileItUnmounts() throws {
    let w = World(); defer { try? FileManager.default.removeItem(at: w.base) }
    let r = try w.run(at: now.addingTimeInterval(-60), owner: appRun)
    let backend = StuckUnmountBackend(live: [r.snapshot])
    let reconciler = SnapshotReconciler(backend: backend, ledger: w.ledger, owners: w.owners, mountBase: w.mountBase,
                                        dataVolume: data, isAlive: { _ in false }, now: now)
    let snapshotLock = NSLock()
    let box = ReportBox(), done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { box.report = reconciler.run(snapshotLock: snapshotLock); done.signal() }

    #expect(backend.entered.wait(timeout: .now() + 5) == .success)
    let free = snapshotLock.lock(before: Date().addingTimeInterval(1))
    if free { snapshotLock.unlock() }
    backend.letGo.signal()
    done.wait()
    #expect(free, "a live run's createSnapshot would wait behind a stuck unmount")
    #expect(box.report?.unmounted == [r.mount] && box.report?.deletedSnapshots == [r.snapshot])
}

// MARK: - an abandoned cleanup

// The agent stops waiting for cleanup after a while and starts its runs. A cleanup
// that gets its answer from the helper after that must not go on to reconcile.
@Test func cleanupThatIsNoLongerWantedNeverReconciles() async throws {
    let helper = FakePrivilegedHelper(version: SnapshotReconciler.helperVersion)
    let dir = tempDir("gate"); defer { try? FileManager.default.removeItem(at: dir) }
    let outcome = await LeftoverCleanup.run(helper: helper, locks: RunLocks(directory: dir), jobIDs: [],
                                            stillWanted: { false })
    if case .cleaned = outcome { Issue.record("reconciled after the caller gave up on it") }
    #expect(await helper.calls == [])
}
