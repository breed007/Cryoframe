//
//  MirrorSizingTests.swift
//  CryoframeKitTests
//
//  Nobody chooses a mirror's size any more: the image is made as big as its drive,
//  grown if it is smaller, and a run the drive can't hold is refused before it
//  writes anything.
//

import Testing
import Foundation
@testable import CryoframeKit

private func tempDir(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-msz-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private let hdiutil = "/usr/bin/hdiutil"

private func library(files n: Int) throws -> URL {
    let lib = tempDir("lib").appendingPathComponent("Lib")
    try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
    for i in 0..<n { try Data("file \(i)".utf8).write(to: lib.appendingPathComponent("f\(i).txt")) }
    return lib
}

/// the image's current size in bytes, from `hdiutil resize -limits`.
private func imageBytes(_ bundle: URL) throws -> UInt64 {
    let r = try ProcessCommandRunner().run(hdiutil, ["resize", "-limits", bundle.path])
    let sectors = try #require(SparseBundleMirrorEngine.currentSectors(r.stdout), "\(r.stdout) \(r.stderr)")
    return sectors * 512
}

/// a scratch drive of `size` (hdiutil units), attached the way external drives are.
private func scratchDrive(_ size: String, in dir: URL) throws -> URL {
    let made = try ProcessCommandRunner().run(hdiutil, ["create", "-size", size, "-fs", "APFS", "-volname", "Drive",
                                                        "-type", "SPARSE", dir.appendingPathComponent("drive").path])
    try #require(made.ok, "\(made.stderr)")
    let mnt = dir.appendingPathComponent("mnt")
    try FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)
    let r = try DiskImageGate.serialized {
        try ProcessCommandRunner().runRetryingBusy(hdiutil, ["attach", dir.appendingPathComponent("drive.sparseimage").path,
                                                             "-mountpoint", mnt.path, "-nobrowse"])
    }
    try #require(r.ok, "\(r.stderr)")
    return mnt
}

// The image is sized to what is free now: on the startup disk "available for
// important usage" counts purgeable space the system frees only on demand.
@Test func theImageIsSizedToWhatIsFreeNowNotWhatCouldBePurged() throws {
    let tmp = FileManager.default.temporaryDirectory
    let now = try #require(JobExecutor.freeNow(for: tmp))
    let eventually = try #require(JobExecutor.freeSpace(for: tmp))
    #expect(now <= eventually + (64 << 20), "free now \(now) is more than free after purging \(eventually)")
}

// The room check refuses exactly what the image's cap leaves no room for. A library
// that fits only if macOS gave up its purgeable space used to pass the check and then
// run out of room inside the image on every run.
@Suite struct RoomCheck {
@Test func aLibraryThatFitsOnlyIfMacOSPurgedIsRefusedAndToldWhy() {
    let gib: UInt64 = 1 << 30
    let between = SparseBundleMirrorEngine.roomVerdict(needs: 250 * gib, held: 0, imageBytes: .max,
                                                       freeNow: 206 * gib, freeEventually: 324 * gib)
    #expect(between == .notEnoughRoomUntilPurged(needed: 251 * gib, free: 206 * gib, purgeable: 118 * gib))
    #expect(between?.errorDescription?.contains("purgeable") == true)
    let beyond = SparseBundleMirrorEngine.roomVerdict(needs: 400 * gib, held: 0, imageBytes: .max,
                                                      freeNow: 206 * gib, freeEventually: 324 * gib)
    #expect(beyond == .notEnoughRoom(needed: 401 * gib, free: 324 * gib))
    #expect(SparseBundleMirrorEngine.roomVerdict(needs: 100 * gib, held: 0, imageBytes: .max,
                                                 freeNow: 206 * gib, freeEventually: 324 * gib) == nil)
    // what the image already holds needn't come from the drive again
    #expect(SparseBundleMirrorEngine.roomVerdict(needs: 250 * gib, held: 200 * gib, imageBytes: .max,
                                                 freeNow: 206 * gib, freeEventually: 324 * gib) == nil)
    // a drive that won't say is not read as full
    #expect(SparseBundleMirrorEngine.roomVerdict(needs: 250 * gib, held: 0, imageBytes: .max, freeNow: nil, freeEventually: nil) == nil)
}

// The image is capped to leave a reserve free on its drive, so a drive with room for
// the library but not for the reserve as well can't take the run. It used to pass
// this check, make an image too small for the library, and blame the image's size.
@Test func aDriveShortOfTheReserveIsRefusedAndTheDriveIsBlamed() {
    let mib: UInt64 = 1 << 20
    let verdict = SparseBundleMirrorEngine.roomVerdict(needs: 100 * mib, held: 0, imageBytes: .max,
                                                       freeNow: 110 * mib, freeEventually: 110 * mib, reserve: 19 * mib)
    #expect(verdict == .notEnoughRoomBesideReserve(needed: 105 * mib, free: 110 * mib, reserve: 19 * mib))
    let text = verdict?.errorDescription ?? ""
    #expect(text.contains("drive") && !text.contains("disk image holds"), "\(text)")
    #expect(SparseBundleMirrorEngine.roomVerdict(needs: 100 * mib, held: 0, imageBytes: .max,
                                                 freeNow: 125 * mib, freeEventually: 125 * mib, reserve: 19 * mib) == nil)
    // what the image already holds counts toward the library here too
    #expect(SparseBundleMirrorEngine.roomVerdict(needs: 100 * mib, held: 90 * mib, imageBytes: .max,
                                                 freeNow: 40 * mib, freeEventually: 40 * mib, reserve: 19 * mib) == nil)
}
}

