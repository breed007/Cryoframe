//
//  PlainCopyTests.swift
//  CryoframeKitTests
//
//  The plain-files format on the startup disk: the plan (what a run will copy, rename,
//  set aside and leave out), an update in place as on a drive that isn't a Mac's, and
//  a copy swapped in whole as on APFS. Real exFAT and FAT32 drives are in
//  PlainCopyDriveTests.
//

import Testing
import Foundation
@testable import CryoframeKit

private func tempDir(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-plain-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
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

/// exFAT's rules on the startup disk: in place, no Mac details, case folded
private let exfatLike = FileSystemProfile(kind: .exfat, fsType: "exfat", foldsCase: true, cluster: 4096, companions: false)

private func plainCopy(_ profile: FileSystemProfile = exfatLike, control: RunControl = RunControl(),
                       free: UInt64? = nil, now: Date = Date(timeIntervalSince1970: 1_800_000_000),
                       accepts: @escaping (String) -> Bool = { _ in true }) -> PlainCopy {
    var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
    return PlainCopy(profile: profile, runner: ProcessCommandRunner(control: control), now: now, calendar: utc,
                     freeSpace: { _ in free ?? .max }, companions: false, accepts: accepts, batchFiles: 3)
}

/// every path under `root`, as the drive lists them ("._" files and all)
private func tree(_ root: URL) -> [String] {
    var out: [String] = []
    func walk(_ rel: String) {
        for name in PlainCopy.list(rel.isEmpty ? root.path : root.appendingPathComponent(rel).path).sorted() {
            let r = rel.isEmpty ? name : rel + "/" + name
            out.append(r)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: root.appendingPathComponent(r).path, isDirectory: &isDir), isDir.boolValue { walk(r) }
        }
    }
    walk("")
    return out
}

/// the steps a run went through, in order
private final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var begun: [String] = []
    var onBegin: ((String) -> Void)?
    func follow(_ control: RunControl) {
        control.stepChanged = { _, step in
            self.lock.lock(); self.begun.append(step.title); let f = self.onBegin; self.lock.unlock()
            f?(step.title)
        }
    }
    var titles: [String] { lock.lock(); defer { lock.unlock() }; return begun }
}

@Suite struct PlainCopyPlanTests {

    // Of two library items the drive can't tell apart, the one the copy already holds
    // is kept, every run; in a new copy, the first by its bytes. A name whose capitals
    // changed is renamed; an item of another kind is set aside; what the library no
    // longer holds is removed; rsync's leftover temporary file is swept.
    @Test func thePlanFoldsNamesAsTheDriveDoes() throws {
        let base = tempDir("plan")
        defer { try? FileManager.default.removeItem(at: base) }
        let src = base.appendingPathComponent("src"), copy = base.appendingPathComponent("copy")
        try put(src, "Report.txt", "newer")
        try put(src, "Notes/a.txt", "a")
        try put(src, "kind", "now a file")
        try put(src, "big.bin", "x")
        try put(copy, "report.TXT", "old")
        try put(copy, "notes/a.txt", "a")
        try put(copy, "kind/inner.txt", "was a folder")
        try put(copy, "gone.txt", "deleted from the library")
        try put(copy, ".Report.txt.o4stnEmcy9", "rsync's leftover")
        try put(copy, ".gone.txt.notatempname", "a file of the person's")

        // a copy a cut-off run left marked: rsync's temporary files are swept only then
        let planner = PlainCopyPlanner(profile: exfatLike, sweepsTemps: true)
        let plan = try planner.plan(source: src, copy: copy)
        #expect(Set(plan.renames.map { "\($0.from)>\($0.to)" }) == ["notes>Notes", "report.TXT>Report.txt"])
        #expect(plan.replaced == ["kind"])
        #expect(Set(plan.removed) == ["gone.txt", ".gone.txt.notatempname"])
        #expect(plan.temps == [".Report.txt.o4stnEmcy9"])
        #expect(Set(plan.written) == ["Report.txt", "kind", "big.bin"])
        #expect(plan.newFolders.isEmpty)
    }

    // The drive's idea of one name: case folded where the drive folds it, Unicode
    // normalization always (both measured on exFAT and FAT32). Which of two such
    // library items is kept is tested on a real drive (PlainCopyDriveTests), from a
    // case-sensitive library.
    @Test func namesAreComparedAsTheDriveComparesThem() {
        let folds = FileSystemProfile(kind: .exfat, fsType: "exfat", foldsCase: true, companions: false)
        #expect(folds.identity(of: "Apple") == folds.identity(of: "apple"))
        #expect(folds.identity(of: "e\u{301}") == folds.identity(of: "\u{e9}"))
        let keeps = FileSystemProfile(kind: .apfs, fsType: "apfs", foldsCase: false)
        #expect(keeps.identity(of: "A") != keeps.identity(of: "a"))
        #expect(keeps.identity(of: "e\u{301}") == keeps.identity(of: "\u{e9}"))
    }

