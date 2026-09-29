//
//  CheckLockTests.swift
//  CryoframeKitTests
//
//  Health checks, drills and rehearsals read a job's newest version. They hold the
//  job's run lock while they do, so they never read one a run is still writing, and
//  a run that finds a check holding the job waits for the next pass.
//

import Testing
import Foundation
@testable import CryoframeKit

private func lockDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-checklock-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@Suite struct CheckLockTests {

    @Test func aCheckIsNotMadeWhileARunHoldsTheJob() throws {
        let locks = RunLocks(directory: lockDir())
        defer { try? FileManager.default.removeItem(at: locks.directory) }
        let run = try locks.acquire(jobID: "job", trigger: .manual)
        var ran = false
        let checked = locks.whileChecking(jobID: "job") { ran = true }
        guard case .busy(let holder) = checked else { Issue.record("checked while a run held the job: \(checked)"); return }
        #expect(holder.trigger == .manual)
        #expect(!ran)
        run.release()
        guard case .done = locks.whileChecking(jobID: "job", { ran = true }) else { Issue.record("not checked once the run ended"); return }
        #expect(ran)
        #expect(locks.holder(of: "job") == nil, "the check kept the lock")
    }

    // The case the lock exists for: the run is in another process (the scheduled
    // agent, while the app's Verify button is pressed).
    @Test func aRunInAnotherProcessHoldsOffTheCheck() throws {
        let locks = RunLocks(directory: lockDir())
        defer { try? FileManager.default.removeItem(at: locks.directory) }
        let other = Process()
        other.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        other.arguments = ["-k", locks.lockURL("job").path, "/bin/cat"]
        let stdin = Pipe()
        other.standardInput = stdin
        other.standardOutput = FileHandle.nullDevice
        try other.run()
        defer { try? stdin.fileHandleForWriting.close(); waitBounded(other) }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while locks.holder(of: "job") == nil, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.05) }
        try #require(locks.holder(of: "job") != nil, "lockf never took the lock")
        let start = ProcessInfo.processInfo.systemUptime
        let checked = locks.whileChecking(jobID: "job", wait: 0.5) { true }
        guard case .busy = checked else { Issue.record("checked while another process held the job"); return }
        #expect(ProcessInfo.processInfo.systemUptime - start >= 0.4, "didn't wait for the run")
    }

    // While a check holds the job, a scheduled run waits for the next pass and says
    // why; a check isn't a backup, so it doesn't count as the job running.
    @Test func aRunFindingACheckWaitsAndSaysWhy() throws {
        let locks = RunLocks(directory: lockDir())
        defer { try? FileManager.default.removeItem(at: locks.directory) }
        _ = locks.whileChecking(jobID: "job") {
            #expect(locks.runningJobIDs(among: ["job"]).isEmpty)
            #expect(locks.holder(of: "job")?.runningLabel == "checking its archives")
            do {
                _ = try locks.acquire(jobID: "job", trigger: .scheduled)
                Issue.record("a run started during a check")
            } catch RunLockError.alreadyRunning(let holder) {
                #expect(holder.trigger == .check)
                #expect(holder.deferralReason == "this job's archives were being checked — it runs at the next check")
                #expect(RunLockError.alreadyRunning(holder).localizedDescription.hasPrefix("its archives are being checked"))
            } catch {
                Issue.record("\(error)")
            }
        }
    }

    // A job skipped because a run held it is looked at on the next hourly pass.
    @Test func aSkippedJobIsCheckedAtTheNextPass() {
        func job(_ id: String) -> BackupJob {
            BackupJob(id: id, name: id, libraries: [.photos], target: .localVolume(id: "t", name: "Disk", dir: URL(fileURLWithPath: "/x")),
                      format: .sealedZip, frequency: .manual, createdAt: Date(timeIntervalSince1970: 0))
        }
        let all = [job("a"), job("b"), job("c")]
        #expect(CheckRound.jobs(all, due: true, pending: ["b"]).map(\.id) == ["a", "b", "c"])
        #expect(CheckRound.jobs(all, due: false, pending: ["b"]).map(\.id) == ["b"])
        #expect(CheckRound.jobs(all, due: false, pending: []).isEmpty)
    }
}
