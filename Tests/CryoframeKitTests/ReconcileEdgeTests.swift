//
//  ReconcileEdgeTests.swift
//  CryoframeKitTests
//
//  Reconcile against the real owners file and real processes, not a stubbed
//  isAlive: the identity has to survive being written to disk and read back, a
//  killed run has to read as gone, and a recycled pid must not pass for the run.
//  Also the 72-hour line, a corrupt owners file, and the calling-side gate when a
//  run is held by another process or the lock folder can't be read.
//

import Testing
import Foundation
import CryoframeShared
@testable import CryoframeKit

private func edgeDir(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private final class CountingBackend: SnapshotBackend, @unchecked Sendable {
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

private let dataVolume = VolumeRef(mountPoint: "/System/Volumes/Data", bsdDevice: "")

private func tmName(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd-HHmmss"
    return "com.apple.TimeMachine.\(f.string(from: date)).local"
}

/// a helper's books in a temp folder: ledger, owners file, mount folder.
private struct Books {
    let base = edgeDir("recedge")
    var mountBase: String { base.appendingPathComponent("mnt").path }
    var ownersPath: String { base.appendingPathComponent("owners.json").path }
    var ledger: SnapshotLedger { SnapshotLedger(path: base.appendingPathComponent("ledger.json").path) }
    var owners: SnapshotOwners { SnapshotOwners(path: ownersPath) }

    func run(at date: Date, owner: ProcessIdentity?) throws -> (snapshot: String, mount: String) {
        let name = tmName(date)
        let mount = "\(mountBase)/\(Int(date.timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: mount, withIntermediateDirectories: true)
        ledger.record(name)
        if let owner {
            owners.recordSnapshot(name, owner: owner)
            owners.recordMount(mount, owner: owner)
        }
        return (name, mount)
    }

    /// reconcile with the real liveness check, as the helper runs it.
    func reconcile(_ backend: CountingBackend, now: Date = Date()) -> ReconcileReport {
        SnapshotReconciler(backend: backend, ledger: ledger, owners: owners, mountBase: mountBase,
                           dataVolume: dataVolume, now: now).run()
    }

    func cleanUp() { try? FileManager.default.removeItem(at: base) }
}

// MARK: - real processes, through the owners file on disk

@Test func anOwnerReadBackFromDiskIsStillTheLiveProcess() throws {
    let b = Books(); defer { b.cleanUp() }
    let me = try #require(ProcessIdentity.current)
    let r = try b.run(at: Date().addingTimeInterval(-60), owner: me)

    // the start time survives JSON to the microsecond, or isAlive would call us dead
    let back = try #require(SnapshotOwners(path: b.ownersPath).snapshotOwner(r.snapshot))
    #expect(back.pid == me.pid && abs(back.startedAt - me.startedAt) < 0.000_5)
    #expect(back.isAlive)

    let backend = CountingBackend(live: [r.snapshot])
    let report = b.reconcile(backend)
    #expect(backend.unmounted.isEmpty && backend.deleted.isEmpty)
    #expect(Set(report.kept ?? []) == [r.snapshot, r.mount])
}

@Test func aRunKilledMidwayIsCleanedUpAndOnlyThen() throws {
    let b = Books(); defer { b.cleanUp() }
    let agent = Process()
    agent.executableURL = URL(fileURLWithPath: "/bin/sleep")
    agent.arguments = ["30"]
    try agent.run()
    let owner = try #require(ProcessIdentity.of(pid: agent.processIdentifier))
    let r = try b.run(at: Date().addingTimeInterval(-60), owner: owner)
    let backend = CountingBackend(live: [r.snapshot])

    _ = b.reconcile(backend)
    #expect(backend.unmounted.isEmpty && backend.deleted.isEmpty)      // still running

    kill(agent.processIdentifier, SIGKILL)
    waitBounded(agent)
    let report = b.reconcile(backend)
    #expect(report.unmounted == [r.mount] && report.deletedSnapshots == [r.snapshot])
    #expect(b.owners.snapshotOwner(r.snapshot) == nil && b.owners.mountOwner(r.mount) == nil)
}

@Test func aRecycledPidInTheOwnersFileIsNotTheRun() throws {
    let b = Books(); defer { b.cleanUp() }
    let me = try #require(ProcessIdentity.current)
    // same pid as a live process, but started a second earlier: the run that owned it died
    let gone = ProcessIdentity(pid: me.pid, startedAt: me.startedAt - 1)
    let r = try b.run(at: Date().addingTimeInterval(-60), owner: gone)
    let backend = CountingBackend(live: [r.snapshot])

    let report = b.reconcile(backend)
    #expect(report.deletedSnapshots == [r.snapshot] && report.unmounted == [r.mount])
}

// MARK: - leftovers with no owner

// 2026-07-01 12:00 UTC, away from any DST change, on a whole second so the snapshot
// name and the mount folder name carry the same instant.
private let madeAt = Date(timeIntervalSince1970: 1_782_907_200)

@Test func anUnownedLeftoverIsKeptThroughSeventyTwoHoursAndCleanedAfter() throws {
    let b = Books(); defer { b.cleanUp() }
    let r = try b.run(at: madeAt, owner: nil)

    let atLine = CountingBackend(live: [r.snapshot])
    _ = b.reconcile(atLine, now: madeAt.addingTimeInterval(72 * 3600))
    #expect(atLine.unmounted.isEmpty && atLine.deleted.isEmpty)

    let past = CountingBackend(live: [r.snapshot])
    _ = b.reconcile(past, now: madeAt.addingTimeInterval(72 * 3600 + 1))
    #expect(past.unmounted == [r.mount] && past.deleted == [r.snapshot])
}

@Test func aClockSetBackNeverMakesALeftoverLookOld() throws {
    let b = Books(); defer { b.cleanUp() }
    let r = try b.run(at: madeAt, owner: nil)
    let backend = CountingBackend(live: [r.snapshot])
    _ = b.reconcile(backend, now: madeAt.addingTimeInterval(-30 * 24 * 3600))
    #expect(backend.unmounted.isEmpty && backend.deleted.isEmpty)
}

@Test func aCorruptOwnersFileNeverMakesARecentRunLookAbandoned() throws {
    let b = Books(); defer { b.cleanUp() }
    let r = try b.run(at: Date().addingTimeInterval(-60), owner: ProcessIdentity(pid: 1, startedAt: 1))
    try Data("{\"snapshots\":{\"com.apple.Time".utf8).write(to: URL(fileURLWithPath: b.ownersPath))

    let backend = CountingBackend(live: [r.snapshot])
    let report = b.reconcile(backend)
    #expect(backend.unmounted.isEmpty && backend.deleted.isEmpty)
    #expect(Set(report.kept ?? []) == [r.snapshot, r.mount])
}

@Test func ownersRecordedFromManyConnectionsAtOnceAreAllKept() throws {
    let b = Books(); defer { b.cleanUp() }
    let owners = b.owners                            // the helper shares one across connections
    DispatchQueue.concurrentPerform(iterations: 40) { i in
        owners.recordSnapshot("snap-\(i)", owner: ProcessIdentity(pid: Int32(1000 + i), startedAt: Double(i)))
    }
    let reread = SnapshotOwners(path: b.ownersPath)
    #expect((0..<40).allSatisfy { reread.snapshotOwner("snap-\($0)")?.pid == Int32(1000 + $0) })
}

// MARK: - the calling-side gate

@Test func cleanupWaitsWhileAnotherProcessHoldsARun() async throws {
    let helper = FakePrivilegedHelper(version: SnapshotReconciler.helperVersion)
    let dir = edgeDir("gateedge"); defer { try? FileManager.default.removeItem(at: dir) }
    let locks = RunLocks(directory: dir)
    let other = Process()
    other.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
    other.arguments = ["-k", locks.lockURL("b").path, "/bin/cat"]
    let stdin = Pipe()
    other.standardInput = stdin
    try other.run()
    defer { try? stdin.fileHandleForWriting.close(); waitBounded(other) }
    for _ in 0..<50 where locks.holder(of: "b") == nil { try await Task.sleep(nanoseconds: 50_000_000) }

    let outcome = await LeftoverCleanup.run(helper: helper, locks: locks, jobIDs: ["a", "b"])
    #expect(outcome == .skippedRunInProgress("b"))
    #expect(await helper.calls.isEmpty)
}

// LeftoverCleanup is the second of two layers, there so that a mistake in the
// helper's owner check alone can't tear down a run. When the lock folder can't be
// read it can't tell whether anything runs, and it goes ahead as if nothing did.
@Test func cleanupDoesNotGoAheadWhenItCantSeeTheRunLocks() async throws {
    let helper = FakePrivilegedHelper(version: SnapshotReconciler.helperVersion)
    let dir = edgeDir("gateedge")
    defer { chmod(dir.path, 0o755); try? FileManager.default.removeItem(at: dir) }
    let locks = RunLocks(directory: dir)
    let run = try locks.acquire(jobID: "b", trigger: .scheduled)
    defer { run.release() }
    chmod(dir.path, 0o000)

    let outcome = await LeftoverCleanup.run(helper: helper, locks: locks, jobIDs: ["a", "b"])
    if case .cleaned = outcome { Issue.record("reconciled while a run held its lock, unseen") }
    #expect(await helper.calls.isEmpty)
}

@Test func helperVersionsThatArentPlainNumbersCountAsOlder() {
    #expect(LeftoverCleanup.isAtLeast("1.6", "1.6.0"))
    #expect(LeftoverCleanup.isAtLeast("1.6.0.1", "1.6.0"))
    #expect(LeftoverCleanup.isAtLeast("1.06.0", "1.6.0"))
    #expect(LeftoverCleanup.isAtLeast("1.9.9", "1.6.0"))
    #expect(!LeftoverCleanup.isAtLeast("1.5.99", "1.6.0"))
    #expect(!LeftoverCleanup.isAtLeast("0.99", "1.6.0"))
    // fail closed: an unreadable version is never trusted with reconcile
    #expect(!LeftoverCleanup.isAtLeast("1.6.0-beta1", "1.6.0"))
    #expect(!LeftoverCleanup.isAtLeast("v1.6.0", "1.6.0"))
    #expect(!LeftoverCleanup.isAtLeast(" 1.6.0", "1.6.0"))
    #expect(!LeftoverCleanup.isAtLeast("1.6.0\n", "1.6.0"))
    #expect(!LeftoverCleanup.isAtLeast("-1.6.0", "1.6.0"))
}

// MARK: - a run that starts while reconcile is unmounting

/// unmount blocks until the test lets it go; everything else is recorded.
private final class StuckBackend: SnapshotBackend, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let letGo = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var live: Set<String>
    private(set) var unmounted: [String] = []
    private(set) var deleted: [String] = []
    init(live: Set<String>) { self.live = live }

    func add(_ name: String) { lock.lock(); live.insert(name); lock.unlock() }
    func create(on volume: VolumeRef) throws -> SnapshotRef { throw SnapshotBackendError.dataVolumeNotFound }
    func mount(_ snapshot: SnapshotRef, ownerUID: uid_t) throws -> MountRef { throw SnapshotBackendError.dataVolumeNotFound }
    func unmount(_ mount: MountRef) throws {
        entered.signal()
        letGo.wait()
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

private final class Outcome: @unchecked Sendable {
    let reconciler: SnapshotReconciler
    var report: ReconcileReport?
    init(_ reconciler: SnapshotReconciler) { self.reconciler = reconciler }
}

// Reconcile now unmounts outside the helper's snapshot lock, so a live run can make
// its snapshot and mount in that gap. Reconcile planned before they existed and
// deletes from that plan afterwards: the new ones must come through untouched,
// whichever order the helper records them in.
@Test func aRunThatStartsWhileReconcileUnmountsIsLeftAlone() throws {
    let b = Books(); defer { b.cleanUp() }
    let crashed = try b.run(at: Date().addingTimeInterval(-3_600), owner: ProcessIdentity(pid: 1, startedAt: 1))
    let backend = StuckBackend(live: [crashed.snapshot])
    let snapshotLock = NSLock()
    let reconciler = SnapshotReconciler(backend: backend, ledger: b.ledger, owners: b.owners,
                                        mountBase: b.mountBase, dataVolume: dataVolume)
    let out = Outcome(reconciler), done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { out.report = out.reconciler.run(snapshotLock: snapshotLock); done.signal() }
    #expect(backend.entered.wait(timeout: .now() + 5) == .success)

    // a live run, doing what createSnapshot and mountSnapshot do, under the same lock
    let me = try #require(ProcessIdentity.current)
    snapshotLock.lock()
    let fresh = try b.run(at: Date(), owner: me)
    backend.add(fresh.snapshot)
    snapshotLock.unlock()

    backend.letGo.signal()
    #expect(done.wait(timeout: .now() + 10) == .success)

    #expect(backend.unmounted == [crashed.mount])
    #expect(backend.deleted == [crashed.snapshot])
    #expect(FileManager.default.fileExists(atPath: fresh.mount))
    #expect(b.ledger.all().contains(fresh.snapshot))
    #expect(b.owners.snapshotOwner(fresh.snapshot) == me && b.owners.mountOwner(fresh.mount) == me)
    #expect(out.report?.deletedSnapshots == [crashed.snapshot])
}
