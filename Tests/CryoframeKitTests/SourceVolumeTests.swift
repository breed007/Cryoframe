//
//  SourceVolumeTests.swift
//  CryoframeKitTests
//
//  Mapping a live path into a snapshot is where external libraries broke: the boot
//  volume needs one rule and every other disk needs another, and using the boot rule
//  everywhere is why a library on an SSD came back "not found".
//

import Testing
import Foundation
@testable import CryoframeKit

private let boot = SourceVolume(mountPoint: "/System/Volumes/Data", fsType: "apfs", name: "Macintosh HD")
private let ssd  = SourceVolume(mountPoint: "/Volumes/Media", fsType: "apfs", name: "Media")
private let card = SourceVolume(mountPoint: "/Volumes/microSD", fsType: "exfat", name: "microSD")

@Test func bootVolumePathsKeepTheirFirmlinkedShape() {
    // /Users is on the data volume but appears at /, so the snapshot holds Users at
    // its root — not under System/Volumes/Data.
    #expect(boot.frozenPath(live: "/Users/me/Pictures/Photos Library.photoslibrary",
                            snapshotMount: "/tmp/snap") == "/tmp/snap/Users/me/Pictures/Photos Library.photoslibrary")
    #expect(boot.isBootData)
    #expect(SourceVolume(mountPoint: "/", fsType: "apfs", name: "x").isBootData)
}

@Test func externalVolumePathsAreRelativeToTheirMountPoint() {
    // this is the case that used to produce "<snapshot>/Volumes/Media/…", a path that
    // exists in no snapshot, and so reported a present library as missing.
    #expect(ssd.frozenPath(live: "/Volumes/Media/Photos Library.photoslibrary",
                           snapshotMount: "/tmp/snap") == "/tmp/snap/Photos Library.photoslibrary")
    #expect(ssd.frozenPath(live: "/Volumes/Media/a/b/c", snapshotMount: "/tmp/snap") == "/tmp/snap/a/b/c")
}

@Test func aPathOnAnotherVolumeHasNoPlaceInThisSnapshot() {
    // catching the mismatch beats mapping it to a plausible path that isn't there.
    #expect(ssd.frozenPath(live: "/Users/me/Pictures/X", snapshotMount: "/tmp/snap") == nil)
    #expect(ssd.frozenPath(live: "/Volumes/MediaOther/X", snapshotMount: "/tmp/snap") == nil)
}

@Test func theVolumeRootItselfMapsToTheSnapshotRoot() {
    #expect(ssd.frozenPath(live: "/Volumes/Media", snapshotMount: "/tmp/snap") == "/tmp/snap")
}

@Test func trailingSlashesDoNotChangeTheAnswer() {
    let v = SourceVolume(mountPoint: "/Volumes/Media/", fsType: "apfs", name: "Media")
    #expect(v.frozenPath(live: "/Volumes/Media/X", snapshotMount: "/tmp/snap/") == "/tmp/snap/X")
}

@Test func onlyAPFSCanBeFrozen() {
    #expect(boot.canSnapshot)
    #expect(ssd.canSnapshot)
    #expect(!card.canSnapshot)      // exFAT: ordinary for a camera card or media drive
    #expect(!SourceVolume(mountPoint: "/Volumes/Old", fsType: "hfs", name: "Old").canSnapshot)
}

@Test func theKernelTellsUsWhereAPathLives() throws {
    // no guessing from the path's shape — that assumption is what broke.
    let home = try #require(VolumeInspector.volume(for: FileManager.default.homeDirectoryForCurrentUser))
    #expect(home.isBootData)
    #expect(home.canSnapshot)       // the boot volume is APFS on any supported Mac
}

// MARK: - resolving a library once its disk is frozen

private func tempTree(_ name: String) -> URL {
    let d = FileManager.default.temporaryDirectory
        .appendingPathComponent("cf-vol-\(UUID().uuidString)").appendingPathComponent(name)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func placement(live: URL?, volume: SourceVolume?) -> JobExecutor.LibraryPlacement {
    JobExecutor.LibraryPlacement(library: .photos, liveRoot: live, volume: volume)
}

@Test func aFrozenLibraryIsReadFromItsOwnVolumesSnapshot() {
    // the snapshot of /Volumes/Media mounted at <snap> holds the library at its root.
    let snap = tempTree("Photos Library.photoslibrary").deletingLastPathComponent()
    let lib = snap.appendingPathComponent("Photos Library.photoslibrary")
    try? FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: snap) }

    let vol = SourceVolume(mountPoint: "/Volumes/Media", fsType: "apfs", name: "Media")
    let p = placement(live: URL(fileURLWithPath: "/Volumes/Media/Photos Library.photoslibrary"), volume: vol)
    #expect(p.root(in: ["/Volumes/Media": snap.path]) == lib)
}

@Test func aVolumeThatCouldNotBeFrozenIsReadLive() {
    // exFAT and HFS+ can't snapshot, so the files are read where they sit. The run
    // refuses to start while that library's app is open, which is what makes it safe.
    let live = tempTree("Music")
    defer { try? FileManager.default.removeItem(at: live.deletingLastPathComponent()) }
    let card = SourceVolume(mountPoint: "/Volumes/microSD", fsType: "exfat", name: "microSD")
    let p = placement(live: live, volume: card)
    #expect(p.root(in: [:]) == live)          // no snapshot for that volume → live path
}

@Test func aLibraryMissingFromTheSnapshotResolvesToNothing() {
    // better to report it than to hand the archiver a path that isn't there.
    let vol = SourceVolume(mountPoint: "/Volumes/Media", fsType: "apfs", name: "Media")
    let p = placement(live: URL(fileURLWithPath: "/Volumes/Media/Gone.photoslibrary"), volume: vol)
    #expect(p.root(in: ["/Volumes/Media": "/tmp/definitely-not-here"]) == nil)
    #expect(placement(live: nil, volume: vol).root(in: [:]) == nil)
}
