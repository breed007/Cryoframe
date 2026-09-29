//
//  RunLockTests.swift
//  CryoframeKitTests
//
//  One run per job across the app and the scheduled agent. The lock is an flock(2)
//  on a per-job file, so most of these hold it from a second descriptor in this
//  process; the ones that matter most hold it from a genuinely separate process
//  (/usr/bin/lockf), because that is the case the lock exists for.
//

import Testing
import Foundation
@testable import CryoframeKit

private func tempDir(_ tag: String = "locks") -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// another process holding `file` locked (flock) until `release()` closes its stdin.
private final class OtherProcessHolding {
    let process = Process()
    private let stdin = Pipe()

    init(_ file: URL) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        process.arguments = ["-k", file.path, "/bin/cat"]
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        try process.run()
    }

    /// wait until the lock is really held (lockf takes it after launching).
    func waitUntilHeld(_ locks: RunLocks, jobID: String) -> Bool {
        for _ in 0..<50 {
            if locks.holder(of: jobID) != nil { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    func kill9() { kill(process.processIdentifier, SIGKILL) }

    func release() {
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit()
    }
}

// MARK: - the lock

@Test func aSecondRunOfTheSameJobIsRefusedAndToldWhoHasIt() throws {
    let locks = RunLocks(directory: tempDir())
    defer { try? FileManager.default.removeItem(at: locks.directory) }
    let first = try locks.acquire(jobID: "job", trigger: .scheduled)
    #expect(throws: RunLockError.alreadyRunning(first.holder)) {
        _ = try locks.acquire(jobID: "job", trigger: .manual)
    }
    do { _ = try locks.acquire(jobID: "job", trigger: .manual); Issue.record("second run started") }
    catch { #expect(error.localizedDescription == "already running (scheduled)") }

    first.release()
    let again = try locks.acquire(jobID: "job", trigger: .manual)
    #expect(again.holder.trigger == .manual)
    again.release()
}

@Test func differentJobsDoNotBlockEachOther() throws {
    let locks = RunLocks(directory: tempDir())
    defer { try? FileManager.default.removeItem(at: locks.directory) }
    let a = try locks.acquire(jobID: "a", trigger: .manual)
    let b = try locks.acquire(jobID: "b", trigger: .scheduled)
    #expect(a.isHeld && b.isHeld)
    a.release(); b.release()
}

@Test func lookingAtTheLockNeverTakesIt() throws {
    let locks = RunLocks(directory: tempDir())
    defer { try? FileManager.default.removeItem(at: locks.directory) }
    #expect(locks.holder(of: "job") == nil)                    // never locked
    let lease = try locks.acquire(jobID: "job", trigger: .scheduled)
    let seen = try #require(locks.holder(of: "job"))
    #expect(seen == lease.holder && seen.pid == getpid() && seen.isThisProcess)
    #expect(seen.runningLabel == "running (scheduled)")
    #expect(locks.holders(of: ["job", "other"]).keys.sorted() == ["job"])
    lease.release()
    #expect(locks.holder(of: "job") == nil)
    // released means forgotten: the old holder's identity isn't left behind
    #expect((try? Data(contentsOf: locks.lockURL("job")))?.isEmpty == true)
}

@Test func aJobLockedByAnotherProcessIsRefusedUntilThatProcessEnds() throws {
    let locks = RunLocks(directory: tempDir())
    defer { try? FileManager.default.removeItem(at: locks.directory) }
    try FileManager.default.createDirectory(at: locks.directory, withIntermediateDirectories: true)
    let other = try OtherProcessHolding(locks.lockURL("job"))
    #expect(other.waitUntilHeld(locks, jobID: "job"))
    #expect(locks.holder(of: "job")?.trigger == .unknown)      // lockf doesn't say who it is
    #expect(throws: RunLockError.self) { _ = try locks.acquire(jobID: "job", trigger: .manual) }
    other.release()
    let lease = try locks.acquire(jobID: "job", trigger: .manual)
    lease.release()
}

@Test func aHolderThatIsKilledReleasesTheLock() throws {
    let locks = RunLocks(directory: tempDir())
    defer { try? FileManager.default.removeItem(at: locks.directory) }
    try FileManager.default.createDirectory(at: locks.directory, withIntermediateDirectories: true)
    let other = try OtherProcessHolding(locks.lockURL("job"))
    #expect(other.waitUntilHeld(locks, jobID: "job"))
    other.kill9()
    other.release()                  // lockf's own child exits on EOF; nothing left holding it
    let lease = try locks.acquire(jobID: "job", trigger: .scheduled, wait: 2)
    #expect(lease.isHeld)
    lease.release()
}

@Test func aToolTheRunLaunchesDoesNotInheritTheLock() throws {
    let locks = RunLocks(directory: tempDir())
    defer { try? FileManager.default.removeItem(at: locks.directory) }
    let lease = try locks.acquire(jobID: "job", trigger: .manual)
    let tool = Process()
    tool.executableURL = URL(fileURLWithPath: "/bin/sleep")
    tool.arguments = ["30"]
    try tool.run()
    defer { tool.terminate(); tool.waitUntilExit() }
    // the run's process dies without unlocking; the tool it launched lives on
    lease.closeWithoutUnlocking()
    let next = try locks.acquire(jobID: "job", trigger: .scheduled)
    next.release()
}

@Test func aShortWaitRidesOutAMomentaryHolder() throws {
    let locks = RunLocks(directory: tempDir())
    defer { try? FileManager.default.removeItem(at: locks.directory) }
    let brief = try locks.acquire(jobID: "job", trigger: .cleanup)
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { brief.release() }
    let lease = try locks.acquire(jobID: "job", trigger: .scheduled, wait: 3)
    #expect(lease.holder.trigger == .scheduled)
    lease.release()
}

@Test func withLockDoesNotRunTheBodyWhenBusy() throws {
    let locks = RunLocks(directory: tempDir())
    defer { try? FileManager.default.removeItem(at: locks.directory) }
    let held = try locks.acquire(jobID: "job", trigger: .scheduled)
    var ran = false
    #expect(throws: RunLockError.self) { try locks.withLock(jobID: "job", trigger: .resume) { _ in ran = true } }
    #expect(!ran)
    held.release()
    try locks.withLock(jobID: "job", trigger: .resume) { _ in ran = true }
    #expect(ran)
    #expect(locks.holder(of: "job") == nil)
}

@Test func oddJobIDsStillGetOneFileEach() {
    #expect(RunLocks.safe("../x/y") == ".._x_y")
    #expect(RunLocks.safe("..") == "_")
    #expect(RunLocks.safe("") == "_")
    #expect(RunLocks.safe("9C1F-AB_2.x") == "9C1F-AB_2.x")
}

@Test func lockErrorsSayWhatIsRunning() {
    func text(_ t: RunHolder.Trigger) -> String? {
        RunLockError.alreadyRunning(RunHolder(pid: 1, trigger: t, runID: "r", startedAt: .distantPast)).errorDescription
    }
    #expect(text(.scheduled) == "already running (scheduled)")
    #expect(text(.manual) == "already running")
    #expect(text(.resume) == "already running (resuming an interrupted transfer)")
    #expect(text(.unknown) == "already running")
}

// MARK: - Stop from another process

@Test func stopReachesTheRunThatHoldsTheLock() async throws {
    let locks = RunLocks(directory: tempDir())
    defer { try? FileManager.default.removeItem(at: locks.directory) }
    let lease = try locks.acquire(jobID: "job", trigger: .scheduled)
    let control = RunControl()
    lease.onStopRequest(every: 0.1) { control.cancel() }
    #expect(!lease.stopRequested)
    #expect(locks.requestStop(jobID: "job"))
    #expect(lease.stopRequested)
    for _ in 0..<50 where !control.isCancelled { try await Task.sleep(nanoseconds: 50_000_000) }
    #expect(control.isCancelled)
    lease.release()
}

@Test func aStopMeantForAnEarlierRunDoesNotStopTheNextOne() throws {
    let locks = RunLocks(directory: tempDir())
    defer { try? FileManager.default.removeItem(at: locks.directory) }
    let first = try locks.acquire(jobID: "job", trigger: .scheduled)
    #expect(locks.requestStop(jobID: "job"))
    first.release()                                   // ended on its own before it saw the request
    let second = try locks.acquire(jobID: "job", trigger: .scheduled)
    #expect(!second.stopRequested)
    second.release()
}

@Test func stopWithNobodyRunningDoesNothing() {
    let locks = RunLocks(directory: tempDir())
    defer { try? FileManager.default.removeItem(at: locks.directory) }
    #expect(!locks.requestStop(jobID: "job"))
    #expect(!FileManager.default.fileExists(atPath: locks.stopURL("job").path))
}

// MARK: - resuming transfers and tidying scratch respect a running job

@Test func aTransferIsNotResumedWhileItsJobIsRunning() throws {
    let base = tempDir("resume"); defer { try? FileManager.default.removeItem(at: base) }
    let buildDir = base.appendingPathComponent("scratch/job/build/lib", isDirectory: true)
    try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
    let src = buildDir.appendingPathComponent("Lib.dmg")
    try Data(repeating: 7, count: 5_000).write(to: src)
    let dest = base.appendingPathComponent("dest")
    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    let store = PendingTransferStore(url: base.appendingPathComponent("pending.json"))
    store.save(PendingTransfer(jobID: "job:dest:lib", sourceFile: src.path, baseName: "Lib.dmg",
                               totalBytes: 5_000, chunkSize: 1_000, targetDir: dest.path, format: .sealedDMG, encrypted: false))
    let locks = RunLocks(directory: base.appendingPathComponent("locks"))

    // the job is running (in whichever process): its own run owns the transfer now
    let run = try locks.acquire(jobID: "job", trigger: .scheduled)
    #expect(TransferResumer.resumeAll(store: store, reachable: { _ in true }, locks: locks).isEmpty)
    #expect(store.all().count == 1)
    #expect(((try? FileManager.default.contentsOfDirectory(atPath: dest.path)) ?? []).isEmpty)
    run.release()

    #expect(TransferResumer.resumeAll(store: store, reachable: { _ in true }, locks: locks) == ["job:dest:lib"])
    #expect(store.all().isEmpty)
    #expect(locks.holder(of: "job") == nil)
}

@Test func tidyingScratchLeavesARunningJobsBuildAlone() throws {
    let base = tempDir("sweep"); defer { try? FileManager.default.removeItem(at: base) }
    let scratch = base.appendingPathComponent("scratch")
    let running = scratch.appendingPathComponent("running-job/build/lib", isDirectory: true)
    let crashed = scratch.appendingPathComponent("crashed-job/build/lib", isDirectory: true)
    for d in [running, crashed] {
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try Data("half-built".utf8).write(to: d.appendingPathComponent("Lib.dmg"))
    }
    let store = PendingTransferStore(url: base.appendingPathComponent("pending.json"))
    let locks = RunLocks(directory: base.appendingPathComponent("locks"))

    // the agent is mid-build on one job when the app launches and tidies up
    let run = try locks.acquire(jobID: "running-job", trigger: .scheduled)
    JobExecutor.sweepOrphanedScratch(scratchBase: scratch, pendingStore: store, locks: locks)
    #expect(FileManager.default.fileExists(atPath: running.appendingPathComponent("Lib.dmg").path))
    #expect(!FileManager.default.fileExists(atPath: crashed.path))
    run.release()

    JobExecutor.sweepOrphanedScratch(scratchBase: scratch, pendingStore: store, locks: locks)
    #expect(!FileManager.default.fileExists(atPath: running.path))
}

// MARK: - a lock folder it can't read

@Test func aLockFolderThatCantBeReadIsNeitherFreeNorHeld() throws {
    let dir = tempDir(); defer { chmod(dir.path, 0o755); try? FileManager.default.removeItem(at: dir) }
    let locks = RunLocks(directory: dir)
    chmod(dir.path, 0o000)
    guard case .unreadable = locks.look("job") else {
        Issue.record("an unreadable lock folder read as \(locks.look("job"))"); return
    }
    // the job list still shows it as idle rather than painting every job as running
    #expect(locks.holder(of: "job") == nil)
}

@Test func cleanupDoesNotGoAheadWhenTheLockFolderCantBeRead() async throws {
    let helper = FakePrivilegedHelper(version: SnapshotReconciler.helperVersion)
    let dir = tempDir(); defer { chmod(dir.path, 0o755); try? FileManager.default.removeItem(at: dir) }
    let locks = RunLocks(directory: dir)
    chmod(dir.path, 0o000)
    let outcome = await LeftoverCleanup.run(helper: helper, locks: locks, jobIDs: ["a"])
    if case .cleaned = outcome { Issue.record("reconciled without being able to see the run locks") }
    #expect(await helper.calls.isEmpty)
}

// MARK: - a lock file removed while held

/// 0 when another process could take the lock on `file` right now, 75 when it's held.
private func lockfCanTake(_ file: URL) throws -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
    p.arguments = ["-k", "-t", "0", file.path, "/usr/bin/true"]
    p.standardError = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

@Test func aRunWhoseLockFileIsRemovedLocksItAgainForOtherProcesses() throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let locks = RunLocks(directory: dir)
    let lease = try locks.acquire(jobID: "job", trigger: .scheduled)
    defer { lease.release() }
    try FileManager.default.removeItem(at: locks.lockURL("job"))

    // within a second the run puts its lock file back and holds it again
    var status: Int32 = 0
    for _ in 0..<40 {
        if FileManager.default.fileExists(atPath: locks.lockURL("job").path),
           try lockfCanTake(locks.lockURL("job")) == 75 { status = 75; break }
        Thread.sleep(forTimeInterval: 0.1)
    }
    #expect(status == 75, "another process could take the lock of a job that is still running")
}

// MARK: - Stop reaches a resumed transfer

@Test func stopReachesAResumedTransfer() throws {
    let base = tempDir("resume-stop"); defer { try? FileManager.default.removeItem(at: base) }
    let buildDir = base.appendingPathComponent("scratch/job/build/lib", isDirectory: true)
    try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
    let src = buildDir.appendingPathComponent("Lib.dmg")
    try Data(repeating: 7, count: 5_000).write(to: src)
    let dest = base.appendingPathComponent("dest")
    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    let store = PendingTransferStore(url: base.appendingPathComponent("pending.json"))
    store.save(PendingTransfer(jobID: "job:dest:lib", sourceFile: src.path, baseName: "Lib.dmg",
                               totalBytes: 5_000, chunkSize: 1_000, targetDir: dest.path, format: .sealedDMG, encrypted: false))
    let locks = RunLocks(directory: base.appendingPathComponent("locks"))

    // Stop pressed in the other process while the first part is shipping
    let resumed = TransferResumer.resumeAll(store: store, reachable: { _ in true }, locks: locks,
                                            afterPart: { _ in _ = locks.requestStop(jobID: "job") })

    #expect(resumed.isEmpty)
    #expect(store.all().first?.completed.count == 1)        // stopped after the part in hand
    #expect(locks.holder(of: "job") == nil)
    // stopped, not abandoned: the next pass finishes it
    #expect(TransferResumer.resumeAll(store: store, reachable: { _ in true }, locks: locks) == ["job:dest:lib"])
}

// MARK: - chores aren't runs

@Test func aJobHeldForAChoreIsNotRunning() throws {
    let locks = RunLocks(directory: tempDir())
    defer { try? FileManager.default.removeItem(at: locks.directory) }
    let tidy = try locks.acquire(jobID: "a", trigger: .cleanup)
    let resume = try locks.acquire(jobID: "b", trigger: .resume)
    let run = try locks.acquire(jobID: "c", trigger: .scheduled)
    defer { tidy.release(); resume.release(); run.release() }
    #expect(locks.runningJobIDs(among: ["a", "b", "c", "d"]) == ["c"])
    #expect(!tidy.holder.isRun && !resume.holder.isRun && run.holder.isRun)
    #expect(RunHolder.unknown.isRun)                          // can't tell: treat it as a run
}
