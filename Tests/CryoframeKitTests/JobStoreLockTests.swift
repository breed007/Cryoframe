//
//  JobStoreLockTests.swift
//  CryoframeKitTests
//
//  The app and the scheduled agent both write the job files; a write is a load, a
//  change and a save, and two at once lost one of them (see JobStore.update).
//

import Testing
import Foundation
@testable import CryoframeKit

private let start = Date(timeIntervalSince1970: 1_790_000_000)

private func scratch(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-storelock-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return TempTracker.track(d)
}

private func job() -> BackupJob {
    BackupJob(id: "job-1", name: "Papers",
              libraries: [.genericFolder(id: "/p", displayName: "Papers", path: .absolute("/p"))],
              target: .localVolume(id: "/Volumes/NAS/Backups", name: "NAS", dir: URL(fileURLWithPath: "/Volumes/NAS/Backups")),
              format: .sealedDMG, frequency: .daily(hour: 2, minute: 0), createdAt: start)
}

@Suite struct JobStoreLockTests {
    // MARK: the store's lock

    @Test func twoStoresOnOneFileLoseNoWrite() async {
        let dir = scratch("race")
        let url = dir.appendingPathComponent("jobs.json")
        JobStore(url: url).upsert(job())
        // two instances share only the file lock, as the app and the agent do
        let a = JobStore(url: url), b = JobStore(url: url)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<40 {
                let store = i.isMultiple(of: 2) ? a : b
                group.addTask { store.recordCopies(jobID: "job-1", targetIDs: ["t\(i)"], at: start) }
            }
        }
        #expect(JobStore(url: url).load().lastCopy["job-1"]?.count == 40)
    }

    @Test func aWriteWaitsForAnotherProcessHoldingTheLock() throws {
        let dir = scratch("proc")
        let store = JobStore(url: dir.appendingPathComponent("jobs.json"))
        store.upsert(job())
        FileManager.default.createFile(atPath: store.lockURL.path, contents: nil)
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        holder.arguments = ["-k", store.lockURL.path, "/bin/cat"]
        let stdin = Pipe(); holder.standardInput = stdin
        try holder.run()
        defer { if holder.isRunning { holder.terminate() } }
        // wait until the other process has it
        let probe = open(store.lockURL.path, O_RDONLY)
        defer { close(probe) }
        var held = false
        for _ in 0..<100 where !held {
            if flock(probe, LOCK_EX | LOCK_NB) == 0 { flock(probe, LOCK_UN); usleep(20_000) } else { held = true }
        }
        #expect(held)

        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { store.recordRun(id: "job-1", at: start); done.signal() }
        #expect(done.wait(timeout: .now() + 0.6) == .timedOut)          // waits while held
        try stdin.fileHandleForWriting.close()                          // the other process lets go
        #expect(done.wait(timeout: .now() + 5) == .success)
        #expect(store.load().lastRun["job-1"] == start)
    }
}
