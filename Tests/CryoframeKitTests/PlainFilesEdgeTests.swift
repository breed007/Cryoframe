//
//  PlainFilesEdgeTests.swift
//  CryoframeKitTests
//
//  The plain-files format where it is likeliest to go wrong: dates exFAT can't hold,
//  a name deleted twice in a day, a name kept in Removed items as a file and then as
//  a folder, a library file named like rsync's temporary files, read-only folders on
//  Mac drives, Finder's litter and a folder renamed in capitals on a real exFAT drive,
//  the allocation probe on a real FAT32 drive, Stop while deleted items are kept,
//  Find a File for a deleted file and after a stopped update, and a restore over the
//  live folder from a copy on exFAT.
//

import Testing
import Foundation
@testable import CryoframeKit

private func realTemp(_ tag: String) -> URL {
    let d = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        .appendingPathComponent("cf-plainedge-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
    return realpath(d.path, &buf) != nil ? URL(fileURLWithPath: String(cString: buf), isDirectory: true) : d
}

/// A drive of `fs` ("ExFAT", "MS-DOS FAT32", "HFS+") in a disk image, mounted under `base`.
private func drive(_ fs: String, mb: Int, in base: URL) throws -> (mount: URL, detach: () -> Void) {
    let image = base.appendingPathComponent("drive-\(UUID().uuidString).dmg")
    let mount = base.appendingPathComponent("vol-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
    let made = try ProcessCommandRunner().run("/usr/bin/hdiutil", ["create", "-size", "\(mb)m", "-fs", fs, "-volname", "CARD",
                                                                   "-type", "UDIF", "-layout", "MBRSPUD", image.path], stdin: nil)
    try #require(made.ok, "couldn't make the drive: \(made.stderr)")
    let attached = try DiskImageGate.serialized {
        try ProcessCommandRunner().runRetryingBusy("/usr/bin/hdiutil", ["attach", image.path, "-mountpoint", mount.path, "-nobrowse"])
    }
    try #require(attached.ok, "couldn't attach the drive: \(attached.stderr)")
    return (mount, { MountPoint.detach(mount, runner: ProcessCommandRunner()) })
}

@discardableResult
private func put(_ root: URL, _ rel: String, _ text: String, date: TimeInterval = 1_700_000_000) throws -> URL {
    let url = root.appendingPathComponent(rel)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
    var times = [timespec(tv_sec: Int(date), tv_nsec: 0), timespec(tv_sec: Int(date), tv_nsec: 0)]
    _ = utimensat(AT_FDCWD, url.path, &times, 0)
    return url
}

private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

/// every path under `root` as the drive lists them ("._" files and all)
private func tree(_ root: URL) -> [String] {
    var out: [String] = []
    func walk(_ rel: String) {
        for name in PlainCopy.list(rel.isEmpty ? root.path : root.appendingPathComponent(rel).path).sorted() {
            let r = rel.isEmpty ? name : rel + "/" + name
            out.append(r)
            var st = stat()
            if lstat(root.appendingPathComponent(r).path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR { walk(r) }
        }
    }
    walk("")
    return out
}

/// the contents of every file under `root`'s Removed items, whatever day and name
private func removedContents(_ folder: URL) -> [String] {
    let removed = folder.appendingPathComponent(PlainCopyLayout.removedFolder)
    return tree(removed).compactMap { rel -> String? in
        var st = stat()
        let url = removed.appendingPathComponent(rel)
        guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, !url.lastPathComponent.hasPrefix("._") else { return nil }
        return read(url)
    }.sorted()
}

/// exFAT's rules on the startup disk (updated in place), and APFS's (swapped in whole)
private let exfatLike = FileSystemProfile(kind: .exfat, fsType: "exfat", foldsCase: true, cluster: 4096, companions: false)
private let apfsLike = FileSystemProfile(kind: .apfs, fsType: "apfs", foldsCase: true, cluster: 4096, companions: false)

private let today = Date(timeIntervalSince1970: 1_800_000_000)

private func plainCopy(_ profile: FileSystemProfile, control: RunControl = RunControl()) -> PlainCopy {
    var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
    return PlainCopy(profile: profile, runner: ProcessCommandRunner(control: control), now: today, calendar: utc,
                     freeSpace: { _ in .max }, companions: false, accepts: { _ in true })
}

/// a real drive's run, with the drive's own profile and probe
private func driveRun(_ src: URL, _ folder: URL, control: RunControl = RunControl()) throws -> PlainCopyOutcome {
    var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
    return try PlainCopy(profile: FileSystemProfile.of(folder), runner: ProcessCommandRunner(control: control), now: today,
                         calendar: utc).run(src, in: folder)
}

private func cancel(at title: String) -> RunControl {
    let control = RunControl()
    control.stepChanged = { _, step in if step.title == title { control.cancel() } }
    return control
}

@Suite(.serialized) struct PlainFilesEdgeTests {

    // MARK: dates

    // exFAT (and FAT32) hold dates from 1980 to 2107 only. Measured on macOS 27 FSKit:
    // a file dated 1970 is stored as 1980-01-01, one dated 2200 as 2063 (wrapped). The
    // read-back compares each file's date with the library's, so one such file would
    // fail every run with "didn't match", and nothing would ever move to Removed items.
    @Test func aFileDatedOutsideWhatExFATHoldsDoesNotFailEveryRun() throws {
        let base = realTemp("dates")
        defer { try? FileManager.default.removeItem(at: base) }
        let (mount, detach) = try drive("ExFAT", mb: 64, in: base)
        defer { detach() }
        let src = base.appendingPathComponent("Downloads")
        try put(src, "unzipped/readme.txt", "dated 1970 by the zip it came in", date: 0)
        try put(src, "future.txt", "a clock set wrong", date: 7_258_118_400)
        try put(src, "fine.txt", "fine")
        let folder = mount.appendingPathComponent("Downloads-plain")

        do {
            _ = try driveRun(src, folder)
        } catch {
            Issue.record("the first run failed: \(error.localizedDescription)")
        }
        do {
            let again = try driveRun(src, folder)
            #expect(again.written == 0, "every run copies them again: \(again.written)")
        } catch {
            Issue.record("the second run failed too: \(error.localizedDescription)")
        }
        #expect(read(folder.appendingPathComponent("Downloads/unzipped/readme.txt")) == "dated 1970 by the zip it came in")
        #expect(!PlainCopyLayout.isOpen(folder), "every run ends stopped part way")
    }

    // MARK: Removed items

    // "Nothing is deleted": a file deleted, made again and deleted again on the same
    // day is two files the library held. Both are kept, whichever way the copy is made.
    @Test(arguments: ["in place", "swapped"])
    func aNameDeletedTwiceInADayKeepsBothFiles(_ how: String) throws {
        let base = realTemp("twice")
        defer { try? FileManager.default.removeItem(at: base) }
        let profile = how == "swapped" ? apfsLike : exfatLike
        let src = base.appendingPathComponent("Work"), folder = base.appendingPathComponent("dest")
        try put(src, "keep.txt", "k")
        try put(src, "report.txt", "first report")
        _ = try plainCopy(profile).run(src, in: folder)
        try FileManager.default.removeItem(at: src.appendingPathComponent("report.txt"))
        _ = try plainCopy(profile).run(src, in: folder)
        try put(src, "report.txt", "second report, not the first", date: 1_700_000_500)
        _ = try plainCopy(profile).run(src, in: folder)
        try FileManager.default.removeItem(at: src.appendingPathComponent("report.txt"))
        let out = try plainCopy(profile).run(src, in: folder)

        #expect(out.removed == 1)
        #expect(removedContents(folder) == ["first report", "second report, not the first"],
                "\(how): Removed items holds \(tree(folder.appendingPathComponent(PlainCopyLayout.removedFolder)))")
    }

    // A file "notes" deleted (kept as Removed items/<day>/notes), then a folder "notes"
    // made, and a file in it deleted, the same day: the second can't go under a file.
    @Test(arguments: ["in place", "swapped"])
    func aFolderDeletedWhereAFileOfItsNameWasKeptTheSameDay(_ how: String) throws {
        let base = realTemp("fileThenFolder")
        defer { try? FileManager.default.removeItem(at: base) }
        let profile = how == "swapped" ? apfsLike : exfatLike
        let src = base.appendingPathComponent("Work"), folder = base.appendingPathComponent("dest")
        try put(src, "keep.txt", "k")
        try put(src, "notes", "a file called notes")
        _ = try plainCopy(profile).run(src, in: folder)
        try FileManager.default.removeItem(at: src.appendingPathComponent("notes"))
        _ = try plainCopy(profile).run(src, in: folder)
        try put(src, "notes/a.txt", "inside the folder called notes")
        _ = try plainCopy(profile).run(src, in: folder)
        try FileManager.default.removeItem(at: src.appendingPathComponent("notes/a.txt"))

        do {
            _ = try plainCopy(profile).run(src, in: folder)
        } catch {
            Issue.record("\(how): the run failed, and fails all day: \(error.localizedDescription)")
        }
        #expect(removedContents(folder) == ["a file called notes", "inside the folder called notes"])
        #expect(!PlainCopyLayout.isOpen(folder))
    }

    // A library file named ".<sibling>.<10 letters or digits>" is the library's, not a
    // temporary file rsync left: deleted from the library, it is kept, not unlinked.
    @Test func aLibraryFileNamedLikeAnRsyncTemporaryIsKeptWhenDeleted() throws {
        let base = realTemp("tempname")
        defer { try? FileManager.default.removeItem(at: base) }
        let src = base.appendingPathComponent("Work"), folder = base.appendingPathComponent("dest")
        try put(src, "backup", "b")
        try put(src, ".backup.2026100201", "the 1 a.m. backup's notes")
        _ = try plainCopy(exfatLike).run(src, in: folder)
        #expect(read(folder.appendingPathComponent("Work/.backup.2026100201")) == "the 1 a.m. backup's notes")

        try FileManager.default.removeItem(at: src.appendingPathComponent(".backup.2026100201"))
        _ = try plainCopy(exfatLike).run(src, in: folder)
        #expect(removedContents(folder) == ["the 1 a.m. backup's notes"], "deleted outright, not kept")
    }

    // Stop as deleted items are being kept: nothing is lost, the mark stays (in place)
    // or the previous copy stays (swapped), and the next run keeps them.
    @Test(arguments: ["in place", "swapped"])
    func stopWhileDeletedItemsAreKept(_ how: String) throws {
        let base = realTemp("stopRemoved")
        defer { try? FileManager.default.removeItem(at: base) }
        let profile = how == "swapped" ? apfsLike : exfatLike
        let src = base.appendingPathComponent("Work"), folder = base.appendingPathComponent("dest")
        for i in 0..<6 { try put(src, "d/f\(i).txt", "file \(i)") }
        try put(src, "keep.txt", "k")
        _ = try plainCopy(profile).run(src, in: folder)
        for i in 0..<6 { try FileManager.default.removeItem(at: src.appendingPathComponent("d/f\(i).txt")) }

        let control = cancel(at: "Moving deleted items to Removed items")
        #expect(throws: CancelledError.self) { _ = try plainCopy(profile, control: control).run(src, in: folder) }
        if how == "in place" { #expect(PlainCopyLayout.isOpen(folder)) }
        let copy = folder.appendingPathComponent("Work/d")
        let stillThere = (0..<6).filter { FileManager.default.fileExists(atPath: copy.appendingPathComponent("f\($0).txt").path) }.count
        #expect(stillThere + removedContents(folder).count == 6, "\(how): an item is in neither place")

        _ = try plainCopy(profile).run(src, in: folder)
        #expect(removedContents(folder) == (0..<6).map { "file \($0)" })
        #expect(!PlainCopyLayout.isOpen(folder))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(PlainCopyLayout.staging).path))
    }

    // MARK: read-only items on Mac drives

    // A folder its owner can't write to (0555) and a 0444 file, kept as they are on a
    // Mac drive: changed, then a file in the folder deleted. Updated in place on Mac OS
    // Extended (real drive), swapped in whole on APFS.
    @Test(arguments: ["HFS+", "APFS"])
    func readOnlyFoldersAndFilesOnAMacDrive(_ fs: String) throws {
        let base = realTemp("readonly")
        defer {
            _ = try? ProcessCommandRunner().run("/bin/chmod", ["-R", "u+w", base.path], stdin: nil)
            try? FileManager.default.removeItem(at: base)
        }
        var detach: () -> Void = {}
        defer { detach() }
        let folder: URL
        let src = base.appendingPathComponent("Papers")
        if fs == "HFS+" {
            let d = try drive("HFS+", mb: 64, in: base)
            detach = d.detach
            folder = d.mount.appendingPathComponent("Papers-plain")
        } else {
            folder = base.appendingPathComponent("dest")
        }
        func chmod(_ rel: String, _ mode: mode_t) { _ = Darwin.chmod(src.appendingPathComponent(rel).path, mode) }
        func run() throws -> PlainCopyOutcome {
            fs == "HFS+" ? try driveRun(src, folder) : try plainCopy(apfsLike).run(src, in: folder)
        }
        try put(src, "ro/a.txt", "a1")
        try put(src, "ro/b.txt", "b1")
        try put(src, "locked.txt", "l1")
        chmod("locked.txt", 0o444)
        chmod("ro", 0o555)
        do { _ = try run() } catch { Issue.record("\(fs) first run: \(error.localizedDescription)"); return }

        try put(src, "ro/a.txt", "a2, longer", date: 1_700_000_600)
        chmod("locked.txt", 0o644)
        try put(src, "locked.txt", "l2, longer", date: 1_700_000_600)
        chmod("locked.txt", 0o444)
        do { _ = try run() } catch { Issue.record("\(fs) changed run: \(error.localizedDescription)") }
        #expect(read(folder.appendingPathComponent("Papers/ro/a.txt")) == "a2, longer")
        #expect(read(folder.appendingPathComponent("Papers/locked.txt")) == "l2, longer")

        chmod("ro", 0o755)
        try FileManager.default.removeItem(at: src.appendingPathComponent("ro/b.txt"))
        chmod("ro", 0o555)
        do { _ = try run() } catch { Issue.record("\(fs) run after a deletion: \(error.localizedDescription)") }
        #expect(removedContents(folder) == ["b1"], "\(fs): \(tree(folder))")
        #expect(!PlainCopyLayout.isOpen(folder))
    }

    // MARK: real exFAT

    // Finder's own files in the copy (after Show in Finder), the library's own
    // .DS_Store, and a folder renamed in capitals with a file in it deleted, in one run.
    @Test func finderLitterAndAFolderRenamedInCapitalsOnExFAT() throws {
        let base = realTemp("litter")
        defer { try? FileManager.default.removeItem(at: base) }
        let (mount, detach) = try drive("ExFAT", mb: 64, in: base)
        defer { detach() }
        let src = base.appendingPathComponent("Pictures"), folder = mount.appendingPathComponent("Pictures-plain")
        try put(src, "Album/a.jpg", "a")
        try put(src, "Album/b.jpg", "b")
        try put(src, ".DS_Store", "the library's own")
        _ = try driveRun(src, folder)

        let copy = folder.appendingPathComponent("Pictures")
        try put(copy, ".DS_Store", "Finder rewrote it, and it is longer now", date: 1_800_000_000)
        try put(copy, "Album/.DS_Store", "Finder's, not the library's", date: 1_800_000_000)
        try put(copy, "Album/._.DS_Store", "its companion", date: 1_800_000_000)
        try FileManager.default.moveItem(at: src.appendingPathComponent("Album"), at2: src.appendingPathComponent("ALBUM"))
        try FileManager.default.removeItem(at: src.appendingPathComponent("ALBUM/b.jpg"))

        let out = try driveRun(src, folder)
        #expect(PlainCopy.list(copy.path).contains("ALBUM"), "\(tree(copy))")
        #expect(read(copy.appendingPathComponent("ALBUM/a.jpg")) == "a")
        #expect(read(copy.appendingPathComponent(".DS_Store")) == "the library's own")
        #expect(removedContents(folder) == ["b"], "\(tree(folder))")
        #expect(out.removed == 1)
        #expect(try driveRun(src, folder).written == 0)
    }

    // MARK: room

    // The allocation probe on a real FAT32 drive (512-byte clusters): measured, so the
    // room check isn't sized at 128 KiB a file.
    @Test func theProbeMeasuresAFAT32DriveAndRoomIsAskedInItsClusters() throws {
        let base = realTemp("fat32room")
        defer { try? FileManager.default.removeItem(at: base) }
        let (mount, detach) = try drive("MS-DOS FAT32", mb: 100, in: base)
        defer { detach() }
        var s = statfs()
        try #require(statfs(mount.path, &s) == 0)
        let probed = DriveAllocation.probe(at: mount)
        #expect(probed.allocationUnit != nil, "unmeasured on FAT32: 128 KiB is assumed for every file")
        #expect(probed.allocationUnit == UInt64(s.f_bsize))

        let src = base.appendingPathComponent("Notes")
        for i in 0..<200 { try put(src, "n\(i).txt", "note \(i)") }
        let folder = mount.appendingPathComponent("Notes-plain")
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let pc = PlainCopy(profile: FileSystemProfile.of(folder), runner: ProcessCommandRunner(), now: today, calendar: utc,
                           freeSpace: { _ in 1 })
        do {
            _ = try pc.run(src, in: folder)
            Issue.record("no room check")
        } catch PlainCopyError.notEnoughRoom(let needed, _, _) {
            // 200 files of one cluster, each with a 4 KB companion, and a folder
            #expect(needed < 2_000_000, "asked \(needed) bytes for 200 tiny files on 512-byte clusters")
        }
    }

    // MARK: Find a File

    // What was deleted from the library is kept in Removed items. Find a File must
    // not say a file kept there is "not in" the backup.
    @Test func findAFileDoesNotSayADeletedFileIsGone() throws {
        let base = realTemp("findRemoved")
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
        #expect(removedContents(a.dir) == ["w2"])

        let r = try #require(ContentsSearch().search(ContentsQuery("W-2")!, in: a, passphrases: { _ in [] }))
        #expect(!r.isNotInVersion, "says \(ContentsSearch.summary([r], of: 1)) while Removed items holds it")
    }

    // A stopped update leaves the list of the update before. A file this update copied
    // isn't in it: Find a File mustn't say for sure that it isn't there.
    @Test func findAFileAfterAStoppedUpdateIsntSure() throws {
        let base = realTemp("findStopped")
        defer { try? FileManager.default.removeItem(at: base) }
        let src = base.appendingPathComponent("src/Taxes")
        try put(src, "keep.txt", "k")
        let dest = base.appendingPathComponent("dest")
        let lib = ContentType.genericFolder(id: "taxes", displayName: "Taxes", path: .absolute(src.path))
        let job = BackupJob(name: "T", libraries: [lib], target: .localVolume(id: "d", name: "Disk", dir: dest),
                            format: .plainFiles, frequency: .manual, createdAt: Date())
        func once(_ control: RunControl = RunControl()) throws {
            let prepared = try LibraryFolders.prepare(job: job, library: lib, in: dest, jobs: [job])
            _ = try JobExecutor.plainFiles(job: job, library: lib, source: ArchiveSource(name: "Taxes", root: src), folder: prepared.folder,
                                           target: job.target, profile: exfatLike, bytes: 10, partial: false, now: Date(),
                                           runner: ProcessCommandRunner(control: control))
        }
        try once()
        try put(src, "2025/1099.pdf", "new this year")
        #expect(throws: CancelledError.self) { try once(cancel(at: "Checking the copy")) }
        let a = try #require(RestoreDiscovery.scan(dest).first)
        #expect(PlainCopyLayout.isOpen(a.dir))
        #expect(FileManager.default.fileExists(atPath: a.dir.appendingPathComponent("Taxes/2025/1099.pdf").path))

        let r = try #require(ContentsSearch().search(ContentsQuery("1099")!, in: a, passphrases: { _ in [] }))
        #expect(!r.isNotInVersion, "says \(ContentsSearch.summary([r], of: 1)) while the copy holds it")
    }

    // MARK: restore

    // A copy on exFAT restored over its live folder, as Restore's in place does: made
    // beside it, then swapped in. What comes back is the library as it was copied:
    // no "._" files, no Removed items, nothing of Cryoframe's.
    @Test func aCopyOnExFATRestoredOverTheLiveFolder() throws {
        let base = realTemp("restoreLive")
        defer { try? FileManager.default.removeItem(at: base) }
        let (mount, detach) = try drive("ExFAT", mb: 64, in: base)
        defer { detach() }
        let home = base.appendingPathComponent("home")
        let live = home.appendingPathComponent("Projects")
        try put(live, "plan.txt", "the plan")
        try put(live, "site/index.html", "<p>hi</p>", date: 1_600_000_001)
        try put(live, "gone.txt", "deleted later")
        try FileManager.default.createSymbolicLink(atPath: live.appendingPathComponent("latest").path, withDestinationPath: "site/index.html")
        let lib = ContentType.genericFolder(id: "projects", displayName: "Projects", path: .absolute(live.path))
        let job = BackupJob(name: "P", libraries: [lib], target: .localVolume(id: "card", name: "CARD", dir: mount),
                            format: .plainFiles, frequency: .manual, createdAt: Date())
        func once() throws {
            let prepared = try LibraryFolders.prepare(job: job, library: lib, in: mount, jobs: [job])
            let (result, _) = try JobExecutor.plainFiles(job: job, library: lib, source: ArchiveSource(name: "Projects", root: live),
                                                         folder: prepared.folder, target: job.target, profile: FileSystemProfile.of(prepared.folder),
                                                         bytes: 10, partial: false, now: Date(), runner: ProcessCommandRunner())
            guard case .completed = result else { Issue.record("not completed: \(result)"); return }
        }
        try once()
        try FileManager.default.removeItem(at: live.appendingPathComponent("gone.txt"))
        try once()
        let backedUp = tree(live)

        // the live folder goes on: a file changed, one added
        try put(live, "plan.txt", "a worse plan", date: 1_800_000_000)
        try put(live, "scratch.txt", "junk")

        let a = try #require(RestoreDiscovery.scan(mount).first)
        #expect(a.format == .plainFiles)
        let staging = home.appendingPathComponent(".cryoframe-restore-test", isDirectory: true)
        let restored = try RestoreEngine().restore(a, to: staging, verify: true, inPlace: true)
        try FileManager.default.moveItem(at: live, to: home.appendingPathComponent("Projects (old)"))
        try FileManager.default.moveItem(at: restored, to: live)

        #expect(tree(live) == backedUp, "restored \(tree(live)), backed up \(backedUp)")
        #expect(read(live.appendingPathComponent("plan.txt")) == "the plan")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: live.appendingPathComponent("latest").path) == "site/index.html")
        var st = stat()
        #expect(lstat(live.appendingPathComponent("site/index.html").path, &st) == 0 && st.st_mtimespec.tv_sec == 1_600_000_001)
        #expect(!tree(live).contains { $0.hasPrefix("._") || $0.contains("/._") || $0.hasPrefix(".cryoframe") || $0.contains(PlainCopyLayout.removedFolder) })
    }
}

private extension FileManager {
    /// a rename through a temporary name, as Finder does one in capitals only
    func moveItem(at from: URL, at2 to: URL) throws {
        let temp = from.deletingLastPathComponent().appendingPathComponent(".rename-\(UUID().uuidString)")
        try moveItem(at: from, to: temp)
        try moveItem(at: temp, to: to)
    }
}
