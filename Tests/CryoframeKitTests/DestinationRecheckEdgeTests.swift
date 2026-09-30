//
//  DestinationRecheckEdgeTests.swift
//  CryoframeKitTests
//
//  The milestone 5a fixes at their edges: a destination set up before 1.6 now
//  takes another drive of its drive's name when it "holds this job's backups",
//  and a sealed library now pulls its versions out of any folder of its name. Both
//  judge whose backups are whose by a library's name and its archives' bundle
//  names, which another Mac's drive with the same name and library matches, and so
//  does a deleted job's folder. Also: whose check a version's result counts for
//  once it has moved, and the split of a shared 1.5 folder in either order.
//

import Testing
import Foundation
@testable import CryoframeKit

private let hdiutil = "/usr/bin/hdiutil"
private let day: TimeInterval = 86_400
private let start = Date(timeIntervalSince1970: 1_790_000_000)
private let v1 = "2026-09-01-020000", v2 = "2026-09-02-020000", v3 = "2026-09-03-020000"

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-drr-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

/// a stand-in archive: a sealed version folder, or a mirror at the folder's top
@discardableResult
private func archive(in dir: URL, bundle: String, mirror: Bool = false, version: String? = nil) throws -> URL {
    let at = version.map { dir.appendingPathComponent($0) } ?? dir
    try FileManager.default.createDirectory(at: at, withIntermediateDirectories: true)
    let result: ArchiveResult
    if mirror {
        let sb = at.appendingPathComponent(bundle + ".sparsebundle")
        try FileManager.default.createDirectory(at: sb.appendingPathComponent("bands"), withIntermediateDirectories: true)
        try Data("band".utf8).write(to: sb.appendingPathComponent("bands/0"))
        result = ArchiveResult(artifacts: [sb], format: .liveMirror)
    } else {
        let f = at.appendingPathComponent(bundle + ".zip")
        try Data("zip \(UUID())".utf8).write(to: f)
        result = ArchiveResult(artifacts: [f], format: .sealedZip)
    }
    _ = try ArchiveManifest.write(try ArchiveManifest.build(for: result), toDir: at)
    return at
}

private func names(_ dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
}

private func lib(_ id: String, _ name: String, root: String? = nil) -> ContentType {
    .genericFolder(id: id, displayName: name, path: .absolute("/Users/someone/\(root ?? name)"))
}

private func job(_ id: String, _ libs: [ContentType], dest: URL, mirror: Bool = false, keep: Int? = nil) -> BackupJob {
    var j = BackupJob(id: id, name: "Job \(id)", libraries: libs, target: .localVolume(id: "d", name: "Dest", dir: dest),
                      format: mirror ? .liveMirror(sizeGB: 1) : .sealedZip, frequency: .manual, createdAt: Date(timeIntervalSince1970: 0))
    if let keep { j.retention = .keepLast(keep) }
    return j
}

/// A small HFS+ volume attached at `mnt`, holding "Papers" with one file: a source
/// read as it is (HFS+ can't be frozen), so no snapshot is needed.
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

@Suite(.serialized) struct DestinationRecheckEdgeTests {

    // MARK: another drive of the destination's drive's name

    // A destination set up before 1.6, its drive learned by a run. A neighbor's drive
    // with the name every drive of its make comes with ("T7") is plugged in at the
    // same path, holding that Mac's own Cryoframe backups of a folder with the same
    // name: a 1.5 folder, or a 1.6 one with its own job's identity. It "holds this
    // job's backups" by name and bundle name, so it is taken as the other drive of a
    // 1.5 pair, recorded for good, and written to: the 1.5 folder is taken over, or
    // the 1.6 one's versions moved into this job's folder, and this job's retention
    // then deletes the neighbor's versions.
    @Test(arguments: ["1.5 folder", "another Mac's 1.6 folder"])
    func aNeighborsDriveOfTheSameNameIsNotTakenForTheOtherDriveOfAPair(_ layout: String) async throws {
        let base = folder("neighbor")
        let (mnt, papers) = try sourceVolume(in: base)
        defer { MountPoint.detach(mnt, runner: ProcessCommandRunner()); try? FileManager.default.removeItem(at: base) }
        let t7 = base.appendingPathComponent("T7"), dest = t7.appendingPathComponent("Backups")
        let theirs = dest.appendingPathComponent("Papers")
        try FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)
        if layout != "1.5 folder" {
            try LibraryIdentity(jobID: "NEIGHBORS-JOB", libraryID: "their-papers", name: "Papers", jobName: "Their papers").write(in: theirs)
        }
        for v in [v1, v2, v3] { try archive(in: theirs, bundle: "Papers", version: v) }

