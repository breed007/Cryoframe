//
//  MediaExportTests.swift
//  CryoframeKitTests
//
//  Restore → Export Media…: what is exported, into which month folder, under which
//  name; that exporting again never copies a file twice; and that room, Stop and a
//  FAT32 drive are handled before or while anything is written. The planner runs on
//  fakes; the copy runs on temporary folders.
//

import Testing
import Foundation
@testable import CryoframeKit

private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

private func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
    utc.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
}

private func file(_ path: String, _ size: UInt64 = 10, _ date: Date = day(2024, 5, 3)) -> MediaFile {
    MediaFile(path: path, size: size, modified: date)
}

/// A version and a folder exported to, in memory. A file's bytes are a label: two
/// files hold the same bytes when their labels match.
private final class FakeDisk: @unchecked Sendable {
    private let lock = NSLock()
    var source: [String: String] = [:]
    /// folder → name → (size, label)
    var exported: [String: [String: (size: UInt64, label: String)]] = [:]
    var compares = 0

    func label(_ at: MediaLocation) -> String? {
        switch at {
        case .source(let p): return source[p]
        case .exported(let f, let n): return exported[f]?[n]?.label
        }
    }

    var probe: MediaExportProbe {
        MediaExportProbe(contents: { folder in
            self.lock.lock(); defer { self.lock.unlock() }
            return self.exported[folder]?.mapValues(\.size)
        }, sameBytes: { a, b, read in
            self.lock.lock(); self.compares += 1; self.lock.unlock()
            read(1)
            return self.label(a) != nil && self.label(a) == self.label(b)
        })
    }

    /// what the plan's copies would leave in the folder
    func apply(_ plan: MediaExportPlan) {
        for c in plan.copies { exported[c.folder, default: [:]][c.name] = (c.size, source[c.source] ?? "?") }
    }
}

private func plan(_ files: [MediaFile], _ disk: FakeDisk, drive: MediaExportDrive = MediaExportDrive(name: "Card"),
                  filter: MediaExportFilter = MediaExportFilter(kinds: Set(MediaKind.allCases))) throws -> MediaExportPlan {
    let entries = MediaCatalog.entries(files).filter { filter.includes($0, calendar: utc) }
    return try MediaExportPlanner.plan(entries, drive: drive, probe: disk.probe, calendar: utc)
}

private func names(_ p: MediaExportPlan) -> [String] { p.copies.map { "\($0.folder)/\($0.name)" } }

@Suite struct MediaExportTests {

    // MARK: - what is exported

    @Test func filesAreSortedIntoKindsAndBookkeepingIsLeftOut() {
        #expect(MediaKind.of(name: "IMG_0001.HEIC") == .photos)
        #expect(MediaKind.of(name: "a.jpeg") == .photos)
        #expect(MediaKind.of(name: "clip.MOV") == .videos)
        #expect(MediaKind.of(name: "clip.mp4") == .videos)
        #expect(MediaKind.of(name: "letter.pdf") == .other)
        #expect(MediaKind.of(name: "voice.m4a") == .other)
        #expect(MediaKind.of(name: "README") == .other)
        for name in ["._IMG_0001.HEIC", ".DS_Store", "Info.plist", "AB12-CD.pluginPayloadAttachment"] {
            #expect(MediaKind.of(name: name) == nil, "\(name)")
        }
    }

    @Test func aLivePhotosVideoTravelsWithItsPhoto() {
        let entries = MediaCatalog.entries([
            file("ab/01/G1/IMG_0001.HEIC"), file("ab/01/G1/img_0001.mov"),
            file("ab/01/G2/IMG_0001.MOV"),               // another folder: a video of its own
            file("ab/01/G1/notes.plist"),
        ])
        #expect(entries.count == 2)
        let photo = entries.first { $0.kind == .photos }
        #expect(photo?.motion?.path == "ab/01/G1/img_0001.mov")
        #expect(entries.first { $0.kind == .videos }?.file.path == "ab/01/G2/IMG_0001.MOV")
    }

