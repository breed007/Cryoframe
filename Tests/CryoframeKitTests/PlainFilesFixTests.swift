//
//  PlainFilesFixTests.swift
//  CryoframeKitTests
//
//  The plain-files rules PlainFilesEdgeTests doesn't reach: FAT32's local-time dates
//  across a daylight saving change, the dates each drive keeps and what a run says of
//  those it can't, the names Removed items gives each deletion, a file and a folder
//  added inside read-only folders on a Mac drive, and how Find a File shows and opens
//  an item kept in Removed items.
//

import Testing
import Foundation
@testable import CryoframeKit

private func tempDir(_ tag: String) -> URL {
    let d = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        .appendingPathComponent("cf-plainfix-\(tag)-\(UUID().uuidString.prefix(8))")
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

private let fat32Like = FileSystemProfile(kind: .fat32, fsType: "msdos", foldsCase: true, cluster: 4096, companions: false)
private let exfatLike = FileSystemProfile(kind: .exfat, fsType: "exfat", foldsCase: true, cluster: 4096, companions: false)

@Suite(.serialized) struct PlainFilesFixTests {

    // MARK: dates

    // FAT32 keeps local time, worked out with the UTC offset in force: once the clocks
    // change, every file of the copy reads an hour off the library's. The clock is
    // faked here by dating the copy's files an hour either way: none is copied again,
    // while a file changed by any other amount still is.
    @Test func aDaylightSavingChangeDoesNotCopyAFAT32DriveAgain() throws {
        let base = tempDir("dst")
        defer { try? FileManager.default.removeItem(at: base) }
        let src = base.appendingPathComponent("src"), copy = base.appendingPathComponent("copy")
        let t = 1_700_000_000
        for (name, copyDate) in [("spring.txt", t + 3600), ("fall.txt", t - 3600), ("odd.txt", t + 3601), ("same.txt", t + 1)] {
            try put(src, name, name, date: t)
            try put(copy, name, name, date: copyDate)
        }
        try put(src, "edited.txt", "edited", date: t)
        try put(copy, "edited.txt", "edited", date: t + 7200)
        try put(src, "other.txt", "other", date: t)
        try put(copy, "other.txt", "other", date: t + 1800)

        let fat = try PlainCopyPlanner(profile: fat32Like).plan(source: src, copy: copy)
        #expect(Set(fat.written) == ["edited.txt", "other.txt"])
        // exFAT keeps UTC: an hour off is a change there
        let ex = try PlainCopyPlanner(profile: exfatLike).plan(source: src, copy: copy)
        #expect(Set(ex.written) == ["spring.txt", "fall.txt", "odd.txt", "same.txt", "edited.txt", "other.txt"])

        #expect(fat32Like.sameDate(library: t, copy: t + 3599))
        #expect(!fat32Like.sameDate(library: t, copy: t + 3598))
        #expect(!fat32Like.sameDate(library: t, copy: t + 3602))
        #expect(!FileSystemProfile(kind: .network, fsType: "smbfs").sameDate(library: t, copy: t + 3600))
    }

    @Test func eachDriveKeepsItsOwnDates() {
        let apfs = FileSystemProfile(kind: .apfs, fsType: "apfs")
        let hfs = FileSystemProfile(kind: .hfs, fsType: "hfs")
        #expect(apfs.clamped(0) == 0 && apfs.clamped(7_258_118_400) == 7_258_118_400)
        #expect(exfatLike.clamped(0) == 315_619_200)
        #expect(exfatLike.clamped(7_258_118_400) == 4_102_444_800)
        #expect(fat32Like.clamped(1_700_000_000) == 1_700_000_000)
        #expect(hfs.clamped(7_258_118_400) == 2_208_988_800)
        #expect(hfs.clamped(-2_208_988_800) == -2_082_758_400)
        // dated outside what exFAT keeps: current once the copy has the nearest date
        #expect(exfatLike.sameDate(library: 0, copy: 315_619_200))
        #expect(!exfatLike.sameDate(library: 0, copy: 315_532_800))

        let note = PlainCopy.datesNote(["a.txt", "b/c.txt"], profile: exfatLike)
        #expect(note == "2 files are dated before 1980 or after 2099 (“a.txt”, “b/c.txt”), which an exFAT drive can't keep. They are copied, with the nearest date it keeps.")
        #expect(PlainCopy.datesNote([], profile: exfatLike) == nil)
        #expect(PlainCopy.datesNote(["a"], profile: apfs) == nil)
    }

    // A run to a drive that can't keep a file's date says so, and doesn't fail.
    @Test func aRunSaysWhichDatesTheDriveCantKeep() throws {
        let base = tempDir("datenote")
        defer { try? FileManager.default.removeItem(at: base) }
        let src = base.appendingPathComponent("Work"), folder = base.appendingPathComponent("dest")
        try put(src, "old.txt", "1970", date: 0)
        try put(src, "new.txt", "now")
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let pc = PlainCopy(profile: exfatLike, runner: ProcessCommandRunner(), calendar: utc, freeSpace: { _ in .max },
                           companions: false, accepts: { _ in true })
        let out = try pc.run(src, in: folder)
        #expect(out.notes.contains { $0.hasPrefix("1 file is dated before 1980") && $0.contains("“old.txt”") }, "\(out.notes)")
        var st = stat()
        #expect(lstat(folder.appendingPathComponent("Work/old.txt").path, &st) == 0 && st.st_mtimespec.tv_sec == 315_619_200)
        #expect(try pc.run(src, in: folder).written == 0)
    }

    // Mac OS Extended keeps 1904 to 2040. A file dated outside that is copied once and
    // dated the nearest it keeps; later runs pass it over (rsync, comparing the
    // library's date, used to copy it again whole every time), and copy it again once
    // it changes.
    @Test func aFileAMacDriveCantDateIsCopiedOnce() throws {
        let base = tempDir("hfsdate")
        defer { try? FileManager.default.removeItem(at: base) }
        let image = base.appendingPathComponent("drive.dmg"), mount = base.appendingPathComponent("vol", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let made = try ProcessCommandRunner().run("/usr/bin/hdiutil", ["create", "-size", "32m", "-fs", "HFS+", "-volname", "MAC",
                                                                       "-type", "UDIF", image.path], stdin: nil)
        try #require(made.ok, "\(made.stderr)")
        let attached = try DiskImageGate.serialized {
            try ProcessCommandRunner().runRetryingBusy("/usr/bin/hdiutil", ["attach", image.path, "-mountpoint", mount.path, "-nobrowse"])
        }
        try #require(attached.ok, "\(attached.stderr)")
        defer { MountPoint.detach(mount, runner: ProcessCommandRunner()) }

        let src = base.appendingPathComponent("Old"), folder = mount.appendingPathComponent("Old-plain")
        try put(src, "1900.txt", "old", date: -2_208_988_800)
        try put(src, "2200.txt", "late", date: 7_258_118_400)
        try put(src, "now.txt", "now")
        let profile = FileSystemProfile.of(folder)
        #expect(profile.kind == .hfs)
        func run() throws -> PlainCopyOutcome { try PlainCopy(profile: profile, runner: ProcessCommandRunner()).run(src, in: folder) }
        func inode(_ name: String) -> ino_t {
            var st = stat()
            return lstat(folder.appendingPathComponent("Old/\(name)").path, &st) == 0 ? st.st_ino : 0
        }
        _ = try run()
        let first = ["1900.txt", "2200.txt", "now.txt"].map(inode)
        #expect(!first.contains(0))
        let again = try run()
        #expect(again.written == 0)
        #expect(["1900.txt", "2200.txt", "now.txt"].map(inode) == first, "copied again")
        #expect(!PlainCopyLayout.isOpen(folder))

        try put(src, "1900.txt", "changed", date: -2_208_988_800)
        let changed = try run()
        #expect(changed.written == 1)
        #expect((try? String(contentsOf: folder.appendingPathComponent("Old/1900.txt"), encoding: .utf8)) == "changed")
        var st = stat()
        #expect(lstat(folder.appendingPathComponent("Old/1900.txt").path, &st) == 0 && st.st_mtimespec.tv_sec == -2_082_758_400)
    }

    // MARK: Removed items

    @Test func eachDeletionGetsANameOfItsOwn() throws {
        #expect(RemovedItems.numbered("report.txt", 1) == "report.txt")
        #expect(RemovedItems.numbered("report.txt", 2) == "report (2).txt")
        #expect(RemovedItems.numbered("notes", 3) == "notes (3)")
        #expect(RemovedItems.numbered(".profile", 2) == ".profile (2)")
        #expect(RemovedItems.numbered(".backup.2026100201", 2) == ".backup (2).2026100201")

        let day = tempDir("place").appendingPathComponent("2026-10-02")
        defer { try? FileManager.default.removeItem(at: day.deletingLastPathComponent()) }
        try put(day, "notes", "a file")
        try put(day, "a/report.txt", "first")
        #expect(try RemovedItems.place("a/report.txt", in: day).path.hasSuffix("2026-10-02/a/report (2).txt"))
        let under = try RemovedItems.place("notes/x.txt", in: day)
        #expect(under.path.hasSuffix("2026-10-02/notes (2)/x.txt"))
        // a second file of that folder goes beside the first
        try put(day, "notes (2)/x.txt", "x")
        #expect(try RemovedItems.place("notes/y.txt", in: day).path.hasSuffix("2026-10-02/notes (2)/y.txt"))
        // what a stopped run kept is found again, under whichever name it took
        let item = try put(day.deletingLastPathComponent().appendingPathComponent("copy"), "notes/x.txt", "x")
        #expect(RemovedItems.alreadyKept(item, as: "notes/x.txt", in: day))
        try put(day.deletingLastPathComponent().appendingPathComponent("copy"), "notes/x.txt", "x, changed")
        #expect(!RemovedItems.alreadyKept(item, as: "notes/x.txt", in: day))
    }

    // MARK: read-only folders on a Mac drive

    // On a Mac drive a read-only folder stays read-only in the copy: a file and a
    // folder added to it, and one of its folders renamed in capitals, all go in, and
    // it is read-only again after.
    @Test func itemsAddedToAReadOnlyFolderOnAMacDrive() throws {
        let base = tempDir("roadd")
        defer {
            _ = try? ProcessCommandRunner().run("/bin/chmod", ["-R", "u+w", base.path], stdin: nil)
            try? FileManager.default.removeItem(at: base)
        }
        let image = base.appendingPathComponent("drive.dmg"), mount = base.appendingPathComponent("vol", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let made = try ProcessCommandRunner().run("/usr/bin/hdiutil", ["create", "-size", "32m", "-fs", "HFS+", "-volname", "MAC",
                                                                       "-type", "UDIF", image.path], stdin: nil)
        try #require(made.ok, "\(made.stderr)")
        let attached = try DiskImageGate.serialized {
            try ProcessCommandRunner().runRetryingBusy("/usr/bin/hdiutil", ["attach", image.path, "-mountpoint", mount.path, "-nobrowse"])
        }
        try #require(attached.ok, "\(attached.stderr)")
        defer { MountPoint.detach(mount, runner: ProcessCommandRunner()) }

        let src = base.appendingPathComponent("Papers"), folder = mount.appendingPathComponent("Papers-plain")
        func chmod(_ rel: String, _ mode: mode_t) { _ = Darwin.chmod(src.appendingPathComponent(rel).path, mode) }
        func run() throws -> PlainCopyOutcome {
            try PlainCopy(profile: FileSystemProfile.of(folder), runner: ProcessCommandRunner()).run(src, in: folder)
        }
        try put(src, "ro/a.txt", "a")
        try put(src, "ro/sub/b.txt", "b")
        chmod("ro/sub", 0o555)
        chmod("ro", 0o555)
        _ = try run()

        chmod("ro", 0o755); chmod("ro/sub", 0o755)
        try put(src, "ro/new.txt", "new")
        try put(src, "ro/newer/c.txt", "c")
        try FileManager.default.moveItem(at: src.appendingPathComponent("ro/sub"), to: src.appendingPathComponent("ro/x"))
        try FileManager.default.moveItem(at: src.appendingPathComponent("ro/x"), to: src.appendingPathComponent("ro/SUB"))
        chmod("ro/SUB", 0o555); chmod("ro", 0o555)
        let out = try run()
        #expect(out.written >= 2)
        let copy = folder.appendingPathComponent("Papers")
        #expect((try? String(contentsOf: copy.appendingPathComponent("ro/new.txt"), encoding: .utf8)) == "new")
        #expect((try? String(contentsOf: copy.appendingPathComponent("ro/newer/c.txt"), encoding: .utf8)) == "c")
        #expect(PlainCopy.list(copy.appendingPathComponent("ro").path).contains("SUB"))
        for rel in ["ro", "ro/SUB"] {
            var st = stat()
            #expect(lstat(copy.appendingPathComponent(rel).path, &st) == 0 && st.st_mode & 0o7777 == 0o555, "\(rel)")
        }
        #expect(!PlainCopyLayout.isOpen(folder))
    }

    // MARK: Find a File

    // A match kept in Removed items says when it was removed from the library, and
    // opens where it is kept, beside the copy.
    @Test func aMatchInRemovedItemsSaysWhenAndOpensWhereItIs() throws {
        let base = tempDir("findkept")
        defer { try? FileManager.default.removeItem(at: base) }
        let src = base.appendingPathComponent("src/Taxes")
        try put(src, "2024/W-2.pdf", "w2")
        try put(src, "keep.txt", "k")
        let dest = base.appendingPathComponent("dest")
        let lib = ContentType.genericFolder(id: "taxes", displayName: "Taxes", path: .absolute(src.path))
        let job = BackupJob(name: "T", libraries: [lib], target: .localVolume(id: "d", name: "Disk", dir: dest),
                            format: .plainFiles, frequency: .manual, createdAt: Date())
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
        let r = try #require(ContentsSearch().search(ContentsQuery("W-2")!, in: a, passphrases: { _ in [] }))
        let hit = try #require(r.hits.first)
        #expect(r.hits.count == 1)
        #expect(hit.path == "2024/W-2.pdf")
        #expect(hit.removedOn != nil)
        let at = ArchiveLayout.item(hit, in: a.dir, for: a)
        #expect((try? String(contentsOf: at, encoding: .utf8)) == "w2", "\(at.path)")
        // a match in the copy opens in the copy, as before
        let live = try #require(ContentsSearch().search(ContentsQuery("keep.txt")!, in: a, passphrases: { _ in [] })?.hits.first)
        #expect(live.removedOn == nil)
        #expect(ArchiveLayout.item(live, in: a.dir, for: a).path.hasSuffix("/Taxes/keep.txt"))
    }

    // What a run moves into Removed items is recorded as it goes, and Find a File
    // reads that record instead of walking every day's folders. A folder made only
    // to keep a deleted file's path isn't a match; a folder deleted whole is, with
    // all it held. A day the record doesn't hold, or one a run was cut off while
    // moving items into, is walked as before; the next run's record takes it in.
    @Test func removedItemsAreRecordedAsTheyAreMoved() throws {
        try removedItemsAreRecorded(profile: exfatLike)
    }

    // the same for a copy swapped in whole (a Mac's own drive), whose deleted items
    // are cloned into Removed items
    @Test func removedItemsAreRecordedWhenTheCopyIsSwapped() throws {
        let apfs = FileSystemProfile(kind: .apfs, fsType: "apfs")
        #expect(apfs.swapsWholeCopy)
        try removedItemsAreRecorded(profile: apfs)
    }

    private func removedItemsAreRecorded(profile: FileSystemProfile) throws {
        let base = tempDir("findindex")
        defer { try? FileManager.default.removeItem(at: base) }
        let src = base.appendingPathComponent("src/Taxes")
        try put(src, "2024/W-2.pdf", "w2")
        try put(src, "2024/keep.txt", "k")
        try put(src, "old/a.txt", "a")
        try put(src, "old/deeper/b.txt", "b")
        let dest = base.appendingPathComponent("dest")
        let lib = ContentType.genericFolder(id: "taxes", displayName: "Taxes", path: .absolute(src.path))
        let job = BackupJob(name: "T", libraries: [lib], target: .localVolume(id: "d", name: "Disk", dir: dest),
                            format: .plainFiles, frequency: .manual, createdAt: Date())
        func once() throws {
            let prepared = try LibraryFolders.prepare(job: job, library: lib, in: dest, jobs: [job])
            _ = try JobExecutor.plainFiles(job: job, library: lib, source: ArchiveSource(name: "Taxes", root: src), folder: prepared.folder,
                                           target: job.target, profile: profile, bytes: 10, partial: false, now: Date(),
                                           runner: ProcessCommandRunner())
        }
        try once()
        try FileManager.default.removeItem(at: src.appendingPathComponent("2024/W-2.pdf"))
        try FileManager.default.removeItem(at: src.appendingPathComponent("old"))
        try once()
        let a = try #require(RestoreDiscovery.scan(dest).first)
        // found again for each search: a run's new list is another file
        func removedHits(_ q: String) throws -> [String] {
            let now = try #require(RestoreDiscovery.scan(dest).first)
            let r = try #require(ContentsSearch().search(ContentsQuery(q)!, in: now, passphrases: { _ in [] }))
            guard case .listed(let hits, _, _) = r.answer else { return ["not listed"] }
            return hits.filter { $0.removedOn != nil }.map(\.path).sorted()
        }
        #expect(try removedHits("2024").isEmpty, "the folder made to keep its path is a match")
        #expect(try removedHits("W-2") == ["2024/W-2.pdf"])
        #expect(try removedHits("old") == ["old"])
        #expect(try removedHits("deeper") == ["old/deeper"])
        #expect(try removedHits("a.txt") == ["old/a.txt"])
        #expect(try removedHits("b.txt") == ["old/deeper/b.txt"])

        // the record is what is read: an item put there by hand isn't found ...
        let removed = a.dir.appendingPathComponent(PlainCopyLayout.removedFolder)
        let day = try #require(RemovedItems.days(in: removed).first?.folder)
        try put(day, "stray.txt", "s")
        #expect(try removedHits("stray").isEmpty)
        // ... until the day is one a run was cut off in, which is walked
        var index = try #require(RemovedItemsIndex.read(removed))
        index.pending = day.lastPathComponent
        try index.write(removed)
        #expect(try removedHits("stray") == ["stray.txt"])
        // and the next run that moves something takes it in
        try FileManager.default.removeItem(at: src.appendingPathComponent("2024/keep.txt"))
        try once()
        let after = try #require(RemovedItemsIndex.read(removed))
        #expect(after.pending == nil)
        #expect(try removedHits("stray") == ["stray.txt"])
        #expect(try removedHits("keep") == ["2024/keep.txt"])
        // a day deleted in Storage is gone from the search, and with every day gone
        // Removed items goes too, record and all
        RemovedItems.delete(in: removed, before: nil)
        #expect(try removedHits("W-2").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: removed.path))
        #expect(RemovedItemsIndex.read(removed) == nil)
    }
}