        let papersLib = ContentType.genericFolder(id: "papers", displayName: "Papers", path: .absolute(papers.path))
        var target = Target.externalDrive(id: "t7", name: "T7", dir: dest)
        target.volume = VolumeIdentity(uuid: "MY-T7", name: "T7", relativePath: "Backups", learnedAt: start)
        var mine = BackupJob(name: "Papers", libraries: [papersLib], target: target, format: .sealedZip,
                             frequency: .daily(hour: 2, minute: 0), createdAt: start)
        mine.retention = .keepLast(1)
        let store = JobStore(url: base.appendingPathComponent("jobs.json"))
        store.upsert(mine)
        store.recordRun(id: mine.id, at: start)
        let exec = JobExecutor(helper: FakePrivilegedHelper(), detector: FakeProcessDetector(),
                               scratchBase: base.appendingPathComponent("scratch"), jobStore: store,
                               volumes: FixedVolumeTable([MountedVolume(mountPoint: t7, uuid: "NEIGHBORS-T7", name: "T7",
                                                                        isInternal: false, isRemovable: true, isEjectable: true)]))
        _ = try? await exec.run(try #require(store.load().jobs.first), ownerUID: getuid(), now: start.addingTimeInterval(day))
        let left = [v1, v2, v3].filter { FileManager.default.fileExists(atPath: theirs.appendingPathComponent($0).path) }
        #expect(left == [v1, v2, v3], "\(layout): the neighbor's versions left in their folder: \(left); the drive holds \(names(dest))")
        #expect(store.load().jobs.first?.targets.first?.otherVolumes == nil, "the neighbor's drive was recorded as this destination's")
    }

    // MARK: a deleted job's backups

    // A job is deleted (its backups stay on the drive; its key goes with it), or no
    // longer writes to this destination. Changing a job's encryption means making a
    // new job, and the job editor refuses the new one while the old one still writes
    // the same library there. The new job's library has the old one's name, so its
    // first run moves the old job's versions out of the old job's own folder (its
    // identity says whose they are) into its own, where its retention deletes them
    // and its drills, with the new key, fail on them.
    @Test(arguments: ["deleted", "no longer writing here"])
    func anotherJobsFolderKeepsItsVersionsWhenThatJobIsntWritingHere(_ how: String) throws {
        let dest = folder("deleted"); defer { try? FileManager.default.removeItem(at: dest) }
        let other = folder("elsewhere"); defer { try? FileManager.default.removeItem(at: other) }
        let oldLib = lib("old-projects", "Projects", root: "Work/Projects")
        var old = job("old", [oldLib], dest: dest)
        let theirs = dest.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)
        try LibraryIdentity(job: old, library: oldLib).write(in: theirs)
        for v in [v1, v2] { try archive(in: theirs, bundle: "Projects", version: v) }
        var jobs: [BackupJob] = []
        if how != "deleted" { old.targets = [.localVolume(id: "e", name: "Elsewhere", dir: other)]; jobs.append(old) }