    // A "._" file beside its namesake isn't copied to a drive that keeps "._"
    // companions (rsync turned it into the namesake's attributes, measured); alone, it
    // is. A file of 4 GiB isn't copied to FAT32, nor a name the drive refuses.
    @Test func itemsTheDriveCantTakeAreLeftOutOneByOne() throws {
        let base = tempDir("refuse")
        defer { try? FileManager.default.removeItem(at: base) }
        let src = base.appendingPathComponent("src")
        try put(src, "X", "x")
        try put(src, "._X", "mine")
        try put(src, "._alone", "mine too")
        try put(src, "a:b", "colon")
        let big = src.appendingPathComponent("huge.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let h = try FileHandle(forWritingTo: big); try h.truncate(atOffset: FileSystemProfile.fat32Limit); try h.close()
        let fat = FileSystemProfile(kind: .fat32, fsType: "msdos", foldsCase: true, cluster: 512, companions: false)
        let plan = try PlainCopyPlanner(profile: fat, accepts: { $0 != "a:b" }).plan(source: src, copy: nil)
        let why = Dictionary(plan.excluded.map { ($0.rel, $0.why) }, uniquingKeysWith: { a, _ in a })
        #expect(why["._X"] == .companionName)
        #expect(why["huge.bin"] == .tooLarge(FileSystemProfile.fat32Limit))
        #expect(why["a:b"] == .nameRefused)
        #expect(why["._alone"] == nil)
        #expect(Set(plan.written) == ["X", "._alone"])
        // a Mac's drive takes all of them
        let mac = try PlainCopyPlanner(profile: FileSystemProfile(kind: .hfs, fsType: "hfs"), accepts: { _ in false })
            .plan(source: src, copy: nil)
        #expect(mac.excluded.isEmpty)
    }

    // A FAT32 folder holds 65,536 directory entries; what doesn't fit isn't copied,
    // those already in the copy first. Counted the way FAT32 counts long names.
    @Test func aFAT32FolderTakesWhatFits() {
        let fat = FileSystemProfile(kind: .fat32, fsType: "msdos", foldsCase: true, cluster: 512, companions: true)
        #expect(fat.fat32Entries("short.txt") == 2 + 2)            // 9 characters, and "._short.txt"
        #expect(fat.fat32Entries(String(repeating: "x", count: 26)) == 3 + 4)
        var noCompanion = fat; noCompanion.companions = false
        #expect(noCompanion.fat32Entries(String(repeating: "x", count: 13)) == 2)
    }

    // The room a run needs: whole clusters, a companion's for each new file and folder
    // when the drive writes them, and only the growth of a changed file (its old room
    // comes back once it is replaced) plus room to write the largest beside its old self.
    @Test func roomIsCountedInTheDrivesClusters() throws {
        let base = tempDir("room")
        defer { try? FileManager.default.removeItem(at: base) }
        let src = base.appendingPathComponent("src"), copy = base.appendingPathComponent("copy")
        try put(src, "new.txt", String(repeating: "n", count: 10))
        try put(src, "dir/grown.txt", String(repeating: "g", count: 200_000), date: 1_700_000_100)
        try put(copy, "dir/grown.txt", String(repeating: "g", count: 100))
        let card = FileSystemProfile(kind: .exfat, fsType: "exfat", foldsCase: true, cluster: 131_072, companions: true)
        let plan = try PlainCopyPlanner(profile: card).plan(source: src, copy: copy)
        let companion: UInt64 = 131_072
        // new.txt: a cluster and its companion; grown.txt: 2 clusters where it had 1,
        // and the 1 it had while both are there
        #expect(plan.room == (131_072 + companion) + 131_072 + 131_072)
        let noCompanions = try PlainCopyPlanner(profile: { var p = card; p.companions = false; return p }()).plan(source: src, copy: copy)
        #expect(noCompanions.room == 131_072 + 131_072 + 131_072)
    }

    @Test func notesNameWhatWasLeftOut() {
        let notes = PlainCopy.notes([("a/Photo.JPG", .sameName(kept: "photo.jpg")), ("b/PHOTO.jpg", .sameName(kept: "photo.jpg")),
                                     ("movie.mov", .tooLarge(5_000_000_000))])
        #expect(notes.count == 2)
        #expect(notes[0].hasPrefix("2 items weren't copied (“a/Photo.JPG”, “b/PHOTO.jpg”): their names differ only in capitals"))
        #expect(notes[1].hasPrefix("1 item wasn't copied (“movie.mov”): too large for this drive"))
    }

    @Test func rsyncTemporaryNames() {
        #expect(PlainCopyPlanner.isTemp(".big.o4stnEmcy9", of: ["big"]))
        #expect(!PlainCopyPlanner.isTemp(".big.o4stnEmcy9", of: ["other"]))
        #expect(!PlainCopyPlanner.isTemp(".big.short", of: ["big"]))
        #expect(PlainCopyPlanner.mightBeRefused("a:b") && PlainCopyPlanner.mightBeRefused("trailing.") && !PlainCopyPlanner.mightBeRefused("plain"))
    }
}

@Suite(.serialized) struct PlainCopyInPlaceTests {

