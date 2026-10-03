//
//  Cleanup17EdgeTests.swift
//  CryoframeKitTests
//
//  The 1.7 cleanup round and the removed-items archive, at their edges: a restore in
//  place cut off at the other points around the Trash, a record of it that can't be
//  read, a leftover from 1.6 whose name matches no library, Find a File after a file
//  is deleted by hand from Removed items, Stop while a removed-items archive is
//  gathered, a removed-items archive cut off while it was copied to the drive, and the
//  pairing preview of an app library as plain files on a Mac OS Extended drive.
//
//  Some of these fail on purpose: each says what is wrong where it fails.
//

import Testing
import Foundation
@testable import CryoframeKit

private func tempFolder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-c17-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

@discardableResult
private func put(_ root: URL, _ rel: String, _ text: String, date: Int = 1_700_000_000) throws -> URL {
    let url = root.appendingPathComponent(rel)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
    var times = [timespec(tv_sec: date, tv_nsec: 0), timespec(tv_sec: date, tv_nsec: 0)]
    _ = utimensat(AT_FDCWD, url.path, &times, 0)
    return url
}

private func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

private func stagingFolders(in parent: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []).filter { $0.hasPrefix(RestoreStaging.prefix) }
}

private func said(_ l: RestoreStaging.Leftover) -> String {
    "\(l.what) \(l.live.path) \(l.copy.path) \(l.trashed?.path ?? "-")"
}

private struct CutOff: Error {}

/// a zip of a library named `name` holding a.txt ("restored"), and the live library
/// of that name it restores over (a.txt: "live")
private func restoreFixture(_ base: URL, name: String) throws -> (archive: RestorableArchive, live: URL) {
    let lib = base.appendingPathComponent("made/\(name)")
    try put(lib, "a.txt", "restored")
    try put(lib, "sub/b.txt", "b")
    let dir = base.appendingPathComponent("backup/\(name)/2026-10-01-020000")
    let result = try SealedArchiveEngine(.zip).archive(ArchiveSource(name: name, root: lib), to: dir)
    try ArchiveManifest.write(try ArchiveManifest.build(for: result), toDir: dir)
    let archive = try #require(RestoreDiscovery.archive(at: dir))
    let live = base.appendingPathComponent("home/\(name)")
    try put(live, "a.txt", "live")
    return (archive, live)
}

@Suite(.serialized) struct Cleanup17EdgeTests {

    // MARK: restore in place, cut off

    // Killed after the copy was verified and recorded, before the library went to the
    // Trash: the library is still in its place. Neither is deleted: the copy is put
    // beside it, under a name that shows.
    @Test func aRestoreCutOffBeforeTheTrashKeepsBoth() throws {
        let base = tempFolder("pretrash")
        defer { try? FileManager.default.removeItem(at: base) }
        let (archive, live) = try restoreFixture(base, name: "Papers")
        let parent = live.deletingLastPathComponent()
        let (staging, restored) = try RestoreEngine().stage(archive, in: parent, verify: true, passphrase: nil, clash: nil,
                                                            inPlace: true, onStage: { _ in })
        try staging.markReady(item: restored, live: live)
        staging.release()                               // killed here, before the Trash

        let found = RestoreStaging.recover(lives: [live])
        let beside = parent.appendingPathComponent("Papers (2)")
        #expect(found.map(said) == [said(.init(what: .verifiedBeside, live: live, copy: beside, trashed: nil))])
        #expect(text(live.appendingPathComponent("a.txt")) == "live")
        #expect(text(beside.appendingPathComponent("a.txt")) == "restored")
        #expect(text(beside.appendingPathComponent("sub/b.txt")) == "b")
        #expect(stagingFolders(in: parent).isEmpty)
    }

    // A package library cut off after the Trash, with its place taken meanwhile and
    // "(2)" taken too: the copy goes to "(3)" with the package extension last, and
    // nothing of the four (the new library, the earlier "(2)", the copy, the one in
    // the Trash) is deleted.
    @Test func aCutOffPackageLibraryIsPutBesideUnderANameThatStillOpens() throws {
        let base = tempFolder("package")
        defer { try? FileManager.default.removeItem(at: base) }
        let name = "Photos Library.photoslibrary"
        let (archive, live) = try restoreFixture(base, name: name)
        let parent = live.deletingLastPathComponent()
        let trash = base.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let trashed = trash.appendingPathComponent(name)
        #expect(throws: CutOff.self) {
            try RestoreInPlace.run(archive, live: live, passphrase: nil, trash: { url in
                try FileManager.default.moveItem(at: url, to: trashed)
                return trashed
            }, afterTrash: { throw CutOff() })
        }
        try put(live, "new.txt", "new")                                 // Photos made a new library
        try put(parent.appendingPathComponent("Photos Library (2).photoslibrary"), "a.txt", "earlier")

