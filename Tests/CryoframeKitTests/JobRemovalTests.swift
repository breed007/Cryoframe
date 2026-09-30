//
//  JobRemovalTests.swift
//  CryoframeKitTests
//
//  Deleting a job (see JobRemoval): refused while anything uses it, refused when
//  what it would do changed since it was shown, and when it goes ahead, its backups
//  are untouched and only its own records and staged copies go.
//

import Testing
import Foundation
import CryptoKit
@testable import CryoframeKit

private let start = Date(timeIntervalSince1970: 1_790_000_000)

private func scratch(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-remove-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return TempTracker.track(d) }
    defer { free(real) }
    return TempTracker.track(URL(fileURLWithPath: String(cString: real), isDirectory: true))
}

/// every file under `dir` with its bytes' digest, and every folder
private func tree(_ dir: URL) -> [String: String] {
    var out: [String: String] = [:]
    let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey])
    while let u = e?.nextObject() as? URL {
        let rel = String(u.path.dropFirst(dir.path.count))
        if (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { out[rel] = "dir"; continue }
        let data = (try? Data(contentsOf: u)) ?? Data()
        out[rel] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    return out
}

private struct Setup {
    let base: URL, dest: URL, scratchBase: URL
    let job: BackupJob, other: BackupJob
    let store: JobStore, pending: PendingTransferStore, locks: RunLocks
}

/// a sealed job with a version at its destination, an interrupted upload (two
/// parts there, its staged copy in scratch), and another job's upload
private func setup(_ tag: String) throws -> Setup {
    let base = scratch(tag)
    let dest = base.appendingPathComponent("NAS/Backups")
    let lib = ContentType.genericFolder(id: "papers", displayName: "Papers", path: .absolute("/nowhere/Papers"))
    let target = Target.networkShare(id: "nas", name: "Backups on NAS", dir: dest,
                                     mount: NetworkMountSpec(url: URL(string: "smb://nas/share")!, mountpoint: dest.path))
    let job = BackupJob(id: "job-1", name: "Papers", libraries: [lib], target: target, format: .sealedDMG,
                        frequency: .daily(hour: 2, minute: 0), encrypted: true, retention: .keepLast(3), createdAt: start)
    let other = BackupJob(id: "job-2", name: "Other", libraries: [lib], target: target, format: .sealedZip,
                          frequency: .manual, createdAt: start)
    let folder = try LibraryFolders.prepare(job: job, library: lib, in: dest, jobs: [job], isOpen: { _ in false }).folder
    let v = folder.appendingPathComponent("2026-09-01-020000")
    try FileManager.default.createDirectory(at: v, withIntermediateDirectories: true)
    try Data("archive".utf8).write(to: v.appendingPathComponent("Papers.dmg"))
    _ = try ArchiveManifest.write(try ArchiveManifest.build(for: ArchiveResult(artifacts: [v.appendingPathComponent("Papers.dmg")],
                                                                               format: .sealedDMG)), toDir: v)
    let partial = folder.appendingPathComponent("2026-09-30-020000")
    try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 100).write(to: partial.appendingPathComponent("Papers.dmg.part.000"))
    try Data(repeating: 2, count: 100).write(to: partial.appendingPathComponent("Papers.dmg.part.001"))

    let scratchBase = base.appendingPathComponent("scratch")
    let staged = scratchBase.appendingPathComponent("job-1/build/papers/Papers.dmg")
    try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 3, count: 300).write(to: staged)
    let otherStaged = scratchBase.appendingPathComponent("job-2/build/papers/Papers.zip")
    try FileManager.default.createDirectory(at: otherStaged.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 4, count: 10).write(to: otherStaged)

    let pending = PendingTransferStore(url: base.appendingPathComponent("pending.json"))
    pending.save(PendingTransfer(jobID: "job-1:nas:papers", sourceFile: staged.path, baseName: "Papers.dmg", totalBytes: 300,
                                 chunkSize: 100, targetDir: partial.path, format: .sealedDMG, encrypted: true,
                                 completed: [ArtifactDigest(name: "Papers.dmg.part.000", size: 100, sha256: ""),
                                             ArtifactDigest(name: "Papers.dmg.part.001", size: 100, sha256: "")]))
    pending.save(PendingTransfer(jobID: "job-2:nas:papers", sourceFile: otherStaged.path, baseName: "Papers.zip", totalBytes: 10,
                                 chunkSize: 100, targetDir: dest.appendingPathComponent("elsewhere").path, format: .sealedZip))
    let store = JobStore(url: base.appendingPathComponent("jobs.json"))
    store.upsert(job); store.upsert(other)
    store.recordRun(id: job.id, at: start); store.recordCopies(jobID: job.id, targetIDs: ["nas"], at: start)
    store.recordRun(id: other.id, at: start)
    return Setup(base: base, dest: dest, scratchBase: scratchBase, job: job, other: other, store: store, pending: pending,
                 locks: RunLocks(directory: base.appendingPathComponent("locks")))
}

