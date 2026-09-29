//
//  RunLockEdgeTests.swift
//  CryoframeKitTests
//
//  The run lock at its edges: a lock folder that isn't there or can't be written,
//  holder details caught half written, stop requests left over from an earlier run,
//  many takers at once, a lock held by this process as seen from another one, and
//  a lock file removed while a run holds it.
//

import Testing
import Foundation
@testable import CryoframeKit

private func edgeDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("cf-lockedge-\(UUID().uuidString)")
}

private func remove(_ dir: URL) {
    chmod(dir.path, 0o755)
    try? FileManager.default.removeItem(at: dir)
}

/// another process holding `file` with flock(2) until `release()` closes its stdin.
private final class LockfHolder {
    let process = Process()
    private let stdin = Pipe()

    init(_ file: URL) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        process.arguments = ["-k", file.path, "/bin/cat"]
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        try process.run()
    }

    func waitUntilHeld(_ locks: RunLocks, jobID: String) -> Bool {
        for _ in 0..<50 {
            if locks.holder(of: jobID) != nil { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    func release() {
        try? stdin.fileHandleForWriting.close()
        waitBounded(process)
    }
}

/// exit status of `lockf -k -t 0 <file> /usr/bin/true`: 0 when another process could
/// take the lock right now, 75 (EX_TEMPFAIL) when someone holds it.
private func lockfCanTake(_ file: URL) throws -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
    p.arguments = ["-k", "-t", "0", file.path, "/usr/bin/true"]
    p.standardError = FileHandle.nullDevice
    try p.run()
    return waitBounded(p) ?? -1
}

// MARK: - the lock folder

@Test func aMissingLockFolderMeansNothingIsRunningAndIsMadeByTheFirstRun() throws {
    let dir = edgeDir(); defer { remove(dir) }
    let locks = RunLocks(directory: dir)

    #expect(locks.holder(of: "job") == nil)
    #expect(!locks.requestStop(jobID: "job"))
    // looking and asking to stop create nothing
    #expect(!FileManager.default.fileExists(atPath: dir.path))

    let lease = try locks.acquire(jobID: "job", trigger: .manual)
    #expect(FileManager.default.fileExists(atPath: locks.lockURL("job").path))
    #expect(locks.holder(of: "job") == lease.holder)
    lease.release()
}

@Test func aLockFolderThatCantBeWrittenIsReportedAsUnavailableNotAsBusy() throws {
    let dir = edgeDir(); defer { remove(dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    chmod(dir.path, 0o500)
    let locks = RunLocks(directory: dir)

    do {
        let lease = try locks.acquire(jobID: "job", trigger: .scheduled)
        lease.release()
        Issue.record("took a lock whose file it could not create")
    } catch let e as RunLockError {
        guard case .unavailable = e else { Issue.record("expected .unavailable, got \(e)"); return }
        // a user reading the run history should learn it's a lock problem, not a busy job
        #expect(e.localizedDescription.hasPrefix("couldn't check whether this job is already running"))
    }
}

// MARK: - holder details

// The holder writes its details just after it takes the lock, and a reader can catch
// the file between truncate and write, or a writer that died mid-write. Either way
// the job must still read as running, and Stop must not aim at a run id it made up.
@Test func halfWrittenHolderDetailsReadAsUnknownAndCantBeStopped() throws {
    let dir = edgeDir(); defer { remove(dir) }
    let locks = RunLocks(directory: dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let other = try LockfHolder(locks.lockURL("job"))
    defer { other.release() }
    #expect(other.waitUntilHeld(locks, jobID: "job"))

    // written in place, never replaced: a new inode would be a different lock
    let h = try FileHandle(forWritingTo: locks.lockURL("job"))
    try h.write(contentsOf: Data(#"{"pid":4242,"trigger":"sched"#.utf8))
    try h.close()

    let seen = try #require(locks.holder(of: "job"))
    #expect(seen.trigger == .unknown && seen.runID.isEmpty && seen.pid == 0)
    #expect(seen.runningLabel == "running")
    #expect(!locks.requestStop(jobID: "job"))
    #expect(!FileManager.default.fileExists(atPath: locks.stopURL("job").path))
}

// MARK: - stop requests

@Test func aStopLeftFromAnEarlierRunIsClearedWhenTheNextRunStarts() async throws {
    let dir = edgeDir(); defer { remove(dir) }
    let locks = RunLocks(directory: dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // a request for a run that ended (or crashed) before it saw it
    try Data("an-earlier-run".utf8).write(to: locks.stopURL("job"))

    let lease = try locks.acquire(jobID: "job", trigger: .scheduled)
    defer { lease.release() }
    #expect(!FileManager.default.fileExists(atPath: locks.stopURL("job").path))
    #expect(!lease.stopRequested)

    let control = RunControl()
    lease.onStopRequest(every: 0.05) { control.cancel() }

    // a request naming some other run is not this run's
    try Data("an-earlier-run".utf8).write(to: locks.stopURL("job"))
    try await Task.sleep(nanoseconds: 400_000_000)
    #expect(!control.isCancelled)

    // the real one is
    #expect(locks.requestStop(jobID: "job"))
    for _ in 0..<40 where !control.isCancelled { try await Task.sleep(nanoseconds: 50_000_000) }
    #expect(control.isCancelled)
}

@Test func aStopArrivingAfterTheRunEndedIsNotHeard() async throws {
    let dir = edgeDir(); defer { remove(dir) }
    let locks = RunLocks(directory: dir)
    let lease = try locks.acquire(jobID: "job", trigger: .scheduled)
    let control = RunControl()
    lease.onStopRequest(every: 0.05) { control.cancel() }
    let runID = lease.holder.runID
    lease.release()

    try Data(runID.utf8).write(to: locks.stopURL("job"))
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(!control.isCancelled)
}

@Test func everyRunGetsItsOwnRunID() throws {
    let dir = edgeDir(); defer { remove(dir) }
    let locks = RunLocks(directory: dir)
    var ids = Set<String>()
    for _ in 0..<100 {
        let lease = try locks.acquire(jobID: "job", trigger: .manual)
        ids.insert(lease.holder.runID)
        lease.release()
    }
    #expect(ids.count == 100)
    #expect(!ids.contains(""))
}

// MARK: - contention

@Test func manyTakersAtOnceGetExactlyOneLock() throws {
    let dir = edgeDir(); defer { remove(dir) }
    let locks = RunLocks(directory: dir)
    let tally = Tally()

    DispatchQueue.concurrentPerform(iterations: 16) { _ in
        do {
            tally.won(try locks.acquire(jobID: "job", trigger: .manual))
        } catch RunLockError.alreadyRunning {
            tally.refused()
        } catch {
            tally.failed(error)
        }
    }
    #expect(tally.winners.count == 1)
    #expect(tally.busy == 15)
    #expect(tally.other.isEmpty)
    tally.winners.forEach { $0.release() }
}

private final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var winners: [RunLease] = []       // held until the end, so no winner lets a second in
    private(set) var busy = 0
    private(set) var other: [String] = []
    func won(_ lease: RunLease) { lock.lock(); winners.append(lease); lock.unlock() }
    func refused() { lock.lock(); busy += 1; lock.unlock() }
    func failed(_ error: Error) { lock.lock(); other.append("\(error)"); lock.unlock() }
}

@Test func anotherProcessCantTakeALockThisRunHolds() throws {
    let dir = edgeDir(); defer { remove(dir) }
    let locks = RunLocks(directory: dir)
    let lease = try locks.acquire(jobID: "job", trigger: .scheduled)
    #expect(try lockfCanTake(locks.lockURL("job")) == 75)
    lease.release()
    #expect(try lockfCanTake(locks.lockURL("job")) == 0)
}

@Test func aLeaseDroppedWithoutReleaseGivesTheLockBack() throws {
    let dir = edgeDir(); defer { remove(dir) }
    let locks = RunLocks(directory: dir)
    do { _ = try locks.acquire(jobID: "job", trigger: .manual) }     // never released by hand
    #expect(locks.holder(of: "job") == nil)
    let next = try locks.acquire(jobID: "job", trigger: .scheduled)
    next.release()
}

// The lock is the file's inode, not its path. Nothing in the app deletes a lock file,
// but the user can (clearing Application Support, or deleting the folder while a
// backup runs). Once the path points at a new inode, a second run can lock that one
// and both runs write the same destination.
@Test func aLockFileRemovedWhileHeldDoesNotLetASecondRunIn() throws {
    let dir = edgeDir(); defer { remove(dir) }
    let locks = RunLocks(directory: dir)
    let first = try locks.acquire(jobID: "job", trigger: .scheduled)
    defer { first.release() }

    try FileManager.default.removeItem(at: locks.lockURL("job"))

    #expect(locks.holder(of: "job") != nil, "a running job reads as idle once its lock file is gone")
    do {
        let second = try locks.acquire(jobID: "job", trigger: .manual)
        second.release()
        Issue.record("a second run of the same job started while the first still held its lock")
    } catch RunLockError.alreadyRunning {
        // right: still one run per job
    }
}

// MARK: - a run putting its lock file back

/// wait up to `seconds` for another process to find the lock at `file` held. Timed
/// on uptime, which stops while the Mac sleeps, as the lease's own check does: a wall
/// clock deadline can pass during a sleep before the lease has had a chance to look.
private func becomesHeldForOthers(_ file: URL, within seconds: Double) throws -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    while ProcessInfo.processInfo.systemUptime < deadline {
        if FileManager.default.fileExists(atPath: file.path), try lockfCanTake(file) == 75 { return true }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return false
}

// Deleting the whole folder is what clearing Application Support mid-backup does.
@Test func aRunPutsItsLockBackWhenTheWholeLockFolderIsRemoved() throws {
    let dir = edgeDir(); defer { remove(dir) }
    let locks = RunLocks(directory: dir)
    let lease = try locks.acquire(jobID: "job", trigger: .scheduled)
    defer { lease.release() }

    try FileManager.default.removeItem(at: dir)

    #expect(try becomesHeldForOthers(locks.lockURL("job"), within: 3))
    // and says who holds it, so Stop from the other process can still name this run
    Thread.sleep(forTimeInterval: 0.1)
    let written = try JSONDecoder().decode(RunHolder.self, from: Data(contentsOf: locks.lockURL("job")))
    #expect(written.runID == lease.holder.runID)
}

// The stated residual: another process that locks the re-created file inside the
// one-second window gets in. Once it lets go, the run must take its lock back, so
// the window doesn't stay open for the rest of the run.
@Test func aRunTakesItsLockBackOnceAProcessThatSlippedInLetsGo() throws {
    let dir = edgeDir(); defer { remove(dir) }
    let locks = RunLocks(directory: dir)
    let lease = try locks.acquire(jobID: "job", trigger: .scheduled)
    defer { lease.release() }

    try FileManager.default.removeItem(at: locks.lockURL("job"))
    let other = try LockfHolder(locks.lockURL("job"))          // gets there before the run's next check
    Thread.sleep(forTimeInterval: 1.5)                          // the run has checked, and lost
    other.release()

    #expect(try becomesHeldForOthers(locks.lockURL("job"), within: 3))
}

@Test func releasingARunWhoseLockWasPutBackFreesEveryCopy() throws {
    let dir = edgeDir(); defer { remove(dir) }
    let locks = RunLocks(directory: dir)
    let lease = try locks.acquire(jobID: "job", trigger: .scheduled)
    for _ in 0..<2 {
        try FileManager.default.removeItem(at: locks.lockURL("job"))
        #expect(try becomesHeldForOthers(locks.lockURL("job"), within: 3))
    }
    lease.release()

    #expect(try lockfCanTake(locks.lockURL("job")) == 0)
    #expect(locks.holder(of: "job") == nil)
    let next = try RunLocks(directory: dir).acquire(jobID: "job", trigger: .manual)
    next.release()
}

// A lock file the user can't read might be a run's: the cleanup gate must treat it
// as busy (look says unreadable), while a run trying to start reports the lock as
// unavailable rather than starting unlocked.
@Test func aLockFileThatCantBeOpenedIsUnreadableNotFree() throws {
    let dir = edgeDir(); defer { remove(dir) }
    let locks = RunLocks(directory: dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: locks.lockURL("job").path, contents: nil)
    chmod(locks.lockURL("job").path, 0o000)
    defer { chmod(locks.lockURL("job").path, 0o644) }

    guard case .unreadable = locks.look("job") else { Issue.record("read as \(locks.look("job"))"); return }
    do {
        let lease = try locks.acquire(jobID: "job", trigger: .scheduled)
        lease.release()
        Issue.record("started a run on a lock file it couldn't open")
    } catch let e as RunLockError {
        guard case .unavailable = e else { Issue.record("expected .unavailable, got \(e)"); return }
    }
}