    @Test func theFilterPicksKindsAndMonthsBothEndsIncluded() {
        let entries = MediaCatalog.entries([
            file("a.heic", 1, day(2024, 1, 31, hour: 23)), file("b.heic", 1, day(2024, 2, 1)),
            file("c.mov", 1, day(2024, 3, 31)), file("d.pdf", 1, day(2024, 2, 9)),
        ])
        let f = MediaExportFilter(kinds: [.photos, .videos], from: MediaMonth(year: 2024, month: 2),
                                  through: MediaMonth(year: 2024, month: 3))
        #expect(entries.filter { f.includes($0, calendar: utc) }.map(\.file.path) == ["b.heic", "c.mov"])
        #expect(MediaExportFilter().kinds == [.photos, .videos])
    }

    // MARK: - month folders and names

    @Test func filesGoIntoMonthFoldersByModificationDateAndTheVideoFollowsThePhoto() throws {
        let disk = FakeDisk()
        // the photo taken on the last evening of May, its video written just after midnight
        let p = try plan([file("G/IMG_7.HEIC", 5, day(2024, 5, 31, hour: 23)), file("G/IMG_7.MOV", 9, day(2024, 6, 1, hour: 0)),
                          file("H/trip.mp4", 3, day(2023, 12, 25))], disk)
        #expect(names(p) == ["2023-12/trip.mp4", "2024-05/IMG_7.HEIC", "2024-05/IMG_7.MOV"])
        #expect(Set(p.newFolders) == ["2023-12", "2024-05"])
        #expect(p.copies.first { $0.name == "IMG_7.MOV" }?.modified == day(2024, 6, 1, hour: 0))
        #expect(MediaMonth(year: 2024, month: 5).folderName == "2024-05")
    }

    @Test func aTakenNameWithOtherBytesGetsTheNextNumberAndAPairSharesIt() throws {
        let disk = FakeDisk()
        disk.source = ["A/IMG_1.HEIC": "a", "A/IMG_1.MOV": "am", "B/IMG_1.HEIC": "b", "B/IMG_1.MOV": "bm"]
        let p = try plan([file("A/IMG_1.HEIC"), file("A/IMG_1.MOV"), file("B/IMG_1.HEIC"), file("B/IMG_1.MOV")], disk)
        #expect(names(p) == ["2024-05/IMG_1.HEIC", "2024-05/IMG_1.MOV", "2024-05/IMG_1 (2).HEIC", "2024-05/IMG_1 (2).MOV"])
    }

    @Test func aPairMovesOnTogetherWhenOnlyItsVideosNameIsTaken() throws {
        let disk = FakeDisk()
        disk.source = ["A/IMG_1.HEIC": "a", "A/IMG_1.MOV": "am"]
        disk.exported = ["2024-05": ["IMG_1.MOV": (10, "someone else's")]]
        let p = try plan([file("A/IMG_1.HEIC"), file("A/IMG_1.MOV")], disk)
        #expect(names(p) == ["2024-05/IMG_1 (2).HEIC", "2024-05/IMG_1 (2).MOV"])
    }

    // MARK: - exporting again

    @Test func exportingTwiceCopiesNothingTheSecondTime() throws {
        let disk = FakeDisk()
        let files = [file("A/IMG_1.HEIC"), file("A/IMG_1.MOV"), file("B/IMG_1.HEIC"), file("C/IMG_1.HEIC"),
                     file("D/clip.mp4", 10, day(2024, 7, 1)), file("E/IMG_1.MOV")]
        disk.source = ["A/IMG_1.HEIC": "a", "A/IMG_1.MOV": "am", "B/IMG_1.HEIC": "b", "C/IMG_1.HEIC": "c",
                       "D/clip.mp4": "d", "E/IMG_1.MOV": "e"]
        let first = try plan(files, disk)
        #expect(first.copies.count == 6)
        disk.apply(first)
        let again = try plan(files, disk)
        #expect(again.copies.isEmpty)
        #expect(again.alreadyThere == 6)
        #expect(again.newFolders.isEmpty)
    }

    // A stop part way, then another export of the same files: each gets the name
    // it would have had in one go, and nothing is copied twice.
    @Test func aStoppedExportFinishesWithTheNamesOfAWholeOne() throws {
        let disk = FakeDisk()
        let files = [file("A/IMG_1.HEIC"), file("B/IMG_1.HEIC"), file("C/IMG_1.HEIC")]
        disk.source = ["A/IMG_1.HEIC": "a", "B/IMG_1.HEIC": "b", "C/IMG_1.HEIC": "c"]
        let whole = try plan(files, disk)
        #expect(names(whole) == ["2024-05/IMG_1.HEIC", "2024-05/IMG_1 (2).HEIC", "2024-05/IMG_1 (3).HEIC"])
        for stoppedAfter in 1...2 {
            let partial = FakeDisk()
            partial.source = disk.source
            var done = whole
            done.copies = Array(whole.copies.prefix(stoppedAfter))
            partial.apply(done)
            let rest = try plan(files, partial)
            #expect(rest.alreadyThere == stoppedAfter)
            #expect(names(done) + names(rest) == names(whole))
        }
    }

