//
//  LibraryFolderTests.swift
//  CryoframeKitTests
//
//  Library folders found by identity, not name: new folders, 1.5 folders taken over
//  in place, folders two jobs shared, names that follow a rename, a run that died
//  half way, a return to 1.5.6 and back, and what Restore finds.
//

import Testing
import Foundation
@testable import CryoframeKit

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-libf-\(tag)-\(UUID().uuidString.prefix(8))")
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

@Suite struct LibraryFolderTests {

    // MARK: new folders

    @Test func aNewFolderTakesTheLibrarysNameAndCarriesItsIdentity() throws {
        let dest = folder("new"); defer { try? FileManager.default.removeItem(at: dest) }
        let projects = lib("p", "Projects")
        let j = job("a", [projects], dest: dest)
        let p = try LibraryFolders.prepare(job: j, library: projects, in: dest, jobs: [j], isOpen: { _ in false })
        #expect(p.folder.lastPathComponent == "Projects")
        let id = try #require(LibraryIdentity.read(in: p.folder))
        #expect(id.key == "a/p" && id.name == "Projects" && id.jobName == "Job a")
        // found again by the identity, not made twice
        let again = try LibraryFolders.prepare(job: j, library: projects, in: dest, jobs: [j], isOpen: { _ in false })
        #expect(again.folder.path == p.folder.path && names(dest) == ["Projects"])
    }

    // Two libraries with one name (Work/Projects and Personal/Projects) get two
    // folders, where 1.5 wrote both into one and 1.5.6 refused the job.
    @Test func twoLibrariesWithOneNameGetTwoFolders() throws {
        let dest = folder("same"); defer { try? FileManager.default.removeItem(at: dest) }
        let work = lib("w", "Projects", root: "Work/Projects"), home = lib("h", "Projects", root: "Home/Projects")
        let j = job("a", [work, home], dest: dest)
        let a = try LibraryFolders.prepare(job: j, library: work, in: dest, jobs: [j], isOpen: { _ in false })
        let b = try LibraryFolders.prepare(job: j, library: home, in: dest, jobs: [j], isOpen: { _ in false })
        #expect(a.folder.path != b.folder.path)
        #expect(a.folder.lastPathComponent == "Projects")
        #expect(b.folder.lastPathComponent == "Projects [\(LibraryIdentity.shortID("a/h"))]")
    }

    // A folder of a new library's name that belongs to another library.
    @Test func aNameTakenByAnotherLibraryGetsTheShortID() throws {
        let dest = folder("taken"); defer { try? FileManager.default.removeItem(at: dest) }
        let other = lib("x", "Photos"), mine = lib("y", "Photos")
        let jx = job("x", [other], dest: dest), jy = job("y", [mine], dest: dest)
        _ = try LibraryFolders.prepare(job: jx, library: other, in: dest, jobs: [jx, jy], isOpen: { _ in false })
        let p = try LibraryFolders.prepare(job: jy, library: mine, in: dest, jobs: [jx, jy], isOpen: { _ in false })
        #expect(p.folder.lastPathComponent == LibraryFolderName.make(job: jy, library: mine))
        #expect(LibraryIdentity.read(in: dest.appendingPathComponent("Photos"))?.key == "x/x")
    }

    // A run that died after making a suffixed folder and before writing its identity.
    @Test func aFolderLeftWithoutItsIdentityIsPickedUp() throws {
        let dest = folder("half"); defer { try? FileManager.default.removeItem(at: dest) }
        try FileManager.default.createDirectory(at: dest.appendingPathComponent("Projects"), withIntermediateDirectories: true)
        try LibraryIdentity(jobID: "z", libraryID: "z", name: "Projects", jobName: "Z").write(in: dest.appendingPathComponent("Projects"))
        let projects = lib("p", "Projects"), j = job("a", [projects], dest: dest)
        let half = dest.appendingPathComponent(LibraryFolderName.make(job: j, library: projects))
        try FileManager.default.createDirectory(at: half, withIntermediateDirectories: true)
        let p = try LibraryFolders.prepare(job: j, library: projects, in: dest, jobs: [j], isOpen: { _ in false })
        #expect(p.folder.path == half.path && LibraryIdentity.read(in: half)?.key == "a/p")
    }

    // MARK: 1.5 folders

