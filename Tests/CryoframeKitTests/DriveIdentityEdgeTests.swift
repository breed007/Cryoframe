//
//  DriveIdentityEdgeTests.swift
//  CryoframeKitTests
//
//  Drives known by their volume at the edges: a 1.5 job that took turns between
//  two drives of one name (the only way to rotate before 1.6), a folder to back up
//  on a different drive of its drive's name, a rotating drive that was erased, two
//  rotating drives with the name they came with, and a folder left at a drive's
//  path on the startup disk.
//

import Testing
import Foundation
@testable import CryoframeKit

private let hdiutil = "/usr/bin/hdiutil"
private let day: TimeInterval = 86_400
private let start = Date(timeIntervalSince1970: 1_790_000_000)

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-drive-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

/// A small HFS+ volume attached at `mnt`, holding a folder "Papers" with one file:
/// a source the run reads as it is (HFS+ can't be frozen), so no snapshot is needed.
private func sourceVolume(in base: URL) throws -> (mnt: URL, papers: URL) {
    let mnt = base.appendingPathComponent("vol")
    try FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)
    let dmg = base.appendingPathComponent("src.dmg")
    let made = try ProcessCommandRunner().run(hdiutil, ["create", "-size", "20m", "-fs", "HFS+", "-volname", "Src", dmg.path])
    try #require(made.ok, "\(made.stderr)")
    let attached = try DiskImageGate.serialized {
        try ProcessCommandRunner().runRetryingBusy(hdiutil, ["attach", dmg.path, "-mountpoint", mnt.path, "-nobrowse", "-owners", "on"])
    }
    try #require(attached.ok && MountPoint.isMounted(mnt), "\(attached.stderr)")
    let papers = mnt.appendingPathComponent("Papers")
    try FileManager.default.createDirectory(at: papers, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: papers.appendingPathComponent("a.txt"))
    return (mnt, papers)
}

private func drive(_ mount: URL, uuid: String, name: String) -> MountedVolume {
    MountedVolume(mountPoint: mount, uuid: uuid, name: name, isInternal: false, isRemovable: true, isEjectable: true)
}

private func completed(_ outcome: JobOutcome) -> [LibraryRunResult] {
    guard case .finished(let results, _) = outcome else { return [] }
    return results.filter { if case .completed = $0 { return true }; return false }
}

@Suite(.serialized) struct DriveIdentityEdgeTests {

    // MARK: the upgrade from 1.5