private func plan(_ s: Setup) -> JobRemoval.Plan {
    JobRemoval.plan(for: s.job, pending: s.pending, scratchBase: s.scratchBase, volumes: FixedVolumeTable([]))
}

private func delete(_ s: Setup, expected: JobRemoval.Plan, queued: Bool = false) throws {
    try JobRemoval.delete(s.job, expected: expected, store: s.store, pending: s.pending, scratchBase: s.scratchBase,
                          locks: s.locks, isQueued: { queued }, volumes: FixedVolumeTable([]))
}

@Suite struct JobRemovalTests {
    @Test func thePlanSaysWhatStaysAndWhatIsLeftUnfinished() throws {
        let s = try setup("plan")
        let p = plan(s)
        #expect(p.places.count == 1)
        #expect(p.places[0].folders.map(\.lastPathComponent) == ["Papers"])
        #expect(p.unfinished.count == 1)
        #expect(p.unfinished.first?.bytesReached == 200 && p.unfinished.first?.totalBytes == 300)
        #expect(p.unfinished.first?.destination == "Backups on NAS")
        #expect(p.staged?.lastPathComponent == "job-1")
        #expect(p.encrypted)
    }

    @Test func deletingLeavesTheDestinationByteForByteAndOtherJobsAlone() throws {
        let s = try setup("delete")
        let before = tree(s.dest)
        try delete(s, expected: plan(s))
        #expect(tree(s.dest) == before)                                          // backups and parts stay
        let state = s.store.load()
        #expect(state.jobs.map(\.id) == ["job-2"])
        #expect(state.lastRun["job-1"] == nil && state.lastCopy["job-1"] == nil)
        #expect(state.lastRun["job-2"] == start)
        #expect(s.pending.all().map(\.jobID) == ["job-2:nas:papers"])
        #expect(!FileManager.default.fileExists(atPath: s.scratchBase.appendingPathComponent("job-1").path))
        #expect(FileManager.default.fileExists(atPath: s.scratchBase.appendingPathComponent("job-2/build/papers/Papers.zip").path))
    }

    @Test func aRunningJobIsNotDeleted() throws {
        let s = try setup("busy")
        let p = plan(s)
        let lease = try s.locks.acquire(jobID: s.job.id, trigger: .scheduled)
        defer { lease.release() }
        #expect(throws: JobRemoval.Refusal.busy(lease.holder)) { try delete(s, expected: p) }
        #expect(s.store.load().jobs.count == 2)
        #expect(s.pending.all().count == 2)
    }

    @Test func aTransferBeingFinishedCountsAsBusy() throws {
        let s = try setup("resume")
        let p = plan(s)
        #expect(!s.locks.isBusy(s.job.id))
        let lease = try s.locks.acquire(jobID: s.job.id, trigger: .resume)
        #expect(s.locks.isBusy(s.job.id))
        #expect(throws: JobRemoval.Refusal.busy(lease.holder)) { try delete(s, expected: p) }
        lease.release()
        #expect(!s.locks.isBusy(s.job.id))
        try delete(s, expected: p)
        #expect(s.store.load().jobs.map(\.id) == ["job-2"])
    }

    @Test func aJobWaitingToRunIsNotDeleted() throws {
        let s = try setup("queued")
        #expect(throws: JobRemoval.Refusal.queued) { try delete(s, expected: plan(s), queued: true) }
        #expect(s.store.load().jobs.count == 2)
    }

    @Test func whatChangedSinceItWasShownIsShownAgainNotDeleted() throws {
        let s = try setup("changed")
        let shown = plan(s)
        s.pending.remove(jobID: "job-1:nas:papers")                   // the upload finished meanwhile
        do {
            try delete(s, expected: shown)
            Issue.record("deleted what it no longer showed")
        } catch JobRemoval.Refusal.changed(let now) {
            #expect(now.unfinished.isEmpty)
            try delete(s, expected: now)
        }
        #expect(s.store.load().jobs.map(\.id) == ["job-2"])
    }

    @Test func theLockIsGivenBackEitherWay() throws {
        let s = try setup("release")
        #expect(throws: JobRemoval.Refusal.queued) { try delete(s, expected: plan(s), queued: true) }
        #expect(!s.locks.isBusy(s.job.id))
        try delete(s, expected: plan(s))
        #expect(!s.locks.isBusy(s.job.id))
    }

    @Test func anIDThatIsntOneFolderNameNeverReachesOutsideScratch() {
        let base = URL(fileURLWithPath: "/tmp/scratch")
        #expect(JobRemoval.stagedFolder("..", scratchBase: base) == nil)
        #expect(JobRemoval.stagedFolder("a/../..", scratchBase: base) == nil)
        #expect(JobRemoval.stagedFolder("", scratchBase: base) == nil)
        #expect(JobRemoval.stagedFolder("job-1", scratchBase: base)?.path == "/tmp/scratch/job-1")
    }
}
