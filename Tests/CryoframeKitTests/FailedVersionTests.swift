//
//  FailedVersionTests.swift
//  CryoframeKitTests
//
//  A sealed version that didn't pass a check is no backup, and nothing may count it as
//  one: a build that failed its mount-and-open check isn't copied out, so it never
//  becomes the newest version, is never counted by the Keep rule, and never pushes out
//  the good versions before it.
//

import Testing
import Foundation
@testable import CryoframeKit

private func tempDir(_ tag: String) -> URL {
    let d = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        .appendingPathComponent("cf-failedver-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

/// a small HFS+ volume to hold the library, mounted under `base`
private func sourceVolume(in base: URL) throws -> URL {
    let mnt = base.appendingPathComponent("vol")
    try FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)
    let dmg = base.appendingPathComponent("src.dmg")
    let made = try ProcessCommandRunner().run("/usr/bin/hdiutil", ["create", "-size", "20m", "-fs", "HFS+", "-volname", "Src", dmg.path])
    try #require(made.ok, "\(made.stderr)")
    let attached = try DiskImageGate.serialized {
        try ProcessCommandRunner().runRetryingBusy("/usr/bin/hdiutil", ["attach", dmg.path, "-mountpoint", mnt.path, "-nobrowse", "-owners", "on"])
    }
    try #require(attached.ok && MountPoint.isMounted(mnt), "\(attached.stderr)")
    return mnt
}

@Suite(.serialized) struct FailedVersionTests {

    @Test func aBuildThatFailsMountAndOpenIsNotKeptAndPushesOutNothing() async throws {
        let base = tempDir("verify")
        defer { try? FileManager.default.removeItem(at: base) }
        let mnt = try sourceVolume(in: base)
        defer { MountPoint.detach(mnt, runner: ProcessCommandRunner()) }
        let lib = mnt.appendingPathComponent("Notes")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        let db = lib.appendingPathComponent("main.db")
        let made = try ProcessCommandRunner().run("/usr/bin/sqlite3", [db.path, "create table t(x); insert into t values(1);"])
        try #require(made.ok, "\(made.stderr)")
        let dest = base.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let notes = ContentType(id: "notes", displayName: "Notes", paths: [.absolute(lib.path)], owningProcess: nil,
                                kind: .liveDB, integrityProbe: "main.db")
        let job = BackupJob(name: "Notes", libraries: [notes], target: .localVolume(id: "d", name: "Dest", dir: dest),
                            format: .sealedZip, frequency: .manual, verification: .mountAndOpen, retention: .keepLast(1),
                            createdAt: Date(timeIntervalSince1970: 0))
        let exec = JobExecutor(helper: FakePrivilegedHelper(), detector: FakeProcessDetector(),
                               scratchBase: base.appendingPathComponent("scratch"), volumes: FixedVolumeTable([]))
        let start = Date(timeIntervalSince1970: 1_790_000_000)

        let first = try await exec.run(job, ownerUID: getuid(), now: start)
        guard case .finished(let good, _) = first, case .completed(_, _, _, _, let verified)? = good.first else {
            Issue.record("\(first)"); return
        }
        #expect(verified == true)
        let folder = try #require(LibraryFolders.folders(job: job, library: notes, in: dest).first)
        let kept = LibraryFolders.versionNames(in: folder)
        #expect(kept.count == 1)

        // the library's database goes bad: its build fails quick_check
        try Data(repeating: 0x5A, count: 8192).write(to: db)
        for day in 1...2 {
            let outcome = try await exec.run(job, ownerUID: getuid(), now: start.addingTimeInterval(Double(day) * 86_400))
            guard case .finished(let results, _) = outcome else { Issue.record("\(outcome)"); return }
            #expect(results.count == 1)
            #expect(LibraryFolders.versionNames(in: folder) == kept, "day \(day): the good version was replaced")
            guard case .failed(_, _, let error)? = results.first else {
                Issue.record("a build that failed its check was reported as \(results)"); continue
            }
            #expect(error.contains("check"), "\(error)")
        }
    }
}