    // Before 1.6 the only way to take turns between two drives was two drives of one
    // name at one path; the README says to rotate a drive for an off-site copy. The
    // first 1.6 run records the volume of whichever drive is connected (its folder
    // holds the job's library folder, so it's "known"), and from then on the other
    // one is "a different drive", refused, and the run fails every week it's the
    // one at home. Nothing in the job editor makes a rotation yet.
    @Test func a15JobThatTookTurnsBetweenTwoDrivesOfOneNameKeepsBackingUpToBoth() async throws {
        let base = folder("upgrade")
        let (mnt, papers) = try sourceVolume(in: base)
        defer { MountPoint.detach(mnt, runner: ProcessCommandRunner()); try? FileManager.default.removeItem(at: base) }
        let t7 = base.appendingPathComponent("T7"), dest = t7.appendingPathComponent("Backups")
        // what 1.5 left on both drives: a folder named by the library, with a version
        let lib = ContentType.genericFolder(id: "papers", displayName: "Papers", path: .absolute(papers.path))
        let v = dest.appendingPathComponent("Papers/2026-09-01-020000")
        try FileManager.default.createDirectory(at: v, withIntermediateDirectories: true)
        try Data("zip".utf8).write(to: v.appendingPathComponent("Papers.zip"))
        _ = try ArchiveManifest.write(try ArchiveManifest.build(for: ArchiveResult(artifacts: [v.appendingPathComponent("Papers.zip")],
                                                                                   format: .sealedZip)), toDir: v)
        let job = BackupJob(name: "Papers", libraries: [lib], target: .externalDrive(id: "t7", name: "T7", dir: dest),
                            format: .sealedZip, frequency: .daily(hour: 2, minute: 0), createdAt: start)
        let store = JobStore(url: base.appendingPathComponent("jobs.json"))
        store.upsert(job)
        store.recordRun(id: job.id, at: start)                 // it ran under 1.5
        func executor(_ uuid: String) -> JobExecutor {
            JobExecutor(helper: FakePrivilegedHelper(), detector: FakeProcessDetector(), scratchBase: base.appendingPathComponent("scratch"),
                        jobStore: store, volumes: FixedVolumeTable([drive(t7, uuid: uuid, name: "T7")]))
        }
        let week1 = try await executor("DRIVE-A").run(try #require(store.load().jobs.first), ownerUID: getuid(), now: start.addingTimeInterval(day))
        #expect(completed(week1).count == 1, "\(week1)")
        #expect(store.load().jobs.first?.targets.first?.volume?.uuid == "DRIVE-A")
        // the next week, the other drive is at home
        do {
            let week2 = try await executor("DRIVE-B").run(try #require(store.load().jobs.first), ownerUID: getuid(), now: start.addingTimeInterval(8 * day))
            #expect(completed(week2).count == 1, "\(week2)")
        } catch {
            Issue.record("the drive that took its turn under 1.5 is refused after the upgrade: \(error)")
        }
    }

    // MARK: a folder to back up, on another drive of its drive's name

    // A destination on a different drive of its drive's name is never written to.
    // A folder to back up is found by its path first, and only looked for by its
    // volume when the path is gone, so on a different drive of the same name at the
    // same place it is backed up as if it were the library. A mirror is made to match
    // it; a sealed job's retention ages the real versions out behind it. That is the
    // week the real drive died and its replacement took its name.
    @Test func aFolderOnAnotherDriveOfItsDrivesNameIsNotBackedUp() async throws {
        let base = folder("impostor")
        let (mnt, papers) = try sourceVolume(in: base)
        defer { MountPoint.detach(mnt, runner: ProcessCommandRunner()); try? FileManager.default.removeItem(at: base) }
        var lib = ContentType.genericFolder(id: "papers", displayName: "Papers", path: .absolute(papers.path))
        lib.volume = VolumeIdentity(uuid: "THE-REAL-T7", name: "T7", relativePath: "Papers")
        let dest = base.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let job = BackupJob(name: "Papers", libraries: [lib], target: .localVolume(id: "d", name: "Dest", dir: dest),
                            format: .sealedZip, frequency: .manual, createdAt: start)
        let exec = JobExecutor(helper: FakePrivilegedHelper(), detector: FakeProcessDetector(),
                               scratchBase: base.appendingPathComponent("scratch"),
                               volumes: FixedVolumeTable([drive(mnt, uuid: "A-NEW-T7", name: "T7")]))
        let outcome = try? await exec.run(job, ownerUID: getuid(), now: start)
        #expect(outcome.map(completed)?.isEmpty ?? true, "backed up another drive's folder as the library: \(String(describing: outcome))")
        #expect(RestoreDiscovery.scan(dest).isEmpty)
    }

    // MARK: rotations

    // A rotating drive that was erased (a new volume UUID) under its old name, the
    // other drive away. The run can't write anywhere and says neither drive is
    // connected, while the one on the desk is plugged in: why it isn't used is lost.
    @Test func anErasedRotatingDriveIsNamedAsADifferentDrive() async throws {
        let base = folder("erased"); defer { try? FileManager.default.removeItem(at: base) }
        let dirA = base.appendingPathComponent("A"), dirB = base.appendingPathComponent("B")
        for d in [dirA, dirB] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        func member(_ id: String, _ name: String, _ dir: URL) -> Target {
            var t = Target.externalDrive(id: id, name: name, dir: dir)
            t.volume = VolumeIdentity(uuid: "UUID-\(id)", name: name, relativePath: "")
            t.rotation = Rotation(group: "offsite", addedAt: start)
            return t
        }
        let lib = ContentType.genericFolder(id: "papers", displayName: "Papers", path: .absolute(base.path))
        let job = BackupJob(name: "Papers", libraries: [lib], targets: [member("a", "T7 A", dirA), member("b", "T7 B", dirB)],
                            format: .sealedZip, frequency: .manual, createdAt: start)
        let exec = JobExecutor(helper: FakePrivilegedHelper(), detector: FakeProcessDetector(),
                               scratchBase: base.appendingPathComponent("scratch"),
                               volumes: FixedVolumeTable([drive(dirA, uuid: "ERASED-NEW-UUID", name: "T7 A")]))
        do {
            _ = try await exec.run(job, ownerUID: getuid(), now: start)
            Issue.record("wrote to an erased drive")
        } catch let TargetError.unavailable(why) {
            #expect(why.contains("different drive"), "\(why)")
        }
        #expect((try FileManager.default.contentsOfDirectory(atPath: dirA.path)).isEmpty)
    }

    // Two drives bought together carry the name they came with ("T7"), and both are
    // plugged in once to set up the rotation, the second mounting as "T7 1". Their
    // destinations are named alike, so "hasn't had a copy on … in 19 days" can't say
    // which drive to bring home.
    @Test func twoRotatingDrivesOfOneNameAreToldApart() {
        let table = FixedVolumeTable([drive(URL(fileURLWithPath: "/Volumes/T7"), uuid: "A", name: "T7"),
                                      drive(URL(fileURLWithPath: "/Volumes/T7 1"), uuid: "B", name: "T7")])
        let resolver = DestinationResolver(volumes: table)
        var a = resolver.target(for: URL(fileURLWithPath: "/Volumes/T7/Backups"), home: "/Users/nobody")
        var b = resolver.target(for: URL(fileURLWithPath: "/Volumes/T7 1/Backups"), home: "/Users/nobody")
        #expect(a.volume?.uuid == "A" && b.volume?.uuid == "B")
        a.rotation = Rotation(group: "g", addedAt: start); b.rotation = Rotation(group: "g", addedAt: start)
        let job = BackupJob(name: "J", libraries: [.photos], targets: [a, b], format: .sealedDMG,
                            frequency: .daily(hour: 2, minute: 0), createdAt: start)
        let away = RotationRules.awayTooLong(job, lastCopies: [a.id: start.addingTimeInterval(19 * day)], now: start.addingTimeInterval(20 * day))
        #expect(away.count == 1)
        #expect(away.first?.name != a.displayName, "the drive gone too long is named like the one at home: \(a.displayName) / \(b.displayName)")
    }

    // MARK: where a destination is

    // A drive's folder left on the startup disk at its old path (the drive came off
    // without being ejected, and something wrote there): not the drive.
    @Test func aFolderLeftAtADrivesPathOnTheStartupDiskIsNotTheDrive() throws {
        let base = folder("leftover"); defer { try? FileManager.default.removeItem(at: base) }
        let dest = base.appendingPathComponent("T7/Backups")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        var t = Target.externalDrive(id: "t7", name: "Backups on T7", dir: dest)
        t.volume = VolumeIdentity(uuid: "T7-UUID", name: "T7", relativePath: "Backups")
        let startup = MountedVolume(mountPoint: URL(fileURLWithPath: "/"), uuid: "DATA", name: "Macintosh HD", isRoot: true)
        #expect(!DestinationResolver(volumes: FixedVolumeTable([startup])).locate(t).isPresent)
        // and with the drive back under a new name, it is found where it mounted
        let renamed = base.appendingPathComponent("T7 Backup")
        try FileManager.default.createDirectory(at: renamed.appendingPathComponent("Backups"), withIntermediateDirectories: true)
        let back = DestinationResolver(volumes: FixedVolumeTable([startup, drive(renamed, uuid: "T7-UUID", name: "T7 Backup")])).locate(t)
        #expect(back.url?.path == renamed.appendingPathComponent("Backups").path)
    }
}