    // A first run copies everything; a second, with nothing changed, copies nothing;
    // a file deleted from the library goes to Removed items under the day, with its
    // folder; a changed file is replaced. No mark is left.
    @Test func runsKeepDeletedItemsAndCopyOnlyWhatChanged() throws {
        let base = tempDir("runs")
        defer { try? FileManager.default.removeItem(at: base) }
        let src = base.appendingPathComponent("Documents"), folder = base.appendingPathComponent("Documents [abc123]")
        try put(src, "a.txt", "a")
        try put(src, "sub/b.txt", "b")
        try put(src, "sub/deep/c.txt", "c")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: src.appendingPathComponent("link").path, withDestinationPath: "a.txt")

        var out = try plainCopy().run(src, in: folder)
        #expect(out.written == 4)
        let copy = folder.appendingPathComponent("Documents")
        #expect(Set(tree(copy)) == ["a.txt", "sub", "sub/b.txt", "sub/deep", "sub/deep/c.txt", "empty", "link"])
        #expect(!PlainCopyLayout.isOpen(folder))

        out = try plainCopy().run(src, in: folder)
        #expect(out.written == 0)
        #expect(out.removed == 0)

        try FileManager.default.removeItem(at: src.appendingPathComponent("sub/deep"))
        try put(src, "a.txt", "changed", date: 1_700_000_500)
        out = try plainCopy().run(src, in: folder)
        #expect(out.written == 1)
        #expect(out.removed == 1)
        #expect(try String(contentsOf: copy.appendingPathComponent("a.txt"), encoding: .utf8) == "changed")
        let removed = folder.appendingPathComponent("Removed items/2027-01-15/sub/deep/c.txt")
        #expect(try String(contentsOf: removed, encoding: .utf8) == "c")
        #expect(!FileManager.default.fileExists(atPath: copy.appendingPathComponent("sub/deep").path))
    }