        let found = RestoreStaging.recover(lives: [live])
        let three = parent.appendingPathComponent("Photos Library (3).photoslibrary")
        #expect(found.map(said) == [said(.init(what: .verifiedBeside, live: live, copy: three, trashed: trashed))])
        #expect(text(three.appendingPathComponent("a.txt")) == "restored")
        #expect(text(live.appendingPathComponent("new.txt")) == "new")
        #expect(text(parent.appendingPathComponent("Photos Library (2).photoslibrary/a.txt")) == "earlier")
        #expect(text(trashed.appendingPathComponent("a.txt")) == "live")
        #expect(stagingFolders(in: parent).isEmpty)
        #expect(RestoreStaging.recover(lives: [live]).isEmpty)
    }

    // FAILS ON PURPOSE. The record of a restore in place cut off after the Trash can't
    // be read (a damaged file, or one a later Cryoframe wrote in a form this one doesn't
    // read). The verified copy is the only thing in the library's place's stead, the
    // library itself is in the Trash; recover treats an unreadable record like no
    // record, calls the copy unfinished, and deletes it.
    @Test func aRecordThatCantBeReadNeverDeletesTheVerifiedCopy() throws {
        let base = tempFolder("badready")
        defer { try? FileManager.default.removeItem(at: base) }
        let (archive, live) = try restoreFixture(base, name: "Papers")
        let parent = live.deletingLastPathComponent()
        let trash = base.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        #expect(throws: CutOff.self) {
            try RestoreInPlace.run(archive, live: live, passphrase: nil, trash: { url in
                let to = trash.appendingPathComponent("Papers")
                try FileManager.default.moveItem(at: url, to: to)
                return to
            }, afterTrash: { throw CutOff() })
        }
        let dir = try #require(stagingFolders(in: parent).first)
        try Data("{\"live\": ".utf8).write(to: parent.appendingPathComponent("\(dir)/\(RestoreStaging.readyName)"))

        _ = RestoreStaging.recover(lives: [live])
        let survivors = [parent.appendingPathComponent("\(dir)/Papers/a.txt"), live.appendingPathComponent("a.txt"),
                         parent.appendingPathComponent("Papers (2)/a.txt")].filter { text($0) == "restored" }
        #expect(survivors.count == 1, "the verified copy was deleted by recover: the record couldn't be read, so it was taken for an unfinished copy")
    }

    // FAILS ON PURPOSE (NIT). A 1.6 leftover whose library name matches none of the
    // libraries in its folder is named after the first of them: a Photos library is
    // put beside as "Photo Booth Library (2)", and the alert says it is a restore of
    // Photo Booth.
    @Test func aLeftoverFromAnEarlierVersionIsNamedForWhatItIs() throws {
        let base = tempFolder("legacyname")
        defer { try? FileManager.default.removeItem(at: base) }
        let home = base.appendingPathComponent("Pictures")
        let booth = home.appendingPathComponent("Photo Booth Library")
        let photos = home.appendingPathComponent("Photos Library.photoslibrary")
        let old = home.appendingPathComponent("\(RestoreStaging.prefix)\(UUID().uuidString)")
        try put(old, "Holiday.photoslibrary/a.txt", "old copy")

        let found = RestoreStaging.recover(lives: [booth, photos])
        try #require(found.count == 1)
        #expect(text(found[0].copy.appendingPathComponent("a.txt")) == "old copy")
        #expect(!found[0].copy.lastPathComponent.hasPrefix("Photo Booth"),
                "a copy of “Holiday.photoslibrary” was named \(found[0].copy.lastPathComponent)")
    }

    // MARK: Find a File and Removed items

    // FAILS ON PURPOSE. A plain copy's Removed items are ordinary files, and the person
    // deletes one in Finder (or on another computer). The index still holds it, the
    // search trusts the index for its day, and Find a File says the file is kept in
    // Removed items, at a path where nothing is.
    @Test func aFileDeletedByHandFromRemovedItemsIsNotFound() throws {
        let base = tempFolder("byhand")
        defer { try? FileManager.default.removeItem(at: base) }
        let src = base.appendingPathComponent("src/Taxes")
        try put(src, "2024/W-2.pdf", "w2")
        try put(src, "keep.txt", "k")
        let dest = base.appendingPathComponent("dest")
        let lib = ContentType.genericFolder(id: "taxes", displayName: "Taxes", path: .absolute(src.path))
        let job = BackupJob(name: "T", libraries: [lib], target: .localVolume(id: "d", name: "Disk", dir: dest),
                            format: .plainFiles, frequency: .manual, createdAt: Date())
        let exfatLike = FileSystemProfile(kind: .exfat, fsType: "exfat", foldsCase: true, cluster: 4096, companions: false)
        func once() throws {
            let prepared = try LibraryFolders.prepare(job: job, library: lib, in: dest, jobs: [job])
            _ = try JobExecutor.plainFiles(job: job, library: lib, source: ArchiveSource(name: "Taxes", root: src), folder: prepared.folder,
                                           target: job.target, profile: exfatLike, bytes: 10, partial: false, now: Date(),
                                           runner: ProcessCommandRunner())
        }
        try once()
        try FileManager.default.removeItem(at: src.appendingPathComponent("2024/W-2.pdf"))
        try once()
        let a = try #require(RestoreDiscovery.scan(dest).first)
        let removed = a.dir.appendingPathComponent(PlainCopyLayout.removedFolder)
        let day = try #require(RemovedItems.days(in: removed).first?.folder)
        let kept = day.appendingPathComponent("2024/W-2.pdf")
        #expect(text(kept) == "w2")
        try FileManager.default.removeItem(at: kept)                    // deleted in Finder

        let now = try #require(RestoreDiscovery.scan(dest).first)
        let r = try #require(ContentsSearch().search(ContentsQuery("W-2")!, in: now, passphrases: { _ in [] }))
        let hits = r.hits.filter { $0.removedOn != nil }
        #expect(hits.isEmpty, "Find a File says “\(hits.first?.path ?? "")” is kept at \(hits.first.map { ArchiveLayout.item($0, in: now.dir, for: now).path } ?? ""), which doesn't exist")
    }

    // MARK: removed-items archives

    // Stop pressed while the items are gathered out of an opened version: the going
    // versions all stay, no archive or half of one is left in Removed items, and
    // scratch is empty.
    @Test func stopWhileGatheringKeepsEveryVersionAndLeavesNothing() throws {
        let fx = try RemovedFixture()
        defer { fx.remove() }
        let control = RunControl()
        let keeper = fx.keeper(control: control, open: { a, p in
            control.cancel()                            // Stop, as the version opens
            return try ArchiveReader().open(a.archiveResult(), passphrase: p)
        })
        let out = keeper.keep(goingFrom: [fx.v1], in: fx.folder)
        #expect(out.spared == [fx.v1] && out.why == "the backup was stopped" && out.kept == 0)
        #expect(RemovedArchive.archives(in: fx.folder).isEmpty)
        let removed = fx.folder.appendingPathComponent(PlainCopyLayout.removedFolder)
        #expect(PlainCopy.list(removed.path).isEmpty, "\(PlainCopy.list(removed.path))")
        #expect(!FileManager.default.fileExists(atPath: fx.scratch.appendingPathComponent("\(fx.jobID)/build/messages.removed").path))
        #expect(FileManager.default.fileExists(atPath: fx.v1.path))
    }

    // FAILS ON PURPOSE. A run killed (a crash, Force Quit, a restart's 15 seconds)
    // while copying a removed-items archive to the drive leaves its folder in Removed
    // items without a manifest. Unlike a dated folder left the same way (a husk, removed
    // by the next prune), nothing ever removes it, Restore doesn't show it, and in
    // Finder it looks like the archives the guide says may be deleted by hand.
    @Test func aRemovedItemsArchiveCutOffWhileCopiedIsNotLeftForever() throws {
        let fx = try RemovedFixture()
        defer { fx.remove() }
        let husk = fx.folder.appendingPathComponent("\(PlainCopyLayout.removedFolder)/2026-09-30-020000", isDirectory: true)
        try FileManager.default.createDirectory(at: husk, withIntermediateDirectories: true)
        try Data(count: 64 * 1024).write(to: husk.appendingPathComponent("Attachments.zip"))

        let failures = JobExecutor.pruneVersions(folders: [(ContentType.messagesAttachments, fx.folder)], policy: .keepLast(1),
                                                 confirmed: { _, _ in true },
                                                 keepRemoved: { _, folder, going in fx.keeper().keep(goingFrom: going, in: folder) })
        #expect(failures.isEmpty, "\(failures)")
        #expect(RemovedArchive.archives(in: fx.folder).count == 1)
        #expect(!FileManager.default.fileExists(atPath: husk.path), "a removed-items archive cut off while copied is never removed")
    }

    // MARK: pairing preview

    // FAILS ON PURPOSE. A plain-files job of an app library (kept on an APFS drive)
    // taking turns with a Mac OS Extended drive of the same name: the run refuses an
    // app library there (FileSystemProfile.refusal), but the pairing preview says the
    // next backup makes a plain copy there.
    @Test func thePairingPreviewSaysAnAppLibraryIsRefusedOnAMacOSExtendedDrive() throws {
        let base = tempFolder("pairhfs")
        defer { try? FileManager.default.removeItem(at: base) }
        let image = base.appendingPathComponent("twin.dmg"), mnt = base.appendingPathComponent("mnt")
        let r = ProcessCommandRunner()
        let made = try r.run("/usr/bin/hdiutil", ["create", "-size", "20m", "-fs", "HFS+", "-volname", "CF17Twin", "-o", image.path, "-quiet"], stdin: nil)
        try #require(made.ok, "\(made.stderr)")
        try FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)
        let attached = try r.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-mountpoint", mnt.path, image.path], stdin: nil)
        try #require(attached.ok, "\(attached.stderr)")
        defer { _ = try? r.run("/usr/bin/hdiutil", ["detach", mnt.path, "-force"], stdin: nil) }

        let src = base.appendingPathComponent("Photos Library.photoslibrary")
        try put(src, "database/Photos.sqlite", "db")
        try put(src, "originals/A/IMG_0001.heic", "img")
        let lib = ContentType(id: "test.photos.c17", displayName: "Photos", paths: [.absolute(src.path)],
                              owningProcess: nil, kind: .liveDB, integrityProbe: nil)
        let dir = mnt.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = Target.localVolume(id: "t", name: "CF17Twin", dir: dir)
        let profile = FileSystemProfile.of(dir, target: target)
        let why = try #require(profile.refusal(appLibrary: "Photos"), "the run doesn't refuse it here (\(profile.kind))")

        let look = DrivePairing.plainFiles(lib, folder: nil, in: dir, target: target)
        #expect(look.effects.contains { $0.contains(why) || $0.localizedCaseInsensitiveContains("can't") },
                "the preview says “\(look.effects.joined(separator: " "))” while the run refuses: \(why)")
    }
}

