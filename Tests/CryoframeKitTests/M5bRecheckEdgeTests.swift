//
//  M5bRecheckEdgeTests.swift
//  CryoframeKitTests
//
//  Independent QA of the M5b fix round: what the person is shown before the next
//  backup takes over a 1.5 folder, against what that backup then deletes. Each test
//  states what should hold; where the build doesn't, the test fails until it does.
//

import Testing
import Foundation
@testable import CryoframeKit

private let start = Date(timeIntervalSince1970: 1_790_000_000)
private let day: TimeInterval = 86_400

private func scratch(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-m5bre-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return TempTracker.track(d) }
    defer { free(real) }
    return TempTracker.track(URL(fileURLWithPath: String(cString: real), isDirectory: true))
}

private let papers = ContentType.genericFolder(id: "papers", displayName: "Papers", path: .absolute("/Users/me/Papers"))

private func job(_ dests: [URL], id: String = "job-1", format: FormatChoice = .sealedZip,
                 retention: RetentionPolicy = .keepLast(2)) -> BackupJob {
    BackupJob(id: id, name: "Papers", libraries: [papers],
              targets: dests.map { Target.localVolume(id: $0.path, name: $0.lastPathComponent, dir: $0) },
              format: format, frequency: .manual, retention: retention, createdAt: start)
}

/// a dated version of Papers, as 1.5 and 1.6 write one
private func version(in dir: URL, _ date: Date) throws {
    let at = dir.appendingPathComponent(VersionStamp.string(date))
    try FileManager.default.createDirectory(at: at, withIntermediateDirectories: true)
    let f = at.appendingPathComponent("Papers.zip")
    try Data("zip \(date)".utf8).write(to: f)
    _ = try ArchiveManifest.write(try ArchiveManifest.build(for: ArchiveResult(artifacts: [f], format: .sealedZip)), toDir: at)
}

/// the folder 1.5 wrote at `dest` (`<dest>/Papers`, no identity file), holding `n` dated versions
private func legacyFolder(in dest: URL, versions n: Int) throws -> URL {
    let legacy = dest.appendingPathComponent("Papers", isDirectory: true)
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    for d in 0..<n { try version(in: legacy, start.addingTimeInterval(Double(d) * day)) }
    return legacy
}

/// what the next backup does at `dest`: get the folder ready (take the 1.5 one over),
/// add its version, prune by the Keep rule. How many versions it deleted.
private func nextBackup(_ j: BackupJob, at dest: URL, jobs: [BackupJob], now: Date) throws -> (folder: URL, deleted: Int) {
    let folder = try LibraryFolders.prepare(job: j, library: papers, in: dest, jobs: jobs, isOpen: { _ in false }).folder
    try version(in: folder, now)
    let before = LibraryFolders.versionNames(in: folder).count
    JobExecutor.pruneVersions(folders: [(papers, folder)], policy: j.retention, confirmed: { _, _ in true })
    return (folder, before - LibraryFolders.versionNames(in: folder).count)
}

@Suite struct M5bRecheckEdgeTests {
    // A new job saved over a folder 1.5 wrote: the summary says it "creates" a folder,
    // counts nothing, and the first backup takes the 1.5 folder over and deletes 3 of
    // its 4 versions. The same class as the rename blocker: a Keep rule deleting dated
    // versions no one was shown.
    @Test func aNewJobOverA15FolderIsToldWhatItsFirstBackupDeletes() throws {
        let dest = scratch("new")
        let legacy = try legacyFolder(in: dest, versions: 4)
        let draft = job([dest])
        let now = start.addingTimeInterval(10 * day)
        let impact = JobEditImpact.of(draft: draft, base: nil, volumes: FixedVolumeTable([]), now: now)

        let run = try nextBackup(draft, at: dest, jobs: [draft], now: now)
        #expect(run.folder.path == legacy.path)                                  // taken over, as 1.6 does
        #expect(run.deleted == 3)
        #expect(impact.deletes == run.deleted)
        #expect(impact.lines.contains { $0.kind == .deletes })
    }

    // The same, for a destination added by hand to a job that already has one.
    @Test func aDestinationAddedByHandOverA15FolderIsToldWhatItsNextBackupDeletes() throws {
        let home = scratch("home"), added = scratch("added")
        _ = try LibraryFolders.prepare(job: job([home]), library: papers, in: home, jobs: [job([home])], isOpen: { _ in false })
        let legacy = try legacyFolder(in: added, versions: 5)
        let base = job([home])
        let draft = job([home, added])
        let now = start.addingTimeInterval(10 * day)
        let impact = JobEditImpact.of(draft: draft, base: base, volumes: FixedVolumeTable([]), now: now)

        let run = try nextBackup(draft, at: added, jobs: [draft], now: now)
        #expect(run.folder.path == legacy.path)
        #expect(run.deleted == 4)
        #expect(impact.deletes == run.deleted)
        #expect(!impact.lines.contains { $0.kind == .creates && $0.text.contains("creates") && $0.text.contains(added.path) })
    }