    // A name whose capitals changed in the library is renamed in the copy, not set
    // aside in Removed items (a live file mistaken for a deleted one).
    @Test func aRenameOfCapitalsIsARenameNotARemoval() throws {
        let base = tempDir("caps")
        defer { try? FileManager.default.removeItem(at: base) }
        let src = base.appendingPathComponent("Lib"), folder = base.appendingPathComponent("Lib")
            .deletingLastPathComponent().appendingPathComponent("dest")
        try put(src, "Folder/photo.jpg", "p")
        _ = try plainCopy().run(src, in: folder)
        try FileManager.default.moveItem(at: src.appendingPathComponent("Folder"), to: src.appendingPathComponent("FOLDER-tmp"))
        try FileManager.default.moveItem(at: src.appendingPathComponent("FOLDER-tmp"), to: src.appendingPathComponent("FOLDER"))
        try FileManager.default.moveItem(at: src.appendingPathComponent("FOLDER/photo.jpg"), to: src.appendingPathComponent("FOLDER/Photo.JPG"))
        let out = try plainCopy().run(src, in: folder)
        #expect(out.removed == 0)
        #expect(out.written == 0)
        #expect(tree(folder.appendingPathComponent("Lib")) == ["FOLDER", "FOLDER/Photo.JPG"])
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(PlainCopyLayout.removedFolder).path))
    }

    // A folder where the library now has a file (rsync fails on that: "Directory not
    // empty") is set aside in Removed items first, and the file copied.
    @Test func anItemOfAnotherKindIsSetAsideFirst() throws {
        let base = tempDir("kind")
        defer { try? FileManager.default.removeItem(at: base) }
        let src = base.appendingPathComponent("Lib"), folder = base.appendingPathComponent("dest")
        try put(src, "thing/inner.txt", "i")
        _ = try plainCopy().run(src, in: folder)
        try FileManager.default.removeItem(at: src.appendingPathComponent("thing"))
        try put(src, "thing", "now a file")
        let out = try plainCopy().run(src, in: folder)
        #expect(out.removed == 1)
        #expect(try String(contentsOf: folder.appendingPathComponent("Lib/thing"), encoding: .utf8) == "now a file")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Removed items/2027-01-15/thing/inner.txt").path))
    }

    // Stop in each step after the plan: the run ends at once, the mark stays (Restore
    // says the copy may be part old, part new), and nothing has gone to Removed items.
    // The next run finishes the job.
    @Test func stopInEveryStepLeavesTheMarkAndMovesNothing() throws {
        let titles = ["Putting right names whose capitals or accents changed", "Copying", "Finishing the copy",
                      "Checking the copy", "Reading the copy back"]
        for title in titles {
            let base = tempDir("stop")
            defer { try? FileManager.default.removeItem(at: base) }
            let src = base.appendingPathComponent("Lib"), folder = base.appendingPathComponent("dest")
            for i in 0..<12 { try put(src, "d\(i % 3)/f\(i).txt", String(repeating: "x", count: 1000 + i)) }
            try put(src, "rename.txt", "r")
            try put(src, "gone.txt", "g")
            _ = try plainCopy().run(src, in: folder)
            try FileManager.default.removeItem(at: src.appendingPathComponent("gone.txt"))
            try FileManager.default.moveItem(at: src.appendingPathComponent("rename.txt"), to: src.appendingPathComponent("tmp"))
            try FileManager.default.moveItem(at: src.appendingPathComponent("tmp"), to: src.appendingPathComponent("RENAME.txt"))
            for i in 0..<12 { try put(src, "d\(i % 3)/f\(i).txt", String(repeating: "y", count: 1000 + i), date: 1_700_000_900) }

            let control = RunControl(), log = StepLog()
            log.follow(control)
            log.onBegin = { if $0 == title { control.cancel() } }
            #expect(throws: CancelledError.self) { _ = try plainCopy(control: control).run(src, in: folder) }
            #expect(log.titles.last == title)
            #expect(PlainCopyLayout.isOpen(folder), "no mark after a Stop in \(title)")
            #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("Removed items").path), "moved after a Stop in \(title)")

            let out = try plainCopy().run(src, in: folder)
            #expect(out.removed == 1)
            #expect(!PlainCopyLayout.isOpen(folder))
            #expect(try String(contentsOf: folder.appendingPathComponent("Lib/d0/f0.txt"), encoding: .utf8).hasPrefix("y"))
        }
    }

    // A byte changed in the copy after it was written is caught by the read-back, and
    // the run fails with the mark still there and nothing removed.
    @Test func theReadBackCatchesAFlippedByte() throws {
        let base = tempDir("flip")
        defer { try? FileManager.default.removeItem(at: base) }
        let src = base.appendingPathComponent("Lib"), folder = base.appendingPathComponent("dest")
        try put(src, "a.bin", String(repeating: "a", count: 5000))
        let control = RunControl(), log = StepLog()
        log.follow(control)
        let copied = folder.appendingPathComponent("Lib/a.bin")
        log.onBegin = { title in
            guard title == "Checking the copy", let h = try? FileHandle(forUpdating: copied) else { return }
            var st = stat(); lstat(copied.path, &st)
            try? h.seek(toOffset: 100); h.write(Data("b".utf8)); try? h.close()
            var times = [st.st_atimespec, st.st_mtimespec]
            _ = utimensat(AT_FDCWD, copied.path, &times, 0)
        }
        #expect(throws: PlainCopyError.self) { _ = try plainCopy(control: control).run(src, in: folder) }
        #expect(PlainCopyLayout.isOpen(folder))
    }

    // A drive without room refuses the run before anything is written, naming the room
    // Removed items take.
    @Test func noRoomRefusesBeforeWriting() throws {
        let base = tempDir("full")
        defer { try? FileManager.default.removeItem(at: base) }
        let src = base.appendingPathComponent("Lib"), folder = base.appendingPathComponent("dest")
        try put(src, "a.bin", String(repeating: "a", count: 50_000))
        #expect(throws: PlainCopyError.self) { _ = try plainCopy(free: 1000).run(src, in: folder) }
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("Lib").path))
        #expect(!PlainCopyLayout.isOpen(folder))
    }
}