/// a Messages attachments folder on a destination with two zip versions: v1 holds a
/// file deleted before v2
private struct RemovedFixture {
    let jobID = "job-c17"
    let base: URL, folder: URL, scratch: URL, v1: URL, v2: URL

    init() throws {
        base = tempFolder("rmv")
        folder = base.appendingPathComponent("Backups/Messages attachments", isDirectory: true)
        scratch = base.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lib = ContentType.messagesAttachments
        try LibraryIdentity(jobID: jobID, libraryID: lib.id, name: lib.displayName, jobName: "Texts").write(in: folder)
        let src = base.appendingPathComponent("Attachments")
        try put(src, "0a/01/A/a.heic", "a")
        try put(src, "0b/02/B/b.jpg", "b")
        v1 = try Self.version(src, at: 1_750_000_000, in: folder, base: base, jobID: jobID)
        try FileManager.default.removeItem(at: src.appendingPathComponent("0b"))
        v2 = try Self.version(src, at: 1_760_000_000, in: folder, base: base, jobID: jobID)
    }

    static func version(_ src: URL, at date: TimeInterval, in folder: URL, base: URL, jobID: String) throws -> URL {
        let lib = ContentType.messagesAttachments
        let stamp = VersionStamp.string(Date(timeIntervalSince1970: date))
        let build = base.appendingPathComponent("build-\(stamp)")
        let listing = ContentsListing.Collector(binding: ContentsCrypto.Binding(jobID: jobID, libraryID: lib.id, version: stamp))
        _ = JobExecutor.directoryStats(src, listing: listing)
        let built = try SealedArchiveEngine(.zip).archive(ArchiveSource(name: "Attachments", root: src), to: build)
        let contents = ContentsListing.write(listing, master: nil, encrypted: false, into: build)
        let dir = folder.appendingPathComponent(stamp, isDirectory: true)
        _ = try SealedArchiveEngine(.zip).distribute(builtFile: built.artifacts[0], into: dir, encrypted: false, contents: contents)
        try? FileManager.default.removeItem(at: build)
        return dir
    }

    func keeper(control: RunControl = RunControl(), open: ((RestorableArchive, String?) throws -> OpenedArchive)? = nil) -> RemovedArchive {
        let rel = "\(jobID)/build/messages.removed"
        return RemovedArchive(library: .messagesAttachments, jobID: jobID, sealed: .zip, passphrase: nil, listKey: nil,
                              buildDir: scratch.appendingPathComponent(rel), gatherDir: scratch.appendingPathComponent(rel),
                              runner: ProcessCommandRunner(control: control), now: Date(timeIntervalSince1970: 1_800_000_000), open: open)
    }

    func remove() { try? FileManager.default.removeItem(at: base) }
}
