//
//  LibraryFolderEdgeTests.swift
//  CryoframeKitTests
//
//  Library folders at their edges: a 1.5 folder a mirror job and a sealed job
//  shared, taken over in the other order; a return to 1.5.6 when the plain folder
//  is another job's; a folder holding only a mirror and claimed by a sealed job; a
//  move that died half way; versions moved while one of them is open; a folder two
//  sealed jobs shared, under retention; and the version retention keeps as the last
//  known good, after the library is renamed.
//

import Testing
import Foundation
@testable import CryoframeKit

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-libfe-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

/// a stand-in archive (no disk image tools): a sealed version folder, or a mirror at
/// the folder's top, each with its manifest
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

private func lib(_ id: String, _ name: String, root: String? = nil) -> ContentType {
    .genericFolder(id: id, displayName: name, path: .absolute("/Users/someone/\(root ?? name)"))
}

private func job(_ id: String, _ libs: [ContentType], dest: URL, mirror: Bool = false) -> BackupJob {
    BackupJob(id: id, name: "Job \(id)", libraries: libs, target: .localVolume(id: "d", name: "Dest", dir: dest),
              format: mirror ? .liveMirror(sizeGB: 1) : .sealedZip, frequency: .manual, createdAt: Date(timeIntervalSince1970: 0))
}

private let v1 = "2026-09-01-020000", v2 = "2026-09-02-020000", v3 = "2026-09-03-020000"
private func names(_ dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
}
private func versions(_ archives: [RestorableArchive]) -> [String] {
    archives.map { $0.version.map(VersionStamp.string) ?? "mirror" }.sorted()
}

@Suite struct LibraryFolderEdgeTests {

    // MARK: a folder a mirror job and a sealed job shared