    // One job wrote it: taken over in place, nothing moves, and a return to 1.5.6
    // finds its folder and versions where it left them.
    @Test func a15FolderIsTakenOverInPlace() throws {
        let dest = folder("adopt"); defer { try? FileManager.default.removeItem(at: dest) }
        let photos = lib("com.apple.photos", "Photos", root: "Pictures/Photos Library.photoslibrary")
        let legacy = dest.appendingPathComponent("Photos")
        try archive(in: legacy, bundle: "Photos Library.photoslibrary", version: v1)
        try archive(in: legacy, bundle: "Photos Library.photoslibrary", version: v2)
        let j = job("a", [photos], dest: dest)
        let p = try LibraryFolders.prepare(job: j, library: photos, in: dest, jobs: [j], isOpen: { _ in false })
        #expect(p.folder.path == legacy.path)
        #expect(LibraryIdentity.read(in: legacy)?.key == "a/com.apple.photos")
        #expect(names(legacy) == [v1, v2] && names(dest) == ["Photos"])
        #expect(RestoreDiscovery.scan(dest).count == 2)
    }

    // One job's mirror and another's sealed versions of the same library shared a
    // folder. The mirror job takes it over; the versions move, one folder at a time,
    // into the sealed job's own folder, where its retention sees them.
    @Test func aFolderAMirrorAndSealedVersionsSharedIsSplit() throws {
        let dest = folder("shared"); defer { try? FileManager.default.removeItem(at: dest) }
        let photos = lib("com.apple.photos", "Photos", root: "Pictures/Photos Library.photoslibrary")
        let legacy = dest.appendingPathComponent("Photos")
        try archive(in: legacy, bundle: "Photos Library.photoslibrary", mirror: true)
        try archive(in: legacy, bundle: "Photos Library.photoslibrary", version: v1)
        try archive(in: legacy, bundle: "Photos Library.photoslibrary", version: v2)
        let mirror = job("m", [photos], dest: dest, mirror: true), sealed = job("s", [photos], dest: dest)
        let all = [mirror, sealed]
        let s = try LibraryFolders.prepare(job: sealed, library: photos, in: dest, jobs: all, isOpen: { _ in false })
        #expect(s.folder.path != legacy.path)
        #expect(names(s.folder) == [v1, v2], "the versions moved in")
        #expect(s.notes.contains { $0.contains("moved 2 earlier versions") }, "\(s.notes)")
        let m = try LibraryFolders.prepare(job: mirror, library: photos, in: dest, jobs: all, isOpen: { _ in false })
        #expect(m.folder.path == legacy.path && LibraryIdentity.read(in: legacy)?.key == "m/com.apple.photos")
        #expect(names(legacy) == ["Photos Library.photoslibrary.sparsebundle", "cryoframe-manifest.json"])
        // Restore finds every version and the mirror
        #expect(RestoreDiscovery.scan(dest).count == 3)
    }

    // Two sealed jobs wrote one folder: whose version is whose can't be told. Nobody
    // takes it over or prunes it; both start their own folders and both still read it.
    @Test func aFolderTwoSealedJobsSharedIsLeftForReading() throws {
        let dest = folder("ambig"); defer { try? FileManager.default.removeItem(at: dest) }
        let docs = lib("docs", "Documents")
        let legacy = dest.appendingPathComponent("Documents")
        try archive(in: legacy, bundle: "Documents", version: v1)
        let a = job("a", [docs], dest: dest), b = job("b", [docs], dest: dest)
        let pa = try LibraryFolders.prepare(job: a, library: docs, in: dest, jobs: [a, b], isOpen: { _ in false })
        let pb = try LibraryFolders.prepare(job: b, library: docs, in: dest, jobs: [a, b], isOpen: { _ in false })
        #expect(pa.folder.path != legacy.path && pb.folder.path != legacy.path && pa.folder.path != pb.folder.path)
        #expect(LibraryIdentity.read(in: legacy) == nil && names(legacy) == [v1])
        #expect(LibraryFolders.folders(job: a, library: docs, in: dest).map(\.path) == [pa.folder.path, legacy.path])
        #expect(LibraryFolders.folders(job: b, library: docs, in: dest).map(\.path) == [pb.folder.path, legacy.path])
    }