@Test func theImageSizeComesFromTheDrive() {
    #expect(MirrorSizing.fromDestination.imageGB(destinationCapacity: 2_000_000_000_000) == 1862)
    #expect(MirrorSizing.fromDestination.imageGB(destinationCapacity: nil) == MirrorSizing.unknownCapacityGB)
    #expect(MirrorSizing.fromDestination.imageGB(destinationCapacity: 0) == MirrorSizing.unknownCapacityGB)
    #expect(MirrorSizing.fromDestination.imageGB(destinationCapacity: 100 << 20) == 1)     // never 0
    #expect(MirrorSizing.fixed(gb: 7).imageGB(destinationCapacity: 2_000_000_000_000) == 7)
}

// Held to what the drive can back: the image fills before the drive does, so a run
// that runs out of room fails as an ordinary full disk instead of losing band writes.
@Test func theImageIsHeldToWhatItsDriveCanBack() {
    let gib: UInt64 = 1 << 30
    // plenty of room: the ceiling applies
    #expect(MirrorSizing.targetBytes(ceiling: 100 * gib, held: 10 * gib, free: 500 * gib, reserve: gib, minimum: 0) == 100 * gib)
    // a nearly full drive: what's held plus what's free, less the reserve
    #expect(MirrorSizing.targetBytes(ceiling: 100 * gib, held: 10 * gib, free: 5 * gib, reserve: gib, minimum: 0) == 14 * gib)
    // less free than the reserve: no room to grow into, but never below hdiutil's minimum
    #expect(MirrorSizing.targetBytes(ceiling: 100 * gib, held: 10 * gib, free: gib / 2, reserve: gib, minimum: 11 * gib) == 11 * gib)
    // a drive that won't say: the ceiling
    #expect(MirrorSizing.targetBytes(ceiling: 100 * gib, held: 10 * gib, free: nil, reserve: gib, minimum: 0) == 100 * gib)
    #expect(MirrorSizing.reserve(capacity: 380 << 20) == 19 << 20)
    #expect(MirrorSizing.reserve(capacity: 4000 * gib) == gib)
}

@Suite(.serialized) struct MirrorSizingOnDisk {

    // A URL keeps the resource values it has read, and the app holds a job's
    // destination URL as long as it runs: the free-space check went on seeing the room
    // the drive had the first time it looked. (Found because it let a mirror's image
    // be grown past what its drive could hold.)
    @Test func freeSpaceIsReadFreshThroughTheSameURL() throws {
        let scratch = tempDir("fresh")
        let drive = try scratchDrive("200m", in: scratch)
        defer { MountPoint.detach(drive, runner: ProcessCommandRunner()); try? FileManager.default.removeItem(at: scratch) }
        let dest = drive.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let before = try #require(JobExecutor.freeSpace(for: dest))
        let reportedBefore = try #require(StorageReporter.volume(of: dest).free)
        try Data(count: 80 << 20).write(to: drive.appendingPathComponent("filler.bin"))
        let after = try #require(JobExecutor.freeSpace(for: dest))
        let reportedAfter = try #require(StorageReporter.volume(of: dest).free)
        #expect(after + (60 << 20) < before, "80 MB written, free space went from \(before) to \(after)")
        #expect(reportedAfter + (60 << 20) < reportedBefore, "the storage view still shows \(reportedAfter)")
    }