extension PlainCopyInPlaceTests {
    // statfs can say less than a drive's real cluster (CI's macOS 15 with exFAT): the
    // room check counts what a probe file takes when that is more.
    @Test func roomIsCountedByWhatAFileReallyTakes() throws {
        let base = tempDir("unit")
        defer { try? FileManager.default.removeItem(at: base) }
        let src = base.appendingPathComponent("Lib"), folder = base.appendingPathComponent("dest")
        try put(src, "small.txt", "tiny")
        func run(unit: UInt64?) throws {
            _ = try PlainCopy(profile: exfatLike, runner: ProcessCommandRunner(), freeSpace: { _ in 100_000 }, companions: false,
                              accepts: { _ in true }, probe: { _ in DriveAllocation(allocationUnit: unit, companion: false) })
                .run(src, in: folder)
        }
        #expect(throws: PlainCopyError.notEnoughRoom(needed: 131_072, free: 100_000, removedBytes: 0)) { try run(unit: 131_072) }
        // nothing measured on an exFAT drive: its largest cluster is assumed
        #expect(throws: PlainCopyError.notEnoughRoom(needed: 131_072, free: 100_000, removedBytes: 0)) { try run(unit: nil) }
        try run(unit: 4096)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Lib/small.txt").path))
    }
}

@Suite(.serialized) struct PlainCopySwappedTests {

    // On APFS the copy is made beside the last one and swapped in whole: what the
    // library no longer holds is kept in Removed items (a clone), the staging folder
    // goes, and a stopped run leaves the last copy as it was.
    @Test func aCopySwappedInWholeKeepsDeletedItems() throws {
        let base = tempDir("apfs")
        defer { try? FileManager.default.removeItem(at: base) }
        let src = base.appendingPathComponent("Lib"), folder = base.appendingPathComponent("dest")
        try put(src, "a.txt", "a")
        try put(src, "sub/b.txt", "b")
        let apfs = FileSystemProfile(kind: .apfs, fsType: "apfs", foldsCase: true)
        #expect(apfs.swapsWholeCopy && apfs.takesAppLibraries)
        var out = try plainCopy(apfs).run(src, in: folder)
        #expect(out.written == 2)
        try FileManager.default.removeItem(at: src.appendingPathComponent("sub"))
        out = try plainCopy(apfs).run(src, in: folder)
        #expect(out.removed == 1)
        #expect(tree(folder.appendingPathComponent("Lib")) == ["a.txt"])
        #expect(try String(contentsOf: folder.appendingPathComponent("Removed items/2027-01-15/sub/b.txt"), encoding: .utf8) == "b")
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(PlainCopyLayout.staging).path))

        // Stopped while reading back: the last copy is untouched
        try put(src, "a.txt", "changed", date: 1_700_000_700)
        let control = RunControl(), log = StepLog()
        log.follow(control)
        log.onBegin = { if $0 == "Reading the copy back" { control.cancel() } }
        #expect(throws: CancelledError.self) { _ = try plainCopy(apfs, control: control).run(src, in: folder) }
        #expect(try String(contentsOf: folder.appendingPathComponent("Lib/a.txt"), encoding: .utf8) == "a")
        out = try plainCopy(apfs).run(src, in: folder)
        #expect(try String(contentsOf: folder.appendingPathComponent("Lib/a.txt"), encoding: .utf8) == "changed")
    }

    // Only a copy swapped in whole takes an app library; everywhere else the run and
    // the editor refuse it, saying why and what to use instead.
    @Test func appLibrariesOnlyWhereTheCopyIsSwappedInWhole() {
        for kind in [FileSystemProfile.Kind.exfat, .fat32, .network, .cloud, .hfs, .other] {
            let p = FileSystemProfile(kind: kind, fsType: kind == .hfs ? "hfs" : "x")
            #expect(!p.takesAppLibraries)
            #expect(p.refusal(appLibrary: "Photos")?.hasSuffix("Use a disk image on this drive.") == true)
        }
        #expect(FileSystemProfile.make(fsType: "apfs").refusal(appLibrary: "Photos") == nil)
        #expect(FileSystemProfile.make(fsType: "apfs", target: .cloudSync).kind == .cloud)
        #expect(FileSystemProfile.make(fsType: "smbfs").kind == .network)
        #expect(FileSystemProfile.make(fsType: "msdos").maxFileSize == FileSystemProfile.fat32Limit)
        #expect(FileSystemProfile.make(fsType: "apfs", target: .cloudSync, cloudLimit: 50).maxFileSize == 50)
    }
}