    // A custom folder named "Photos" beside the built-in Photos: the 1.5 folder holds
    // the built-in library's archive, and its bundle name says so.
    @Test func theArchivesBundleNameSaysWhichLibraryA15FolderIs() throws {
        let dest = folder("bundle"); defer { try? FileManager.default.removeItem(at: dest) }
        let builtIn = lib("com.apple.photos", "Photos", root: "Pictures/Photos Library.photoslibrary")
        let custom = lib("custom", "Photos", root: "Desktop/Photos")
        let legacy = dest.appendingPathComponent("Photos")
        try archive(in: legacy, bundle: "Photos Library.photoslibrary", mirror: true)
        let j = job("a", [builtIn, custom], dest: dest, mirror: true)
        let c = try LibraryFolders.prepare(job: j, library: custom, in: dest, jobs: [j], isOpen: { _ in false })
        let b = try LibraryFolders.prepare(job: j, library: builtIn, in: dest, jobs: [j], isOpen: { _ in false })
        #expect(b.folder.path == legacy.path, "the built-in library kept its mirror")
        #expect(c.folder.path != legacy.path)
    }

    // The Photos library can be another than the usual one (chosen in Cryoframe, or
    // renamed since), and its 1.5 archives carry the name it had: still its own, read
    // and taken over. A custom folder named "Photos" doesn't read them.
    @Test func aBuiltInLibrarysArchiveUnderAnotherPackageNameIsStillItsOwn() throws {
        let dest = folder("pkg"); defer { try? FileManager.default.removeItem(at: dest) }
        let legacy = dest.appendingPathComponent("Photos")
        try archive(in: legacy, bundle: "Photos Library 2.photoslibrary", version: v1)
        let j = job("a", [.photos], dest: dest)
        #expect(LibraryFolders.archives(job: j, library: .photos, in: dest).count == 1)
        let custom = lib("custom", "Photos", root: "Desktop/Photos"), c = job("c", [custom], dest: dest)
        #expect(LibraryFolders.archives(job: c, library: custom, in: dest).isEmpty)
        let p = try LibraryFolders.prepare(job: j, library: .photos, in: dest, jobs: [j, c], isOpen: { _ in false })
        #expect(p.folder.path == legacy.path, "not taken over: \(p.folder.lastPathComponent)")
    }

    // MARK: renaming

    @Test func aRenamedLibrarysFolderFollowsItsName() throws {
        let dest = folder("rename"); defer { try? FileManager.default.removeItem(at: dest) }
        var projects = lib("p", "Projects")
        var j = job("a", [projects], dest: dest)
        let before = try LibraryFolders.prepare(job: j, library: projects, in: dest, jobs: [j], isOpen: { _ in false })
        try archive(in: before.folder, bundle: "Projects", version: v1)
        projects.displayName = "Client Work"; j.libraries = [projects]
        // not while a disk image in it is open
        let held = try LibraryFolders.prepare(job: j, library: projects, in: dest, jobs: [j], isOpen: { _ in true })
        #expect(held.folder.path == before.folder.path && LibraryIdentity.read(in: held.folder)?.name == "Client Work")
        let after = try LibraryFolders.prepare(job: j, library: projects, in: dest, jobs: [j], isOpen: { _ in false })
        #expect(after.folder.lastPathComponent == "Client Work" && names(after.folder) == [v1])
        #expect(RestoreDiscovery.scan(dest).first?.libraryName == "Client Work")
    }

    // MARK: a return to 1.5.6, and back