    // An earlier export of some of them (A was added since, or filtered out): A takes
    // a free name, and B and C aren't copied again.
    @Test func anExportAfterAnotherOfSomeOfTheFilesCopiesOnlyTheRest() throws {
        let disk = FakeDisk()
        let files = [file("A/IMG_1.HEIC"), file("B/IMG_1.HEIC"), file("C/IMG_1.HEIC")]
        disk.source = ["A/IMG_1.HEIC": "a", "B/IMG_1.HEIC": "b", "C/IMG_1.HEIC": "c"]
        let earlier = try plan(Array(files.dropFirst()), disk)
        disk.apply(earlier)
        let rest = try plan(files, disk)
        #expect(rest.alreadyThere == 2)
        #expect(rest.copies.map(\.source) == ["A/IMG_1.HEIC"])
        #expect(Set(names(earlier) + names(rest)).count == 3)
    }

    @Test func theNumberedCopiesAreCheckedBeforeWriting() throws {
        let disk = FakeDisk()
        disk.source = ["A/IMG_1.HEIC": "a"]
        disk.exported = ["2024-05": ["IMG_1.HEIC": (10, "other"), "IMG_1 (2).HEIC": (10, "other2"), "IMG_1 (3).HEIC": (10, "a")]]
        let p = try plan([file("A/IMG_1.HEIC")], disk)
        #expect(p.copies.isEmpty)
        #expect(p.alreadyThere == 1)
    }

    @Test func aDifferentSizeIsNeverReadToCompare() throws {
        let disk = FakeDisk()
        disk.source = ["A/IMG_1.HEIC": "a"]
        disk.exported = ["2024-05": ["IMG_1.HEIC": (99, "a")]]
        let p = try plan([file("A/IMG_1.HEIC")], disk)
        #expect(names(p) == ["2024-05/IMG_1 (2).HEIC"])
        #expect(disk.compares == 0)
    }

    @Test func theSameFileTwiceInOneVersionIsCopiedOnce() throws {
        let disk = FakeDisk()
        disk.source = ["G1/IMG_1.HEIC": "same", "G2/IMG_1.HEIC": "same"]
        let p = try plan([file("G1/IMG_1.HEIC"), file("G2/IMG_1.HEIC")], disk)
        #expect(names(p) == ["2024-05/IMG_1.HEIC"])
        #expect(p.alreadyThere == 1)
    }

    @Test func namesThatDifferOnlyInCapitalsCollideWhereTheDriveFoldsCase() throws {
        let disk = FakeDisk()
        disk.source = ["A/IMG_1.HEIC": "a"]
        disk.exported = ["2024-05": ["img_1.heic": (10, "other")]]
        #expect(names(try plan([file("A/IMG_1.HEIC")], disk)) == ["2024-05/IMG_1 (2).HEIC"])
        let sensitive = MediaExportDrive(name: "Mac", foldsCase: false)
        #expect(names(try plan([file("A/IMG_1.HEIC")], disk, drive: sensitive)) == ["2024-05/IMG_1.HEIC"])
    }

    // MARK: - the drive

    @Test func aFAT32DriveSkipsFilesOf4GBOrMore() throws {
        let disk = FakeDisk()
        let fat = MediaExportDrive(name: "Card", maxFileSize: MediaExportDrive.fat32Limit)
        let p = try plan([file("big.mov", MediaExportDrive.fat32Limit), file("small.mov", MediaExportDrive.fat32Limit - 1)], disk, drive: fat)
        #expect(names(p) == ["2024-05/small.mov"])
        #expect(p.tooLarge == ["big.mov"])
        var o = MediaExportOutcome()
        o.matched = 2; o.copied = 1; o.planned = 1; o.bytes = 10; o.tooLarge = p.tooLarge
        #expect(o.summary(folder: "Exports").contains("1 file was skipped (big.mov): a file of 4 GB or more doesn't fit on a FAT32 drive"))
    }