    // "Is this one of your drives?" (and so a rename's look): the job's 1.5 versions sit
    // in the folder a mirror job of this Mac took over on that drive (1.5 wrote both
    // jobs' backups into one "Papers"). The look finds no folder of its own and says
    // the next backup only makes one. That backup moves the versions into it and its
    // Keep rule deletes them.
    @Test func versionsInAMirrorJobsFolderAreCountedBeforeTheyArePruned() throws {
        let t7 = scratch("shared"), dest = t7.appendingPathComponent("Backups")
        let shared = dest.appendingPathComponent("Papers", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        for d in 0..<4 { try version(in: shared, start.addingTimeInterval(Double(d) * day)) }
        var mirror = job([dest], id: "mirror-job", format: .liveMirror(sizeGB: 1), retention: .keepAll)
        mirror.targets[0].volume = VolumeIdentity(uuid: "DRIVE-B", name: "T7", relativePath: "Backups")
        try LibraryIdentity(job: mirror, library: papers).write(in: shared)          // it took the 1.5 folder over

        var t = Target.externalDrive(id: "t7", name: "Backups on T7", dir: dest)
        t.volume = VolumeIdentity(uuid: "DRIVE-A", name: "T7", relativePath: "Backups", learnedAt: start)
        let sealed = BackupJob(id: "job-1", name: "Papers", libraries: [papers], target: t, format: .sealedZip,
                               frequency: .manual, retention: .keepLast(2), createdAt: start)
        let now = start.addingTimeInterval(10 * day)
        let b = MountedVolume(mountPoint: t7, uuid: "DRIVE-B", name: "T7", isInternal: false, isRemovable: true, isEjectable: true)
        let look = try #require(DrivePairing.look(t, job: sealed, jobs: [sealed, mirror], volumes: FixedVolumeTable([b]), now: now))
        #expect(look.refusal == nil)                                             // the mirror job knows drive B
        let shown = look.libraries.reduce(0) { $0 + $1.deletes }

        let run = try nextBackup(sealed, at: dest, jobs: [sealed, mirror], now: now)
        #expect(run.deleted == 3)
        #expect(shown == run.deleted)
        #expect(look.changesBackups)                                             // so a rename needs it confirmed
    }

    // A re-send reads the staged archive again. A later run of the job empties its
    // build folder and builds the next archive under the same name (JobExecutor, the
    // build dir is <job>/build/<library>), so an interrupted upload to a destination
    // that run didn't reach can resume from a different archive. Parts of the old one
    // and of the new one then pass the size checks and are marked complete: a version
    // that can't be put back together.
    @Test func aResumeWhoseArchiveWasRebuiltIsNeverMarkedCompleteAsAMix() throws {
        let work = scratch("rebuilt"), dest = scratch("rebuilt-dest")
        let source = work.appendingPathComponent("Papers.dmg")
        let old = Data((0..<5_000_000).map { _ in UInt8.random(in: 0...255) })
        try old.write(to: source)
        let pending = PendingTransfer(jobID: "job-1:t7:papers", sourceFile: source.path, baseName: "Papers.dmg",
                                      totalBytes: 5_000_000, chunkSize: 2_000_000, targetDir: dest.path, format: .sealedDMG)
        let full = try ChunkedShipper().ship(pending, persist: { _ in })
        // interrupted after the first part
        try FileManager.default.removeItem(at: dest.appendingPathComponent(ArchiveManifest.sidecarName))
        for a in full.artifacts.dropFirst() { try FileManager.default.removeItem(at: dest.appendingPathComponent(a.name)) }
        var resumed = pending
        resumed.completed = Array(full.artifacts.prefix(1))
        // the next run's archive, a little larger, at the same path
        let new = Data((0..<5_500_000).map { _ in UInt8.random(in: 0...255) })
        try new.write(to: source)

        let m = try? ChunkedShipper().ship(resumed, persist: { _ in })
        if let m {
            var whole = Data()
            for a in m.artifacts { whole.append(try Data(contentsOf: dest.appendingPathComponent(a.name))) }
            #expect(whole == old || whole == new)
        }
    }
}