    // 1.5.6 doesn't know a suffixed folder and writes a new plain one. Back on 1.6,
    // its versions move into the library's folder; a mirror it wrote stays, is said
    // so, and Restore still finds it.
    @Test func versionsWrittenByAnEarlierVersionMoveBackIn() throws {
        let dest = folder("return"); defer { try? FileManager.default.removeItem(at: dest) }
        let notes = lib("q", "Notes"), j = job("s", [notes], dest: dest)
        let suffixed = dest.appendingPathComponent(LibraryFolderName.make(job: j, library: notes))
        try FileManager.default.createDirectory(at: suffixed, withIntermediateDirectories: true)
        try LibraryIdentity(job: j, library: notes).write(in: suffixed)
        try archive(in: suffixed, bundle: "Notes", version: v1)
        try archive(in: dest.appendingPathComponent("Notes"), bundle: "Notes", version: v2)     // what 1.5.6 wrote
        let back = try LibraryFolders.prepare(job: j, library: notes, in: dest, jobs: [j], isOpen: { _ in false })
        #expect(back.folder.path == suffixed.path)
        #expect(names(suffixed) == [v1, v2])
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("Notes").path), "the emptied folder is gone")
        #expect(RestoreDiscovery.scan(dest).count == 2)
    }

    @Test func aMirrorAnEarlierVersionWroteStaysAndIsSaidSo() throws {
        let dest = folder("return-m"); defer { try? FileManager.default.removeItem(at: dest) }
        let notes = lib("q", "Notes"), j = job("s", [notes], dest: dest, mirror: true)
        let suffixed = dest.appendingPathComponent(LibraryFolderName.make(job: j, library: notes))
        try FileManager.default.createDirectory(at: suffixed, withIntermediateDirectories: true)
        try LibraryIdentity(job: j, library: notes).write(in: suffixed)
        try archive(in: suffixed, bundle: "Notes", mirror: true)
        try archive(in: dest.appendingPathComponent("Notes"), bundle: "Notes", mirror: true)     // 1.5.6's fresh mirror
        let p = try LibraryFolders.prepare(job: j, library: notes, in: dest, jobs: [j], isOpen: { _ in false })
        #expect(p.folder.path == suffixed.path)
        #expect(p.notes.contains { $0.contains("earlier copy of Notes") }, "\(p.notes)")
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("Notes/Notes.sparsebundle").path))
    }

    // MARK: versions beside a mirror

    // A folder holding a mirror and sealed versions (a 1.5 folder two jobs shared) was
    // a leaf to discovery: the manifest at its top hid every version under it.
    @Test func versionsBesideAMirrorAreFound() throws {
        let dest = folder("leaf"); defer { try? FileManager.default.removeItem(at: dest) }
        let legacy = dest.appendingPathComponent("Photos")
        try archive(in: legacy, bundle: "Photos Library.photoslibrary", mirror: true)
        try archive(in: legacy, bundle: "Photos Library.photoslibrary", version: v1)
        try archive(in: legacy, bundle: "Photos Library.photoslibrary", version: v3)
        let found = RestoreDiscovery.scan(dest)
        #expect(found.count == 3, "\(found.map(\.dir.lastPathComponent))")
        #expect(RestoreDiscovery.scan(legacy).count == 3)
    }

    // MARK: what Restore calls them

    // Archives are named by their library's name, not the folder's; two libraries
    // with one name are told apart by their folders.
    @Test func archivesAreNamedByTheirLibraryAndTwoOfOneNameAreToldApart() throws {
        let dest = folder("names"); defer { try? FileManager.default.removeItem(at: dest) }
        let work = lib("w", "Projects", root: "Work/Projects"), home = lib("h", "Projects", root: "Home/Projects")
        let j = job("a", [work, home], dest: dest)
        let a = try LibraryFolders.prepare(job: j, library: work, in: dest, jobs: [j], isOpen: { _ in false }).folder
        let b = try LibraryFolders.prepare(job: j, library: home, in: dest, jobs: [j], isOpen: { _ in false }).folder
        try archive(in: a, bundle: "Projects", version: v1)
        try archive(in: b, bundle: "Projects", version: v1)
        let found = RestoreDiscovery.scan(dest)
        #expect(Set(found.map(\.libraryName)).count == 2, "\(found.map(\.libraryName))")
        #expect(found.allSatisfy { $0.libraryName.hasPrefix("Projects") })
        #expect(Set(found.compactMap(\.libraryKey)) == ["a/w", "a/h"])
        // scanned on its own, a library folder's archives carry the plain name
        #expect(RestoreDiscovery.scan(b).map(\.libraryName) == ["Projects"])
        #expect(found.allSatisfy { $0.displayName == "Projects" })
    }

    // Told apart for showing, the library is still found by its name: a rehearsal
    // expecting "Notes" finds it beside an earlier copy of the same name.
    @Test func aLibraryToldApartFromAnotherIsStillFoundByName() throws {
        let dest = folder("rehearse"); defer { try? FileManager.default.removeItem(at: dest) }
        let notes = lib("q", "Notes"), j = job("s", [notes], dest: dest)
        let mine = dest.appendingPathComponent(LibraryFolderName.make(job: j, library: notes))
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        try LibraryIdentity(job: j, library: notes).write(in: mine)
        try archive(in: mine, bundle: "Notes", version: v1)
        try archive(in: dest.appendingPathComponent("Notes"), bundle: "Notes", mirror: true)
        #expect(Set(RestoreDiscovery.scan(dest).map(\.libraryName)).count == 2)
        #expect(RecoveryRehearsal().rehearse(destination: dest, expecting: ["Notes"]).missing.isEmpty)
        // and the note written into the destination sends people to the right folders
        let note = RecoveryNote.text(for: RestoreDiscovery.scan(dest))
        #expect(note.contains("In the folder \(mine.lastPathComponent)/, 1 version"), "\(note)")
        #expect(note.contains("In the folder Notes/, one copy kept up to date"), "\(note)")
    }
}