    @Test func roomCountsWholeClustersAndEachHiddenCompanion() {
        var p = MediaExportPlan()
        p.copies = [.init(source: "a", folder: "2024-05", name: "a", size: 1, modified: Date()),
                    .init(source: "b", folder: "2024-05", name: "b", size: 131_073, modified: Date())]
        p.newFolders = ["2024-05"]
        let mac = MediaExportDrive(name: "Mac", cluster: 4096)
        let card = MediaExportDrive(name: "Card", cluster: 131_072, companions: true)
        let floor: UInt64 = 16 * 1024 * 1024
        #expect(MediaExportRoom.needed(p, drive: mac) == 4096 + 135_168 + 4096 + floor)
        // typed parts: Xcode 16's type checker gives up on the literal sum
        let files: UInt64 = 131_072 + 262_144, companions: UInt64 = 2 * 131_072, folders: UInt64 = 2 * 131_072
        #expect(MediaExportRoom.needed(p, drive: card) == files + companions + folders + floor)
        var tight = card; tight.free = MediaExportRoom.needed(p, drive: card) - 1
        let refusal = MediaExportRoom.refusal(p, drive: tight)
        #expect(refusal != nil)
        #expect(refusal?.localizedDescription.contains("Nothing was copied") == true)
        tight.free = nil
        #expect(MediaExportRoom.refusal(p, drive: tight) == nil)
    }

    @Test func stopWhileCheckingEndsThePlan() {
        let disk = FakeDisk()
        let control = RunControl()
        control.cancel()
        #expect(throws: CancelledError.self) {
            try MediaExportPlanner.plan(MediaCatalog.entries([file("a.heic")]), drive: MediaExportDrive(name: "Card"),
                                        probe: disk.probe, calendar: utc, control: control)
        }
    }

    // MARK: - which versions, and the warning

    @Test func photosIsNotOfferedAndMessagesExportsItsAttachments() {
        func archive(_ name: String, key: String?, encrypted: Bool = false) -> RestorableArchive {
            RestorableArchive(dir: URL(fileURLWithPath: "/x/\(name)"), libraryName: name, format: .sealedDMG, bytes: 1,
                              artifactNames: ["\(name).dmg"], encrypted: encrypted, libraryKey: key)
        }
        let photos = archive("Photos Library.photoslibrary", key: "J/com.apple.photos")
        let family = archive("Family.photoslibrary", key: nil)
        let legacyPhotos = archive("Photos Library.photoslibrary", key: nil)
        let messages = archive("Messages", key: "J/com.apple.messages")
        let legacyMessages = archive("Messages", key: nil)
        let mail = archive("Mail", key: "J/com.apple.mail")
        let folder = archive("Projects", key: "J/3F2A")
        #expect(!MediaExportScope.isOffered(photos))
        #expect(!MediaExportScope.isOffered(family))
        #expect(!MediaExportScope.isOffered(legacyPhotos))
        #expect(!MediaExportScope.isOffered(mail))
        #expect(MediaExportScope.isOffered(messages) && MediaExportScope.isOffered(legacyMessages) && MediaExportScope.isOffered(folder))
        let root = URL(fileURLWithPath: "/v/Messages")
        #expect(MediaExportScope.folder(in: root, for: messages).lastPathComponent == "Attachments")
        #expect(MediaExportScope.folder(in: root, for: folder) == root)

        // plain copies of a version that's encrypted, or holds messages, say so once
        #expect(MediaExportScope.warning(for: folder, driveEncrypted: false) == nil)
        let enc = MediaExportScope.warning(for: archive("Projects", key: "J/3F2A", encrypted: true), driveEncrypted: false)
        #expect(enc?.contains("aren't encrypted") == true)
        #expect(enc?.contains("delete them from that folder") == true)
        #expect(enc?.contains("messages") == false)
        let msg = MediaExportScope.warning(for: messages, driveEncrypted: false)
        #expect(msg?.contains("even ones deleted in Messages since this backup") == true)
        #expect(MediaExportScope.warning(for: messages, driveEncrypted: true) == nil)
    }

    @Test func theSummarySaysWhatHappened() {
        var o = MediaExportOutcome()
        #expect(o.summary(folder: "Exports").hasPrefix("Nothing to export"))
        o.matched = 3; o.alreadyThere = 3
        #expect(o.summary(folder: "Exports") == "Everything was already in “Exports”: 3 files.")
        o.stopped = true; o.planned = 3_412; o.copied = 1_204
        #expect(o.summary(folder: "Exports") == "Stopped after \(1_204.formatted()) of \(3_412.formatted()) files. Exporting again skips what's done.")

        // files that couldn't be read are named, the first three, after what was done
        var u = MediaExportOutcome()
        u.matched = 6; u.planned = 6; u.copied = 2; u.bytes = 20; u.unreadable = ["a/1.jpg", "a/2.jpg", "b/3.jpg", "b/4.jpg"]
        let text = u.summary(folder: "Exports")
        #expect(text.hasPrefix("Copied 2 files"))
        #expect(text.contains("4 files couldn't be read from this backup and weren't copied: a/1.jpg, a/2.jpg, b/3.jpg, …"), "\(text)")
        u.copied = 0; u.alreadyThere = 5; u.unreadable = ["a/1.jpg"]
        #expect(!u.summary(folder: "Exports").hasPrefix("Everything was already"))
        #expect(u.summary(folder: "Exports").contains("1 file couldn't be read from this backup and wasn't copied: a/1.jpg."))
    }

    // a failure writing to the drive says so in words about the drive, never about reading
    @Test func aWriteFailureIsDescribedAsSaving() {
        let full = MediaExport.writeReason(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)))
        #expect(full == "the drive is full.")
        let denied = MediaExport.writeReason(CocoaError(.fileWriteNoPermission))
        #expect(denied == "Cryoframe isn't allowed to save files there.")
        let e = MediaExportError.saveFailed(name: "IMG_1.HEIC", folder: "2024-05", reason: full, copied: 3, of: 9)
        #expect(e.localizedDescription == "Couldn't save “IMG_1.HEIC” in the folder “2024-05”: the drive is full. 3 of 9 files were copied; exporting again skips them.")
    }
}

