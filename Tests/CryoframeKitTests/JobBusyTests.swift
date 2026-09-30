//
//  JobBusyTests.swift
//  CryoframeKitTests
//
//  A job is in use while anything holds its run lock, a transfer being finished
//  included: the app counted only runs, so it offered to delete a job whose upload
//  was still being written.
//

import Testing
import Foundation
@testable import CryoframeKit

@Suite struct JobBusyTests {
    private func locks() -> RunLocks {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-busy-\(UUID().uuidString.prefix(8))")
        return RunLocks(directory: TempTracker.track(d))
    }

    @Test func everyHolderMakesTheJobBusy() throws {
        let l = locks()
        #expect(!l.isBusy("job"))
        for trigger in [RunHolder.Trigger.manual, .scheduled, .resume, .check, .cleanup] {
            let lease = try l.acquire(jobID: "job", trigger: trigger)
            #expect(l.isBusy("job"), "\(trigger)")
            lease.release()
            #expect(!l.isBusy("job"))
        }
    }

    @Test func thisProcesssOwnResumeIsSeen() throws {
        let l = locks()
        let lease = try l.acquire(jobID: "job", trigger: .resume)
        defer { lease.release() }
        let h = try #require(l.holders(of: ["job"])["job"])
        #expect(h.isThisProcess && h.trigger == .resume)
        #expect(!h.isRun)                                          // a chore, but the job is in use
        #expect(l.isBusy("job"))
    }

    @Test func aLockThatCantBeReadCountsAsBusy() throws {
        let l = locks()
        try FileManager.default.createDirectory(at: l.directory, withIntermediateDirectories: true)
        let file = l.lockURL("job")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        chmod(file.path, 0)
        defer { chmod(file.path, 0o644) }
        #expect(l.isBusy("job"))
    }
}