        let newLib = lib("new-projects", "Projects", root: "Home/Projects")
        let new = job("new", [newLib], dest: dest, keep: 1)
        jobs.append(new)
        let p = try LibraryFolders.prepare(job: new, library: newLib, in: dest, jobs: jobs, isOpen: { _ in false })
        #expect(p.folder.path != theirs.path)
        #expect(names(theirs) == [v1, v2], "\(how): the old job's versions were moved into \(p.folder.lastPathComponent): \(names(p.folder))")
        try archive(in: p.folder, bundle: "Projects", version: v3)
        JobExecutor.pruneVersions(folders: JobExecutor.prunable(new, ["d": [newLib.id: p.folder]]), policy: new.retention)
        let survivors = [v1, v2].filter { FileManager.default.fileExists(atPath: theirs.appendingPathComponent($0).path)
                                            || FileManager.default.fileExists(atPath: p.folder.appendingPathComponent($0).path) }
        #expect(survivors == [v1, v2], "\(how): the new job's retention deleted the old job's versions")
    }

    // MARK: whose check a moved version's result is

    // A return to 1.5.6 wrote a sealed job's version into a mirror job's folder. The
    // sealed job reads it there (it's its own by name and bundle) and drills it: the
    // result is recorded under the key of the folder it sat in, the mirror job's.
    // The next run moves it home, where that result no longer counts for it, so the
    // one version that restored is no longer kept by retention.
    @Test func aVersionsDrillResultStillCountsAfterItMovesHome() throws {
        let dest = folder("drift"); defer { try? FileManager.default.removeItem(at: dest) }
        let notes = lib("q", "Notes")
        let mirror = job("m", [notes], dest: dest, mirror: true), sealed = job("s", [notes], dest: dest, keep: 1)
        let all = [mirror, sealed]
        let m = try LibraryFolders.prepare(job: mirror, library: notes, in: dest, jobs: all, isOpen: { _ in false }).folder
        try archive(in: m, bundle: "Notes", mirror: true)
        let s = try LibraryFolders.prepare(job: sealed, library: notes, in: dest, jobs: all, isOpen: { _ in false }).folder
        try archive(in: s, bundle: "Notes", version: v1)
        try archive(in: m, bundle: "Notes", version: v2)            // 1.5.6 wrote it into the mirror job's folder
        try archive(in: s, bundle: "Notes", version: v3)
        // the sealed job's drill, as it reads its archives
        let seen = LibraryFolders.archives(job: sealed, library: notes, in: dest)
        let atV2 = try #require(seen.first { $0.version == VersionStamp.date(v2) }, "\(seen.map(\.dir.path))")
        let date = { (x: String) in VersionStamp.date(x)! }
        let drill = HealthRecord(jobID: sealed.id, jobName: sealed.name, checkedAt: date(v3).addingTimeInterval(3600), archivesChecked: 3,
                                 failures: ["Notes: didn't reopen", "Notes: didn't reopen"], kind: "drill",
                                 verified: [VerifiedArchive(library: "Notes", version: date(v3), passed: false, key: "s/q"),
                                            VerifiedArchive(library: "Notes", version: date(v1), passed: false, key: "s/q"),
                                            VerifiedArchive(library: atV2.libraryName, version: date(v2), passed: true, key: atV2.libraryKey)])
        _ = try LibraryFolders.prepare(job: sealed, library: notes, in: dest, jobs: all, isOpen: { _ in false })
        #expect(names(s) == [v1, v2, v3], "v2 moved home")
        JobExecutor.pruneVersions(folders: [(notes, s)], policy: .keepLast(1), checks: [drill])
        #expect(names(s).contains(v2), "the one version that restored was deleted (its check was recorded as \(atV2.libraryKey ?? "nil")'s): \(names(s))")
    }

    // MARK: a shared 1.5 folder, in either order

    // Pinned: whichever job takes the shared folder over first, the sealed versions
    // end in the sealed job's folder, the mirror job reads only its mirror, and a
    // latest-only check of the mirror job checks the mirror.
    @Test(arguments: ["mirror first", "sealed first", "mirror, then sealed twice"])
    func aSharedFolderSplitsTheSameWhicheverJobRunsFirst(_ order: String) throws {
        let dest = folder("order"); defer { try? FileManager.default.removeItem(at: dest) }
        let photos = ContentType.genericFolder(id: "com.apple.photos", displayName: "Photos",
                                               path: .absolute("/Users/someone/Pictures/Photos Library.photoslibrary"))
        let legacy = dest.appendingPathComponent("Photos")
        try archive(in: legacy, bundle: "Photos Library.photoslibrary", mirror: true)
        for v in [v1, v2] { try archive(in: legacy, bundle: "Photos Library.photoslibrary", version: v) }
        let mirror = job("m", [photos], dest: dest, mirror: true), sealed = job("s", [photos], dest: dest)
        let all = [mirror, sealed]
        let runs: [BackupJob] = order == "mirror first" ? [mirror, sealed] : order == "sealed first" ? [sealed, mirror] : [mirror, sealed, sealed]
        var folders: [String: URL] = [:]
        for j in runs { folders[j.id] = try LibraryFolders.prepare(job: j, library: photos, in: dest, jobs: all, isOpen: { _ in false }).folder }
        let s = try #require(folders["s"]), m = try #require(folders["m"])
        #expect(names(s) == [v1, v2], "\(order): \(names(s)) / \(names(m))")
        #expect(m.path == legacy.path && names(m) == ["Photos Library.photoslibrary.sparsebundle", "cryoframe-manifest.json"])
        #expect(LibraryFolders.archives(job: mirror, library: photos, in: dest).map(\.version) == [nil])
        #expect(LibraryFolders.archives(job: sealed, library: photos, in: dest).compactMap(\.version).count == 2)
        let checked = HealthChecker(volumes: FixedVolumeTable([])).check(job: mirror, latestOnly: true).checks
        #expect(checked.map(\.version) == [nil], "\(order): \(checked.map(\.version))")
    }
}