// MARK: - the copy, on temporary folders

@Suite(.serialized) struct MediaExportCopyTests {
    private func scratch() throws -> (source: URL, dest: URL, cleanup: () -> Void) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("cf-media-\(UUID().uuidString)")
        let source = base.appendingPathComponent("Library"), dest = base.appendingPathComponent("Out")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        return (source, dest, { try? FileManager.default.removeItem(at: base) })
    }

    private func write(_ root: URL, _ path: String, _ text: String, _ date: Date) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func everything(_ root: URL) -> [String] {
        let walk = FileManager.default.enumerator(atPath: root.path)
        var out: [String] = []
        while let p = walk?.nextObject() as? String {
            var dir: ObjCBool = false
            if FileManager.default.fileExists(atPath: root.appendingPathComponent(p).path, isDirectory: &dir), !dir.boolValue { out.append(p) }
        }
        return out.sorted()
    }

    @Test func anExportWritesMonthFoldersKeepsDatesAndASecondCopiesNothing() throws {
        let (source, dest, cleanup) = try scratch()
        defer { cleanup() }
        try write(source, "G1/IMG_1.HEIC", "photo one", day(2024, 5, 31, hour: 23))
        try write(source, "G1/IMG_1.MOV", "motion one", day(2024, 6, 1, hour: 0))
        try write(source, "G2/IMG_1.HEIC", "photo two", day(2024, 5, 2))
        try write(source, "G3/IMG_1.HEIC", "photo one", day(2024, 5, 9))            // the same photo, sent again
        try write(source, "G3/talk.pdf", "pdf", day(2024, 5, 9))
        try write(source, "G3/.hidden.jpg", "x", day(2024, 5, 9))
        let drive = MediaExportDrive(name: "Out", free: 1 << 40)
        let export = MediaExport(calendar: utc, interval: 0)
        let first = try export.run(from: source, to: dest, filter: MediaExportFilter(), drive: drive, control: RunControl()) { _ in }
        #expect(everything(dest) == ["2024-05/IMG_1 (2).HEIC", "2024-05/IMG_1.HEIC", "2024-05/IMG_1.MOV"])
        #expect(first.copied == 3 && first.alreadyThere == 1 && !first.stopped)
        let video = try FileManager.default.attributesOfItem(atPath: dest.appendingPathComponent("2024-05/IMG_1.MOV").path)
        #expect(video[.modificationDate] as? Date == day(2024, 6, 1, hour: 0))
        #expect(try String(contentsOf: dest.appendingPathComponent("2024-05/IMG_1.HEIC"), encoding: .utf8) == "photo one")

        let again = try export.run(from: source, to: dest, filter: MediaExportFilter(), drive: drive, control: RunControl()) { _ in }
        #expect(again.copied == 0 && again.alreadyThere == 4)
        #expect(everything(dest).count == 3)
    }

    @Test func stopWhileCopyingLeavesNoPartFileAndSaysHowFarItGot() throws {
        let (source, dest, cleanup) = try scratch()
        defer { cleanup() }
        for i in 0..<4 { try write(source, "f\(i).heic", String(repeating: "x", count: 100 + i), day(2024, 5, 3)) }
        let control = RunControl()
        let seen = Phases()
        let out = try MediaExport(calendar: utc, interval: 0).run(from: source, to: dest, filter: MediaExportFilter(),
                                                                   drive: MediaExportDrive(name: "Out", free: 1 << 40),
                                                                   control: control) { p in
            seen.add(p.phase)
            // stop once the second file is being copied
            if p.phase == .copying, p.detail.hasPrefix("Copying 2 of") { control.cancel() }
        }
        #expect(out.stopped && out.copied == 1 && out.planned == 4)
        #expect(everything(dest) == ["2024-05/f0.heic"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: dest.appendingPathComponent("2024-05").path).count == 1)
        #expect(seen.all == [.looking, .checking, .copying])
    }

    @Test func noRoomIsRefusedBeforeAnythingIsWritten() throws {
        let (source, dest, cleanup) = try scratch()
        defer { cleanup() }
        try write(source, "a.heic", "a", day(2024, 5, 3))
        #expect(throws: MediaExportError.self) {
            try MediaExport(calendar: utc).run(from: source, to: dest, filter: MediaExportFilter(),
                                               drive: MediaExportDrive(name: "Out", free: 1024), control: RunControl()) { _ in }
        }
        #expect(everything(dest).isEmpty)
    }

    // A file that can't be read is skipped and named; the rest go out, nothing
    // part-written is left, and exporting again still names it.
    @Test func anUnreadableFileIsSkippedAndTheRestGoOut() throws {
        let (source, dest, cleanup) = try scratch()
        let locked = source.appendingPathComponent("b/IMG_2.JPG")
        defer { chmod(locked.path, 0o644); cleanup() }
        for i in 0..<4 { try write(source, "\(i < 2 ? "a" : "b")/IMG_\(i).JPG", "photo \(i)", day(2024, 5, 3)) }
        #expect(chmod(locked.path, 0) == 0)
        let drive = MediaExportDrive(name: "Out", free: 1 << 40)
        let export = MediaExport(calendar: utc, interval: 0)
        let first = try export.run(from: source, to: dest, filter: MediaExportFilter(), drive: drive, control: RunControl()) { _ in }
        #expect(first.copied == 3 && first.unreadable == ["b/IMG_2.JPG"] && !first.stopped, "\(first)")
        #expect(everything(dest) == ["2024-05/IMG_0.JPG", "2024-05/IMG_1.JPG", "2024-05/IMG_3.JPG"])
        #expect(first.summary(folder: "Out").contains("couldn't be read from this backup and wasn't copied: b/IMG_2.JPG."))

        let again = try export.run(from: source, to: dest, filter: MediaExportFilter(), drive: drive, control: RunControl()) { _ in }
        #expect(again.copied == 0 && again.alreadyThere == 3 && again.unreadable == ["b/IMG_2.JPG"], "\(again)")
        #expect(everything(dest).count == 3)
    }

    // A folder that can't be written to ends the export with words about saving.
    @Test func aFolderThatCantBeWrittenToEndsTheExport() throws {
        let (source, dest, cleanup) = try scratch()
        defer { chmod(dest.path, 0o755); cleanup() }
        try write(source, "a.heic", "a", day(2024, 5, 3))
        #expect(chmod(dest.path, 0o555) == 0)
        do {
            _ = try MediaExport(calendar: utc).run(from: source, to: dest, filter: MediaExportFilter(),
                                                   drive: MediaExportDrive(name: "Out", free: 1 << 40), control: RunControl()) { _ in }
            Issue.record("the export didn't fail")
        } catch let e as MediaExportError {
            guard case .saveFailed(let name, let folder, let reason, let copied, _) = e else { Issue.record("\(e)"); return }
            #expect(name == "a.heic" && folder == "2024-05" && copied == 0)
            #expect(reason == "Cryoframe isn't allowed to save files there.", "\(reason)")
        }
    }

    // A crash part way leaves the export's list and a part-written file under its
    // real name: the next export removes it, writes it whole under the same name,
    // and keeps the files that were finished. A Stop leaves no list.
    @Test func aFileACrashLeftPartWrittenIsWrittenAgain() throws {
        let (source, dest, cleanup) = try scratch()
        defer { cleanup() }
        for i in 0..<3 { try write(source, "f\(i).heic", String(repeating: "x", count: 1000 + i), day(2024, 5, 3)) }
        let drive = MediaExportDrive(name: "Out", free: 1 << 40)
        let export = MediaExport(calendar: utc, interval: 0)
        // the crash: the list written, f0 finished, f1 half written, f2 not started
        let files = try MediaExport.look(in: source, control: RunControl()) { _ in }
        let plan = try MediaExportPlanner.plan(MediaCatalog.entries(files), drive: drive,
                                               probe: MediaExport.probe(source: source, destination: dest, control: RunControl()), calendar: utc)
        try MediaExport.writeList(plan, in: dest)
        let month = dest.appendingPathComponent("2024-05")
        try FileManager.default.createDirectory(at: month, withIntermediateDirectories: true)
        var partLeft = false
        try MediaExport.copyFile(source.appendingPathComponent("f0.heic"), into: month, as: "f0.heic", modified: day(2024, 5, 3),
                                 control: RunControl(), partLeft: &partLeft) { _ in }
        try Data(String(repeating: "x", count: 500).utf8).write(to: month.appendingPathComponent("f1.heic"))

        let after = try export.run(from: source, to: dest, filter: MediaExportFilter(), drive: drive, control: RunControl()) { _ in }
        #expect(after.copied == 2 && after.alreadyThere == 1, "\(after)")
        #expect(everything(dest) == ["2024-05/f0.heic", "2024-05/f1.heic", "2024-05/f2.heic"], "no list left, no \"(2)\"")
        #expect(FileManager.default.contentsEqual(atPath: month.appendingPathComponent("f1.heic").path, andPath: source.appendingPathComponent("f1.heic").path))
        let date = try FileManager.default.attributesOfItem(atPath: month.appendingPathComponent("f1.heic").path)[.modificationDate] as? Date
        #expect(date == day(2024, 5, 3))
    }

    // A file of someone else's under a name the list never had is left alone, even
    // when it doesn't match anything
    @Test func theListOnlyTouchesTheNamesItHas() throws {
        let (_, dest, cleanup) = try scratch()
        defer { cleanup() }
        let month = dest.appendingPathComponent("2024-05")
        try FileManager.default.createDirectory(at: month, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: month.appendingPathComponent("mine.jpg"))
        try Data("half".utf8).write(to: month.appendingPathComponent("IMG_1.JPG"))
        var plan = MediaExportPlan()
        plan.copies = [.init(source: "a/IMG_1.JPG", folder: "2024-05", name: "IMG_1.JPG", size: 100, modified: day(2024, 5, 3))]
        try MediaExport.writeList(plan, in: dest)
        #expect(MediaExport.finishInterrupted(in: dest) == 1)
        #expect(everything(dest) == ["2024-05/mine.jpg"])
        #expect(MediaExport.finishInterrupted(in: dest) == 0)
    }

    @Test func aMissingAttachmentsFolderSaysSo() throws {
        let (source, dest, cleanup) = try scratch()
        defer { cleanup() }
        #expect(throws: MediaExportError.notFound("Attachments")) {
            try MediaExport().run(from: source.appendingPathComponent("Attachments"), to: dest, filter: MediaExportFilter(),
                                  control: RunControl()) { _ in }
        }
    }
}

/// the phases progress was reported in, in order, each once
private final class Phases: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [MediaExportProgress.Phase] = []
    func add(_ p: MediaExportProgress.Phase) { lock.lock(); if list.last != p { list.append(p) }; lock.unlock() }
    var all: [MediaExportProgress.Phase] { lock.lock(); defer { lock.unlock() }; return list }
}