    @Test func aNewMirrorIsMadeAsBigAsItsDrive() throws {
        let scratch = tempDir("drive"), base = tempDir("base")
        let src = try library(files: 3)
        let drive = try scratchDrive("3g", in: scratch)
        defer {
            MountPoint.detach(drive, runner: ProcessCommandRunner())
            for d in [scratch, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) }
        }
        let result = try SparseBundleMirrorEngine(mountBase: base).archive(ArchiveSource(name: "Lib", root: src), to: drive.appendingPathComponent("Lib"))
        let capacity = try #require(StorageReporter.volume(of: drive).total)
        let size = try imageBytes(result.artifacts[0])
        #expect(size <= capacity && size + (1 << 30) > capacity, "image \(size) for a drive of \(capacity)")
    }

    // A mirror made at a fixed size (every pre-1.6 mirror, 500 GB unless changed)
    // filled up from inside while the drive still had room. A job's run now grows it.
    @Test func aMirrorSmallerThanItsDriveIsGrown() throws {
        let src = try library(files: 3)
        let dest = tempDir("grow"), base = tempDir("base")
        defer { for d in [dest, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        let out = dest.appendingPathComponent("Lib")
        let bundle = try SparseBundleMirrorEngine(sizeGB: 1, mountBase: base).archive(ArchiveSource(name: "Lib", root: src), to: out).artifacts[0]
        #expect(try imageBytes(bundle) < 2 << 30)

        // what a job saved before 1.6 says: a fixed 1 GB
        let target = Target.localVolume(id: "t", name: "Disk", dir: dest)
        _ = try EngineFactory.engine(for: .liveMirror(sizeGB: 1), target: target).archive(ArchiveSource(name: "Lib", root: src), to: out)
        // as big as the drive, or as the room the drive has left, whichever is less
        let capacity = try #require(StorageReporter.volume(of: dest).total)
        let free = try #require(JobExecutor.freeNow(for: dest))
        #expect(try imageBytes(bundle) + (2 << 30) > min(capacity, free), "the mirror wasn't grown to its drive")
    }

    // A library that no longer fits on the drive used to fail part-way through rsync,
    // with the drive full. It is refused before anything is written, and says why.
    @Test func aLibraryTheDriveCanNotHoldIsRefusedBeforeAnythingIsWritten() throws {
        let scratch = tempDir("small"), base = tempDir("base")
        let src = try library(files: 5)
        let drive = try scratchDrive("512m", in: scratch)
        defer {
            MountPoint.detach(drive, runner: ProcessCommandRunner())
            for d in [scratch, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) }
        }
        let out = drive.appendingPathComponent("Lib")
        let engine = SparseBundleMirrorEngine(mountBase: base)
        let bundle = try engine.archive(ArchiveSource(name: "Lib", root: src, sizeHint: JobExecutor.directorySize(src)), to: out).artifacts[0]

        // the library grows past what the drive has left
        try Data(count: 640 << 20).write(to: src.appendingPathComponent("big.bin"))
        let spy = RsyncSpy()
        #expect(throws: MirrorSpaceError.self) {
            try SparseBundleMirrorEngine(runner: spy, mountBase: base)
                .archive(ArchiveSource(name: "Lib", root: src, sizeHint: JobExecutor.directorySize(src)), to: out)
        }
        #expect(!spy.ranRsync, "rsync ran on a drive that couldn't hold the library")
        #expect(MirrorMounts.mountPoints(of: bundle, runner: ProcessCommandRunner()).isEmpty)
        #expect(!MirrorSeal.isOpen(out), "a refused run left the mirror marked open")
        let check = try ChecksumVerifier().reverify(archiveDir: out)
        #expect(check.passed, "\(check.details)")
    }
}

extension MirrorSizingOnDisk {
    // A first run on a drive with room for the library but not for the reserve kept
    // free beside it: refused before an image is made, and the message is about the
    // drive. It used to make the image, find it too small, and say "the mirror's disk
    // image holds 93 MB".
    @Test func aFirstRunOnADriveShortOfTheReserveMakesNoImage() throws {
        let scratch = tempDir("reserve"), base = tempDir("base")
        let src = tempDir("reservesrc").appendingPathComponent("Lib")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        for i in 0..<10 { try Data(count: 10 << 20).write(to: src.appendingPathComponent("p\(i).raw")) }
        let drive = try scratchDrive("380m", in: scratch)
        defer {
            MountPoint.detach(drive, runner: ProcessCommandRunner())
            for d in [scratch, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) }
        }
        let needs = JobExecutor.directorySize(src)
        let margin = min(needs / 20, 1 << 30)
        let reserve = MirrorSizing.reserve(capacity: StorageReporter.volume(of: drive).total)
        // leave room for the library and its margin, and half the reserve
        let leave = needs + margin + reserve / 2
        let filler = drive.appendingPathComponent("other.bin")
        FileManager.default.createFile(atPath: filler.path, contents: nil)
        let h = try #require(FileHandle(forWritingAtPath: filler.path))
        while let now = JobExecutor.freeNow(for: drive), now > leave + (1 << 20) {
            try h.write(contentsOf: Data(count: Int(min(now - leave, 8 << 20))))
            try h.synchronize()
        }
        try h.close()
        let free = try #require(JobExecutor.freeNow(for: drive))
        try #require(free >= needs + margin && free < needs + margin + reserve, "free \(free) is outside the gap this is about")

        let out = drive.appendingPathComponent("Lib")
        var failure: Error?
        do {
            _ = try SparseBundleMirrorEngine(mountBase: base).archive(ArchiveSource(name: "Lib", root: src, sizeHint: needs), to: out)
        } catch { failure = error }
        if case .notEnoughRoomBesideReserve? = failure as? MirrorSpaceError {} else {
            Issue.record("expected a refusal about the drive's reserve, got \(String(describing: failure))")
        }
        #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("Lib.sparsebundle").path),
                "an image was made for a run that was then refused")
        #expect(!MirrorSeal.isOpen(out))
    }
}

private final class RsyncSpy: CommandRunner, @unchecked Sendable {
    let inner = ProcessCommandRunner()
    private(set) var ranRsync = false
    var forTeardown: CommandRunner { inner }
    func run(_ launchPath: String, _ args: [String], stdin: Data?) throws -> CommandResult {
        if (launchPath as NSString).lastPathComponent == "rsync" { ranRsync = true }
        return try inner.run(launchPath, args, stdin: stdin)
    }
}
