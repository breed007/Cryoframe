//
//  ChecksAndRetentionEdgeTests.swift
//  CryoframeKitTests
//
//  Checks under the run lock, retention's known-good version, and the busy retries
//  against the real hdiutil rather than a scripted one.
//

import Testing
import Foundation
@testable import CryoframeKit

private let cal = Calendar(identifier: .gregorian)
private func day(_ d: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 8, day: d, hour: 3))! }

private func check(_ kind: String, _ verified: [VerifiedArchive], at d: Int) -> HealthRecord {
    HealthRecord(jobID: "j", jobName: "Job", checkedAt: day(d).addingTimeInterval(7200),
                 archivesChecked: verified.count, failures: verified.filter { !$0.passed }.map { "\($0.library): failed" },
                 kind: kind, verified: verified)
}

private func lockDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-chkedge-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func scratch(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-retryedge-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

private struct Boom: Error {}

@Suite struct KnownGoodEdgeTests {

    // A version that passed its drill and later failed one still counts: the pass
    // proved it restored once, and deleting it can cost the backup.
    @Test func aLaterFailureOfTheSameVersionDoesNotDisqualifyIt() {
        let versions = (1...5).map(day)
        let records = [check("drill", [VerifiedArchive(library: "Photos", version: day(2), passed: false)], at: 5),
                       check("drill", [VerifiedArchive(library: "Photos", version: day(2), passed: true)], at: 2)]
        #expect(KnownGood.version(of: "Photos", among: versions, records: records) == day(2))
    }

    // A cloud placeholder skipped by the check proved nothing; nor did a check in which
    // one destination's copy failed. The known-good version falls back past both.
    @Test func skippedAndPartlyFailedChecksAreNotKnownGood() {
        let versions = (1...5).map(day)
        let records = [
            check("drill", [VerifiedArchive(library: "Photos", version: day(5), passed: true, skipped: true)], at: 5),
            check("drill", [VerifiedArchive(library: "Photos", version: day(4), passed: true),
                            VerifiedArchive(library: "Photos", version: day(4), passed: false)], at: 4),
            check("checksum", [VerifiedArchive(library: "Photos", version: day(3), passed: true)], at: 3),
        ]
        #expect(KnownGood.version(of: "Photos", among: versions, records: records) == day(3))
    }

    // When the known-good version is one the policy keeps anyway (the newest, say),
    // nothing changes; keep-all prunes nothing whatever the checks say.
    @Test func aKnownGoodVersionThePolicyKeepsChangesNothing() {
        let versions = (1...9).map(day)
        let plain = retentionPrune(versions, policy: .keepLast(3))
        #expect(retentionPrune(versions, policy: .keepLast(3), keeping: [day(9)]) == plain)
        #expect(retentionPrune(versions, policy: .keepLast(3), keeping: [day(8)]) == plain)
        #expect(retentionPrune(versions, policy: .keepAll, keeping: [day(1)]).isEmpty)
        // grandfather-father-son: the known-good one survives its bucket being full
        let gfs = retentionPrune(versions, policy: .gfs(daily: 2, weekly: 1, monthly: 1), keeping: [day(4)])
        #expect(!gfs.contains(day(4)))
        #expect(gfs.count == retentionPrune(versions, policy: .gfs(daily: 2, weekly: 1, monthly: 1)).count - 1)
    }
}

@Suite struct CheckLockEdgeTests {

    // A check whose body throws lets go of the job: the next run isn't locked out.
    @Test func aCheckThatThrowsReleasesTheJob() throws {
        let locks = RunLocks(directory: lockDir())
        defer { try? FileManager.default.removeItem(at: locks.directory) }
        #expect(throws: Boom.self) { _ = try locks.whileChecking(jobID: "job") { () throws -> Int in throw Boom() } }
        #expect(locks.holder(of: "job") == nil)
        let lease = try locks.acquire(jobID: "job", trigger: .scheduled)
        lease.release()
    }

    // The app is running the job and Verify is pressed in the same app: the check is
    // refused at once (no wait on its own process), and the run goes on holding it.
    @Test func aCheckInTheProcessThatRunsTheJobIsRefusedAtOnce() throws {
        let locks = RunLocks(directory: lockDir())
        defer { try? FileManager.default.removeItem(at: locks.directory) }
        let run = try locks.acquire(jobID: "job", trigger: .manual)
        defer { run.release() }
        let start = ProcessInfo.processInfo.systemUptime
        guard case .busy(let holder) = locks.whileChecking(jobID: "job", { true }) else { Issue.record("checked during a run"); return }
        #expect(holder.trigger == .manual)
        #expect(ProcessInfo.processInfo.systemUptime - start < 1)
        #expect(locks.holder(of: "job")?.trigger == .manual)
    }

    // A scheduled check waits up to its limit for a run to end: one ending half way
    // through the wait is followed by the check, not by a deferral to the next pass.
    @Test func aScheduledCheckFollowsARunThatEndsWithinTheWait() throws {
        let locks = RunLocks(directory: lockDir())
        defer { try? FileManager.default.removeItem(at: locks.directory) }
        let run = try locks.acquire(jobID: "job", trigger: .scheduled)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.7) { run.release() }
        guard case .done(let v) = locks.whileChecking(jobID: "job", wait: 5, { 42 }) else { Issue.record("put off though the run ended"); return }
        #expect(v == 42)
    }

    // An interrupted transfer's resume (another chore) finds the check and waits for
    // the next pass instead of writing under it.
    @Test func aResumeFindsTheCheckAndWaits() throws {
        let locks = RunLocks(directory: lockDir())
        defer { try? FileManager.default.removeItem(at: locks.directory) }
        _ = locks.whileChecking(jobID: "job") {
            do { _ = try locks.acquire(jobID: "job", trigger: .resume); Issue.record("resumed during a check") }
            catch RunLockError.alreadyRunning(let h) { #expect(h.trigger == .check) }
            catch { Issue.record("\(error)") }
        }
    }
}

@Suite(.serialized) struct RealBusyRetryEdgeTests {

    // The real hdiutil, not a script: a second attach of an attached image fails
    // "Resource busy" and is not retried, so the caller hears at once.
    @Test func aRealSecondAttachFailsWithoutWaiting() throws {
        let d = scratch("attach")
        let img = d.appendingPathComponent("x.dmg"), m1 = d.appendingPathComponent("m1"), m2 = d.appendingPathComponent("m2")
        for m in [m1, m2] { try FileManager.default.createDirectory(at: m, withIntermediateDirectories: true) }
        defer { MountPoint.detach(m1, runner: ProcessCommandRunner()); MountPoint.detach(m2, runner: ProcessCommandRunner()); try? FileManager.default.removeItem(at: d) }
        let r = ProcessCommandRunner()
        try #require(try r.run("/usr/bin/hdiutil", ["create", "-size", "10m", "-fs", "HFS+", "-volname", "X", img.path]).ok)
        let first = try DiskImageGate.serialized { try r.runRetryingBusy("/usr/bin/hdiutil", ["attach", img.path, "-mountpoint", m1.path, "-nobrowse"]) }
        try #require(first.ok && MountPoint.isMounted(m1), "\(first.stderr)")
        let start = ProcessInfo.processInfo.systemUptime
        let second = try r.runRetryingBusy("/usr/bin/hdiutil", ["attach", img.path, "-mountpoint", m2.path, "-nobrowse"])
        let took = ProcessInfo.processInfo.systemUptime - start
        #expect(!second.ok)
        #expect(second.stderr.localizedCaseInsensitiveContains("resource busy"), "\(second.stderr)")
        #expect(took < 3, "a second attach took \(took) s: it was retried")
        #expect(MountPoint.isMounted(m1), "the first attach was disturbed")
    }

    // The real hdiutil: a detach refused because something has the volume open for
    // a moment is waited out, and succeeds once it lets go.
    @Test func aRealMomentarilyBusyDetachIsWaitedOut() throws {
        let d = scratch("detach")
        let img = d.appendingPathComponent("y.dmg"), m = d.appendingPathComponent("m")
        try FileManager.default.createDirectory(at: m, withIntermediateDirectories: true)
        defer { MountPoint.detach(m, runner: ProcessCommandRunner()); try? FileManager.default.removeItem(at: d) }
        let r = ProcessCommandRunner()
        try #require(try r.run("/usr/bin/hdiutil", ["create", "-size", "10m", "-fs", "HFS+", "-volname", "Y", img.path]).ok)
        let a = try DiskImageGate.serialized { try r.runRetryingBusy("/usr/bin/hdiutil", ["attach", img.path, "-mountpoint", m.path, "-nobrowse"]) }
        try #require(a.ok && MountPoint.isMounted(m), "\(a.stderr)")
        // something sitting in the volume for 1.5 s
        let squatter = Process()
        squatter.executableURL = URL(fileURLWithPath: "/bin/sleep"); squatter.arguments = ["1.5"]
        squatter.currentDirectoryURL = m
        try squatter.run()
        defer { if squatter.isRunning { squatter.terminate() }; waitBounded(squatter) }
        Thread.sleep(forTimeInterval: 0.2)
        let detached = try r.runRetryingBusy("/usr/bin/hdiutil", ["detach", m.path], attempts: 8)
        #expect(detached.ok, "\(detached.stderr)")
        #expect(!MountPoint.isMounted(m))
    }
}