    // The developer's test takes the sealed job first. The jobs run in whatever
    // order their schedules say. Taken over by the mirror job first, the folder has an
    // identity, so the sealed job no longer sees it as a 1.5 folder: its versions
    // stay in the mirror job's folder, out of its own retention, checks and storage,
    // and the mirror job's checks take them for its own. A latest-only check picks
    // the newest of them and never checks the mirror.
    @Test func aSharedFolderTheMirrorJobTakesOverFirstStillGivesUpTheSealedVersions() throws {
        let dest = folder("mfirst"); defer { try? FileManager.default.removeItem(at: dest) }
        let photos = lib("com.apple.photos", "Photos", root: "Pictures/Photos Library.photoslibrary")
        let legacy = dest.appendingPathComponent("Photos")
        try archive(in: legacy, bundle: "Photos Library.photoslibrary", mirror: true)
        try archive(in: legacy, bundle: "Photos Library.photoslibrary", version: v1)
        try archive(in: legacy, bundle: "Photos Library.photoslibrary", version: v2)
        let mirror = job("m", [photos], dest: dest, mirror: true), sealed = job("s", [photos], dest: dest)
        let all = [mirror, sealed]
        let m = try LibraryFolders.prepare(job: mirror, library: photos, in: dest, jobs: all, isOpen: { _ in false })
        #expect(m.folder.path == legacy.path)
        let s = try LibraryFolders.prepare(job: sealed, library: photos, in: dest, jobs: all, isOpen: { _ in false })
        #expect(s.folder.path != legacy.path)
        #expect(names(s.folder) == [v1, v2], "the sealed job's versions stayed in the mirror job's folder: \(names(legacy))")
        #expect(versions(LibraryFolders.archives(job: sealed, library: photos, in: dest)) == [v1, v2])
        #expect(versions(LibraryFolders.archives(job: mirror, library: photos, in: dest)) == ["mirror"],
                "the mirror job counts another job's versions as its own")
        let checked = HealthChecker(volumes: FixedVolumeTable([])).check(job: mirror, latestOnly: true).checks
        #expect(checked.contains { $0.version == nil }, "the mirror job's check never looks at its mirror: \(checked.map(\.version))")
    }

    // MARK: a return to 1.5.6 when the plain folder is another job's

    // A mirror job and a sealed job of one library at one destination (1.5.6 allows
    // it: their files don't overlap). The mirror job's folder took the plain name,
    // so the sealed job's is suffixed. Back on 1.5.6, the sealed job writes into the
    // plain folder, the mirror job's. Back on 1.6 that folder has an identity, so it
    // isn't a 1.5 folder, and those versions never come back.
    @Test func versionsWrittenOnReturnIntoAnotherJobsFolderComeBack() throws {
        let dest = folder("return-other"); defer { try? FileManager.default.removeItem(at: dest) }
        let notes = lib("q", "Notes")
        let mirror = job("m", [notes], dest: dest, mirror: true), sealed = job("s", [notes], dest: dest)
        let all = [mirror, sealed]
        let m = try LibraryFolders.prepare(job: mirror, library: notes, in: dest, jobs: all, isOpen: { _ in false }).folder
        try archive(in: m, bundle: "Notes", mirror: true)
        let s = try LibraryFolders.prepare(job: sealed, library: notes, in: dest, jobs: all, isOpen: { _ in false }).folder
        try archive(in: s, bundle: "Notes", version: v1)
        #expect(m.lastPathComponent == "Notes" && s.lastPathComponent != "Notes")
        try archive(in: m, bundle: "Notes", version: v2)            // what 1.5.6 wrote for the sealed job
        let back = try LibraryFolders.prepare(job: sealed, library: notes, in: dest, jobs: all, isOpen: { _ in false })
        #expect(back.folder.path == s.path)
        #expect(names(s) == [v1, v2], "1.5.6's version stayed in the mirror job's folder: \(names(m))")
        #expect(versions(LibraryFolders.archives(job: sealed, library: notes, in: dest)) == [v1, v2])
        #expect(versions(LibraryFolders.archives(job: mirror, library: notes, in: dest)) == ["mirror"])
    }

    // The other way round: the sealed job's folder has the plain name, and 1.5.6 makes
    // the mirror job a fresh full mirror in it. The note that an earlier copy stays,
    // no longer updated, is given only when the plain folder has no identity.
    @Test func aMirrorWrittenOnReturnIntoAnotherJobsFolderIsSaidSo() throws {
        let dest = folder("return-mirror"); defer { try? FileManager.default.removeItem(at: dest) }
        let notes = lib("q", "Notes")
        let mirror = job("m", [notes], dest: dest, mirror: true), sealed = job("s", [notes], dest: dest)
        let all = [mirror, sealed]
        let s = try LibraryFolders.prepare(job: sealed, library: notes, in: dest, jobs: all, isOpen: { _ in false }).folder
        try archive(in: s, bundle: "Notes", version: v1)
        let m = try LibraryFolders.prepare(job: mirror, library: notes, in: dest, jobs: all, isOpen: { _ in false }).folder
        try archive(in: m, bundle: "Notes", mirror: true)
        #expect(s.lastPathComponent == "Notes" && m.lastPathComponent != "Notes")
        try archive(in: s, bundle: "Notes", mirror: true)           // 1.5.6's fresh mirror, in the sealed job's folder
        let back = try LibraryFolders.prepare(job: mirror, library: notes, in: dest, jobs: all, isOpen: { _ in false })
        #expect(back.notes.contains { $0.contains("earlier copy of Notes") }, "no word of the copy 1.5.6 made: \(back.notes)")
    }

    // MARK: a folder holding only a mirror

    // A 1.5 mirror job's folder, and now only a sealed job of that library writes
    // there (the mirror job was deleted, or made anew as sealed). A mirror folder is
    // to be taken over only by a mirror job; the sealed job takes it, with the old
    // full copy inside, and nothing says it is there.
    @Test func aSealedJobDoesNotTakeOverAFolderHoldingOnlyAMirror() throws {
        let dest = folder("mirror-only"); defer { try? FileManager.default.removeItem(at: dest) }
        let photos = lib("com.apple.photos", "Photos", root: "Pictures/Photos Library.photoslibrary")
        let legacy = dest.appendingPathComponent("Photos")
        try archive(in: legacy, bundle: "Photos Library.photoslibrary", mirror: true)
        let sealed = job("s", [photos], dest: dest)
        let p = try LibraryFolders.prepare(job: sealed, library: photos, in: dest, jobs: [sealed], isOpen: { _ in false })
        #expect(p.folder.path != legacy.path, "a sealed job took over a mirror's folder")
        #expect(p.notes.contains { $0.contains("earlier copy of Photos") }, "\(p.notes)")
    }

    // MARK: 1.5 folders named as 1.6 wouldn't name them

    // 1.5 named a library's folder by its name exactly. A folder named "Taxes 2024/25"
    // in Finder is "Taxes 2024:25" to the file system, and one can start with a dot.
    // 1.6 makes such names safe ("-" for ":", no leading dot) and takes the 1.5 folder
    // over in place, then renames it to the safe name straight away: the folder a
    // return to 1.5.6 looks for is gone, and 1.5.6 starts over (a whole new mirror).
    @Test(arguments: ["Taxes 2024:25", ".config"])
    func a15FolderWhoseNameIsntSafeIsStillTakenOverInPlace(_ name: String) throws {
        let dest = folder("unsafe"); defer { try? FileManager.default.removeItem(at: dest) }
        let taxes = lib("t", name)
        let legacy = dest.appendingPathComponent(name)
        try archive(in: legacy, bundle: name, mirror: true)
        let j = job("a", [taxes], dest: dest, mirror: true)
        let p = try LibraryFolders.prepare(job: j, library: taxes, in: dest, jobs: [j], isOpen: { _ in false })
        #expect(p.folder.path == legacy.path, "the 1.5 folder was renamed to \(p.folder.lastPathComponent)")
        #expect(FileManager.default.fileExists(atPath: legacy.path), "a return to 1.5.6 won't find it: \(names(dest))")
    }

    // MARK: what a library reads

    // A custom folder named "Photos" beside the built-in Photos library's 1.5 folder.
    // Which library the 1.5 folder belongs to is told by its archive's bundle name
    // when a run takes it over, but not when a check, a drill or the storage view
    // reads: they take every 1.5 folder of the library's name as its own, and drill
    // the built-in library's archives as the custom folder's.
    @Test func a15FolderOfAnotherLibraryOfTheSameNameIsNotReadAsThisOnes() throws {
        let dest = folder("read-other"); defer { try? FileManager.default.removeItem(at: dest) }
        let legacy = dest.appendingPathComponent("Photos")
        try archive(in: legacy, bundle: "Photos Library.photoslibrary", version: v1)
        let custom = lib("custom", "Photos", root: "Desktop/Photos")
        let j = job("c", [custom], dest: dest, mirror: true)
        let p = try LibraryFolders.prepare(job: j, library: custom, in: dest, jobs: [j], isOpen: { _ in false })
        #expect(p.folder.path != legacy.path, "the bundle name told them apart when writing")
        let read = LibraryFolders.folders(job: j, library: custom, in: dest).map(\.path)
        #expect(!read.contains(legacy.path), "the custom folder reads the built-in library's backups: \(read)")
    }

    // MARK: moving versions

    // A run that died after moving one version of three: the next moves the rest.
    @Test func aMoveThatDiedHalfWayFinishesOnTheNextRun() throws {
        let dest = folder("half-move"); defer { try? FileManager.default.removeItem(at: dest) }
        let photos = lib("com.apple.photos", "Photos", root: "Pictures/Photos Library.photoslibrary")
        let legacy = dest.appendingPathComponent("Photos")
        try archive(in: legacy, bundle: "Photos Library.photoslibrary", mirror: true)
        for v in [v1, v2, v3] { try archive(in: legacy, bundle: "Photos Library.photoslibrary", version: v) }
        let mirror = job("m", [photos], dest: dest, mirror: true), sealed = job("s", [photos], dest: dest)
        let mine = dest.appendingPathComponent(LibraryFolderName.make(job: sealed, library: photos))
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        try LibraryIdentity(job: sealed, library: photos).write(in: mine)
        #expect(rename(legacy.appendingPathComponent(v1).path, mine.appendingPathComponent(v1).path) == 0)
        let s = try LibraryFolders.prepare(job: sealed, library: photos, in: dest, jobs: [mirror, sealed], isOpen: { _ in false })
        #expect(s.folder.path == mine.path && names(mine) == [v1, v2, v3])
        #expect(names(legacy) == ["Photos Library.photoslibrary.sparsebundle", "cryoframe-manifest.json"])
        #expect(RestoreDiscovery.scan(dest).count == 4)
    }

    // A folder isn't renamed while a disk image under it is attached (a restore or a
    // drill reading an old version). The versions moved out of a shared 1.5 folder
    // are renamed just the same, and nothing asks.
    @Test func versionsAreNotMovedWhileAnImageInThemIsAttached() throws {
        let dest = folder("open-move"); defer { try? FileManager.default.removeItem(at: dest) }
        let photos = lib("com.apple.photos", "Photos", root: "Pictures/Photos Library.photoslibrary")
        let legacy = dest.appendingPathComponent("Photos")
        try archive(in: legacy, bundle: "Photos Library.photoslibrary", mirror: true)
        try archive(in: legacy, bundle: "Photos Library.photoslibrary", version: v1)
        let mirror = job("m", [photos], dest: dest, mirror: true), sealed = job("s", [photos], dest: dest)
        let open = legacy.appendingPathComponent(v1)
        _ = try LibraryFolders.prepare(job: sealed, library: photos, in: dest, jobs: [mirror, sealed],
                                       isOpen: { $0.path == open.path || $0.path == legacy.path })
        #expect(FileManager.default.fileExists(atPath: open.path), "a version being read was moved from under its reader")
    }

    // MARK: retention

    // Two sealed jobs wrote one 1.5 folder: it is never pruned, whatever either job's
    // retention says.
    @Test func aFolderTwoSealedJobsSharedIsNeverPruned() throws {
        let dest = folder("shared-prune"); defer { try? FileManager.default.removeItem(at: dest) }
        let docs = lib("docs", "Documents")
        let legacy = dest.appendingPathComponent("Documents")
        for v in [v1, v2, v3] { try archive(in: legacy, bundle: "Documents", version: v) }
        let a = job("a", [docs], dest: dest), b = job("b", [docs], dest: dest)
        for j in [a, b] {
            let p = try LibraryFolders.prepare(job: j, library: docs, in: dest, jobs: [a, b], isOpen: { _ in false })
            try archive(in: p.folder, bundle: "Documents", version: v3)
            let failures = JobExecutor.pruneVersions(folders: JobExecutor.prunable(j, ["d": [docs.id: p.folder]]), policy: .keepLast(1), confirmed: { _, _ in true })
            #expect(failures.isEmpty)
        }
        #expect(names(legacy) == [v1, v2, v3])
    }

    // Retention never deletes the version last known to restore (KnownGood). It finds
    // that version by the library's name in the check records, and a library can now
    // be renamed, its folder following. The checks before the rename carry the old
    // name, so the next run's retention finds no known-good version and deletes it,
    // leaving only versions that failed their drills.
    @Test func theLastKnownGoodVersionSurvivesARename() throws {
        let dest = folder("rename-good"); defer { try? FileManager.default.removeItem(at: dest) }
        var projects = lib("p", "Projects")
        var j = job("a", [projects], dest: dest)
        let before = try LibraryFolders.prepare(job: j, library: projects, in: dest, jobs: [j], isOpen: { _ in false }).folder
        for v in [v1, v2, v3] { try archive(in: before, bundle: "Projects", version: v) }
        let date = { (s: String) in VersionStamp.date(s)! }
        let checks = [
            HealthRecord(jobID: j.id, jobName: j.name, checkedAt: date(v3).addingTimeInterval(3600), archivesChecked: 1,
                         failures: ["Projects: didn't reopen"], kind: "drill",
                         verified: [VerifiedArchive(library: "Projects", version: date(v3), passed: false)]),
            HealthRecord(jobID: j.id, jobName: j.name, checkedAt: date(v2).addingTimeInterval(3600), archivesChecked: 1,
                         failures: ["Projects: didn't reopen"], kind: "drill",
                         verified: [VerifiedArchive(library: "Projects", version: date(v2), passed: false)]),
            HealthRecord(jobID: j.id, jobName: j.name, checkedAt: date(v1).addingTimeInterval(3600), archivesChecked: 1,
                         failures: [], kind: "drill",
                         verified: [VerifiedArchive(library: "Projects", version: date(v1), passed: true)]),
        ]
        // not renamed: v1, the one that restored, is kept beside the newest
        #expect(KnownGood.version(of: "Projects", among: [v1, v2, v3].map(date), records: checks) == date(v1))

        projects.displayName = "Client Work"; j.libraries = [projects]
        let after = try LibraryFolders.prepare(job: j, library: projects, in: dest, jobs: [j], isOpen: { _ in false }).folder
        #expect(after.lastPathComponent == "Client Work")
        JobExecutor.pruneVersions(folders: [(projects, after)], policy: .keepLast(1), checks: checks, confirmed: { _, _ in true })
        #expect(names(after).contains(v1), "the last version known to restore was deleted after the rename: \(names(after))")
    }
}
