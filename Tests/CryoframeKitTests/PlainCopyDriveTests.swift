//
//  PlainCopyDriveTests.swift
//  CryoframeKitTests
//
//  The plain-files format onto real exFAT and FAT32 drives (disk images made and
//  detached here), from a library on the startup disk or on a case-sensitive drive:
//  what the drive is found to be, a second run that copies nothing (FAT32's 2-second
//  dates included), a name whose capitals changed, two library names the drive takes
//  for one, a "._" file beside its namesake, a file too large for FAT32 refused before
//  anything is written, and rsync's leftover temporary file swept, not kept.
//

import Testing
import Foundation
@testable import CryoframeKit

private func realTemp(_ tag: String) -> URL {
    let d = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        .appendingPathComponent("cf-plaindrive-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// A drive of `fs` ("ExFAT", "MS-DOS FAT32", "Case-sensitive APFS") in a disk image,
/// mounted under `base`.
private func drive(_ fs: String, mb: Int, cluster: Int? = nil, in base: URL) throws -> (mount: URL, detach: () -> Void) {
    let image = base.appendingPathComponent("drive-\(UUID().uuidString).dmg")
    let mount = base.appendingPathComponent("vol-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
    var args = ["create", "-size", "\(mb)m", "-fs", fs, "-volname", "CARD", "-type", "UDIF"]
    if !fs.contains("APFS") { args += ["-layout", "MBRSPUD"] }
    if let cluster { args += ["-fsargs", "-b \(cluster)"] }
    let made = try ProcessCommandRunner().run("/usr/bin/hdiutil", args + [image.path], stdin: nil)
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

private func run(_ src: URL, _ folder: URL, control: RunControl = RunControl()) throws -> PlainCopyOutcome {
    try PlainCopy(profile: FileSystemProfile.of(folder), runner: ProcessCommandRunner(control: control)).run(src, in: folder)
}

@Suite(.serialized) struct PlainCopyDriveTests {

    // exFAT, found as such with its real cluster size: a first run, a second that
    // copies nothing, a name whose capitals changed renamed in place, a deleted file
    // moved to Removed items with its "._" companion, a "._" file beside its namesake
    // left out, and a leftover rsync temporary file swept rather than kept.
    @Test func exFATRunsCopyOnlyWhatChangedAndKeepWhatWasDeleted() throws {
        let base = realTemp("exfat")
        defer { try? FileManager.default.removeItem(at: base) }
        let (card, detach) = try drive("ExFAT", mb: 64, cluster: 131072, in: base)
        defer { detach() }
        let profile = FileSystemProfile.of(card)
        #expect(profile.kind == .exfat)
        #expect(profile.cluster == 131072)
        #expect(profile.foldsCase && !profile.keepsMacDetails && !profile.takesAppLibraries)

        let src = base.appendingPathComponent("src/Documents")
        try put(src, "Taxes/W-2.pdf", "w2")
        try put(src, "notes.txt", "n")
        try put(src, "X", "x")
        try put(src, "._X", "a file of mine")
        try put(src, "odd.txt", "odd", date: 1_700_000_001)
        let folder = card.appendingPathComponent("Backups/Documents")

        var out = try run(src, folder)
        #expect(out.written == 4)
        #expect(out.excluded["._X"] == .companionName)
        #expect(out.notes.count == 1)
        let copy = folder.appendingPathComponent("Documents")
        #expect(try String(contentsOf: copy.appendingPathComponent("Taxes/W-2.pdf"), encoding: .utf8) == "w2")

        out = try run(src, folder)
        #expect(out.written == 0, "a second run copied \(out.written) files again")

        // capitals changed, a file deleted, a temporary file a killed rsync left
        try FileManager.default.moveItem(at: src.appendingPathComponent("notes.txt"), to: src.appendingPathComponent("n.tmp"))
        try FileManager.default.moveItem(at: src.appendingPathComponent("n.tmp"), to: src.appendingPathComponent("Notes.TXT"))
        try FileManager.default.removeItem(at: src.appendingPathComponent("Taxes/W-2.pdf"))
        try put(copy, ".X.o4stnEmcy9", "half a file")
        try PlainCopy.mark(folder)                  // the killed run's mark
        out = try run(src, folder)
        #expect(out.written == 0)
        #expect(out.removed == 1)
        #expect(PlainCopy.list(copy.path).contains("Notes.TXT"))
        #expect(!PlainCopy.list(copy.path).contains("notes.txt"))
        #expect(!PlainCopy.list(copy.path).contains(".X.o4stnEmcy9"))
        let day = PlainCopyLayout.removedDay(folder, Date())
        #expect(try String(contentsOf: day.appendingPathComponent("Taxes/W-2.pdf"), encoding: .utf8) == "w2")
        #expect(!FileManager.default.fileExists(atPath: day.appendingPathComponent(".X.o4stnEmcy9").path))
        #expect(!PlainCopyLayout.isOpen(folder))
    }

    // FAT32 keeps dates to 2 seconds: an odd-second file isn't copied again on every
    // run. A file of 4 GiB (sparse here, so it costs nothing) is left out before
    // anything is written, and named; everything else is copied.
    @Test func fat32DatesAndTheFourGigabyteLimit() throws {
        let base = realTemp("fat")
        defer { try? FileManager.default.removeItem(at: base) }
        let (card, detach) = try drive("MS-DOS FAT32", mb: 64, in: base)
        defer { detach() }
        let profile = FileSystemProfile.of(card)
        #expect(profile.kind == .fat32)
        #expect(profile.maxFileSize == FileSystemProfile.fat32Limit)

        let src = base.appendingPathComponent("src/Movies")
        try put(src, "odd.txt", "odd", date: 1_700_000_001)
        try put(src, "even.txt", "even", date: 1_700_000_002)
        let big = src.appendingPathComponent("huge.mov")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let h = try FileHandle(forWritingTo: big); try h.truncate(atOffset: FileSystemProfile.fat32Limit); try h.close()
        let folder = card.appendingPathComponent("Movies")

        var out = try run(src, folder)
        #expect(out.written == 2)
        #expect(out.excluded["huge.mov"] == .tooLarge(FileSystemProfile.fat32Limit))
        #expect(out.notes.first?.contains("“huge.mov”") == true)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("Movies/huge.mov").path))
        out = try run(src, folder)
        #expect(out.written == 0, "FAT32's rounded dates copied \(out.written) files again")
    }

    // A case-sensitive library holding "a.txt", then "A.txt" as well, copied to a drive
    // that folds case: the one already copied stays, every run, and the other is named
    // as left out. In a new copy, the first by its bytes ("A" before "a") is kept.
    @Test func twoNamesTheDriveTakesForOneKeepTheOneAlreadyCopied() throws {
        let base = realTemp("case")
        defer { try? FileManager.default.removeItem(at: base) }
        let (lib, detachLib) = try drive("Case-sensitive APFS", mb: 32, in: base)
        defer { detachLib() }
        let (card, detach) = try drive("ExFAT", mb: 32, in: base)
        defer { detach() }
        let src = lib.appendingPathComponent("Papers")
        try put(src, "a.txt", "lower")
        let folder = card.appendingPathComponent("Papers")
        var out = try run(src, folder)
        #expect(out.written == 1)

        try put(src, "A.txt", "UPPER")
        for _ in 0..<2 {
            out = try run(src, folder)
            #expect(out.excluded["A.txt"] == .sameName(kept: "a.txt"))
            #expect(out.removed == 0)
            #expect(try String(contentsOf: folder.appendingPathComponent("Papers/a.txt"), encoding: .utf8) == "lower")
        }

        // the same library to the startup disk (APFS, case folded), the copy made beside
        // the last and swapped in: the one left out lends the kept one neither its date
        // nor its attributes (the read-back would catch either)
        try put(src, "b.txt", "lower b", date: 1_700_000_100)
        try put(src, "B.TXT", "UPPER B, longer", date: 1_700_000_900)
        let startup = base.appendingPathComponent("startup")
        let apfs = FileSystemProfile.of(base)
        #expect(apfs.kind == .apfs && apfs.swapsWholeCopy)
        let mac = try PlainCopy(profile: apfs, runner: ProcessCommandRunner()).run(src, in: startup)
        #expect(mac.excluded["b.txt"] == .sameName(kept: "B.TXT"))
        #expect(try String(contentsOf: startup.appendingPathComponent("Papers/B.TXT"), encoding: .utf8) == "UPPER B, longer")

        let fresh = card.appendingPathComponent("Fresh")
        out = try run(src, fresh)
        #expect(out.excluded["a.txt"] == .sameName(kept: "A.txt"))
        #expect(try String(contentsOf: fresh.appendingPathComponent("Papers/A.txt"), encoding: .utf8) == "UPPER")
    }

    // The free-space measure a probe falls back on where a file written shows no
    // blocks (macOS 15's exFAT and FAT drivers), tried where the blocks are known.
    @Test func theProbesFreeSpaceMeasureFindsAnExFATCluster() throws {
        try #expect(unitByFreeSpace("ExFAT", mb: 64, cluster: 131072) == 131072)
    }

    @Test func theProbesFreeSpaceMeasureFindsAFAT32Cluster() throws {
        try #expect(unitByFreeSpace("MS-DOS FAT32", mb: 100) == 512)
    }

    private func unitByFreeSpace(_ fs: String, mb: Int, cluster: Int? = nil) throws -> UInt64? {
        let base = realTemp("unit")
        defer { try? FileManager.default.removeItem(at: base) }
        let (card, detach) = try drive(fs, mb: mb, cluster: cluster, in: base)
        defer { detach() }
        let probed = DriveAllocation.probe(at: card, readingBlocks: false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: card.path).filter { $0.hasPrefix(".cryoframe-probe-") }.isEmpty)
        return probed.allocationUnit
    }
}
