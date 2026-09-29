//
//  MirrorMountTests.swift
//  CryoframeKitTests
//
//  Where a mirror run attaches its image, and how a crashed run's attach is found
//  again without disturbing a live one.
//

import Testing
import Foundation
@testable import CryoframeKit

private func tempDir(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-mm-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func library(files n: Int) throws -> URL {
    let lib = tempDir("lib").appendingPathComponent("Lib")
    try FileManager.default.createDirectory(at: lib.appendingPathComponent("sub"), withIntermediateDirectories: true)
    for i in 0..<n { try Data("file \(i)".utf8).write(to: lib.appendingPathComponent(i % 2 == 0 ? "f\(i).txt" : "sub/f\(i).txt")) }
    return lib
}

private let hdiutil = "/usr/bin/hdiutil"

private func attach(_ image: URL, at mnt: URL, _ extra: [String] = []) throws {
    try FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)
    let r = try DiskImageGate.serialized {
        try ProcessCommandRunner().runRetryingBusy(hdiutil, ["attach", image.path, "-mountpoint", mnt.path, "-nobrowse"] + extra)
    }
    try #require(r.ok && MountPoint.isMounted(mnt), "couldn't attach \(image.lastPathComponent): \(r.stderr)")
}

/// regular files inside the mirror's library folder, read through a read-only attach.
private func filesInMirror(_ bundle: URL) throws -> Int {
    let mnt = tempDir("count")
    defer { MountPoint.detach(mnt, runner: ProcessCommandRunner()); try? FileManager.default.removeItem(at: mnt) }
    try attach(bundle, at: mnt, ["-readonly"])
    var n = 0
    let walker = FileManager.default.enumerator(at: mnt.appendingPathComponent("Lib"), includingPropertiesForKeys: [.isRegularFileKey])
    while let u = walker?.nextObject() as? URL {
        if (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { n += 1 }
    }
    return n
}

/// a mirror-run directory as MirrorMounts makes one, owned by `owner`.
private func runDir(in base: URL, owner: ProcessIdentity) throws -> URL {
    let work = base.appendingPathComponent(MirrorMounts.prefix + UUID().uuidString)
    try FileManager.default.createDirectory(at: work.appendingPathComponent("mnt"), withIntermediateDirectories: true)
    try JSONEncoder().encode(owner).write(to: work.appendingPathComponent(OpenedArchive.ownerFileName))
    return work
}

private var deadOwner: ProcessIdentity {
    let me = ProcessIdentity.current!
    return ProcessIdentity(pid: me.pid, startedAt: me.startedAt - 1)      // same pid, earlier life
}

@Suite(.serialized) struct MirrorMountTests {

    // External drives are mounted with ownership ignored. macOS refuses a mount point
    // on such a volume, and the mirror used to attach at <dest>/.<name>.mirror-mnt, so
    // every mirror run to one failed: "hdiutil: attach failed - Permission denied".
    @Test func aMirrorToADriveThatIgnoresOwnershipWorks() throws {
        let scratch = tempDir("owners")
        let host = scratch.appendingPathComponent("drive")
        let base = tempDir("base")
        let src = try library(files: 10)
        defer {
            MountPoint.detach(host, runner: ProcessCommandRunner())
            for d in [scratch, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) }
        }
        let made = try ProcessCommandRunner().run(hdiutil, ["create", "-size", "1g", "-fs", "APFS", "-volname", "Drive",
                                                            "-type", "SPARSE", scratch.appendingPathComponent("drive").path])
        try #require(made.ok, "\(made.stderr)")
        try attach(scratch.appendingPathComponent("drive.sparseimage"), at: host)      // no -owners on: like a real external drive
        let info = try ProcessCommandRunner().run("/usr/sbin/diskutil", ["info", host.path])
        try #require(info.stdout.split(separator: "\n").contains { $0.contains("Owners:") && $0.contains("Disabled") },
                     "the scratch drive doesn't ignore ownership, so this proves nothing:\n\(info.stdout)")

        let dest = host.appendingPathComponent("Backups/Lib")
        let result = try SparseBundleMirrorEngine(sizeGB: 1, mountBase: base).archive(ArchiveSource(name: "Lib", root: src), to: dest)
        #expect(try filesInMirror(result.artifacts[0]) == 10)
        #expect(MirrorMounts.mountPoints(of: result.artifacts[0], runner: ProcessCommandRunner()).isEmpty)
        // the drive's lock file stays by design (see VolumeLock); nothing else should
        let left = try FileManager.default.contentsOfDirectory(atPath: base.path).filter { !$0.hasPrefix("cf-volume-lock-") }
        #expect(left.isEmpty, "the run left its mount directory behind: \(left)")
        let beside = try FileManager.default.contentsOfDirectory(atPath: dest.path)
            .filter { $0 != "Lib.sparsebundle" && $0 != ArchiveManifest.sidecarName }
        #expect(beside.isEmpty, "the run wrote into the destination beside the mirror: \(beside)")
    }

    // A run that crashed left the image attached at its own directory. The next run
    // detaches it there and carries on; it doesn't delete through it or give up.
    @Test func aMirrorLeftAttachedByACrashedRunIsReleased() throws {
        let src = try library(files: 12)
        let out = tempDir("crash"), base = tempDir("base")
        defer { for d in [out, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        let engine = SparseBundleMirrorEngine(sizeGB: 1, mountBase: base)
        let bundle = try engine.archive(ArchiveSource(name: "Lib", root: src), to: out).artifacts[0]

        let crashed = try runDir(in: base, owner: deadOwner)
        let mnt = crashed.appendingPathComponent("mnt")
        try attach(bundle, at: mnt)
        defer { MountPoint.detach(mnt, runner: ProcessCommandRunner()) }

        try Data("new".utf8).write(to: src.appendingPathComponent("added.txt"))
        _ = try engine.archive(ArchiveSource(name: "Lib", root: src), to: out)
        #expect(!MountPoint.isMounted(mnt))
        #expect(!FileManager.default.fileExists(atPath: crashed.path))
        #expect(try filesInMirror(bundle) == 13)
    }

    // The same attach with a live owner is a run in progress (or something else with
    // the mirror open). It is left alone, and this run refuses to write.
    @Test func aMirrorALiveRunHasAttachedIsLeftAlone() throws {
        let src = try library(files: 4)
        let out = tempDir("live"), base = tempDir("base")
        defer { for d in [out, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        let engine = SparseBundleMirrorEngine(sizeGB: 1, mountBase: base)
        let bundle = try engine.archive(ArchiveSource(name: "Lib", root: src), to: out).artifacts[0]

        let live = try runDir(in: base, owner: ProcessIdentity.current!)
        let mnt = live.appendingPathComponent("mnt")
        try attach(bundle, at: mnt)
        defer { MountPoint.detach(mnt, runner: ProcessCommandRunner()) }

        #expect(throws: (any Error).self) { try engine.archive(ArchiveSource(name: "Lib", root: src), to: out) }
        #expect(MountPoint.isMounted(mnt), "a live run's mirror was detached")
        #expect(FileManager.default.fileExists(atPath: mnt.appendingPathComponent("Lib/f0.txt").path))
    }

    // So that a restore can open the mirror again before the job next runs, the launch
    // sweep releases a crashed run's attach too. Not a live one's.
    @Test func theLaunchSweepReleasesOnlyADeadRunsMirror() throws {
        let base = tempDir("sweep")
        defer { try? FileManager.default.removeItem(at: base) }
        var images: [URL] = []
        for name in ["Dead", "Live"] {
            let src = tempDir("src-\(name)")
            try Data(name.utf8).write(to: src.appendingPathComponent("a.txt"))
            let r = try ProcessCommandRunner().run(hdiutil, ["create", "-srcfolder", src.path, "-format", "UDRW",
                                                            base.appendingPathComponent("\(name).dmg").path])
            try? FileManager.default.removeItem(at: src)
            try #require(r.ok, "\(r.stderr)")
            images.append(base.appendingPathComponent("\(name).dmg"))
        }
        let dead = try runDir(in: base, owner: deadOwner)
        let live = try runDir(in: base, owner: ProcessIdentity.current!)
        try attach(images[0], at: dead.appendingPathComponent("mnt"))
        try attach(images[1], at: live.appendingPathComponent("mnt"))
        defer {
            MountPoint.detach(dead.appendingPathComponent("mnt"), runner: ProcessCommandRunner())
            MountPoint.detach(live.appendingPathComponent("mnt"), runner: ProcessCommandRunner())
        }

        ArchiveReader.sweepStaleOpens(in: base)
        #expect(!MountPoint.isMounted(dead.appendingPathComponent("mnt")))
        #expect(!FileManager.default.fileExists(atPath: dead.path))
        #expect(MountPoint.isMounted(live.appendingPathComponent("mnt")), "the sweep detached a live run's mirror")
    }

    // An image that is already open used to fail after 13 seconds of retries with
    // hdiutil's own "attach failed - Resource busy". Now it's recognized at once and
    // said plainly, for a reader and for a mirror run alike.
    @Test func anImageAlreadyOpenIsSaidToBeOpenWithoutWaiting() throws {
        let src = try library(files: 4)
        let out = tempDir("inuse"), base = tempDir("base")
        defer { for d in [out, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        let engine = SparseBundleMirrorEngine(sizeGB: 1, mountBase: base)
        let result = try engine.archive(ArchiveSource(name: "Lib", root: src), to: out)
        let first = try ArchiveReader(workBase: base).open(result)
        defer { first.close() }

        var start = ProcessInfo.processInfo.systemUptime
        #expect(throws: DiskImageInUse.self) { _ = try ArchiveReader(workBase: base).open(result) }
        #expect(ProcessInfo.processInfo.systemUptime - start < 5, "a reader waited out the busy retries first")
        start = ProcessInfo.processInfo.systemUptime
        #expect(throws: DiskImageInUse.self) { _ = try engine.archive(ArchiveSource(name: "Lib", root: src), to: out) }
        #expect(ProcessInfo.processInfo.systemUptime - start < 5, "a mirror run waited out the busy retries first")
        // one that would grow the image first: refused before the resize, which on an
        // open image failed EAGAIN after the retries and left the mirror marked open
        start = ProcessInfo.processInfo.systemUptime
        #expect(throws: DiskImageInUse.self) {
            _ = try SparseBundleMirrorEngine(sizeGB: 2, mountBase: base).archive(ArchiveSource(name: "Lib", root: src), to: out)
        }
        #expect(ProcessInfo.processInfo.systemUptime - start < 5, "growing an open image waited out the busy retries")
        #expect(!MirrorSeal.isOpen(out), "a run refused before touching the image left it marked open")
        #expect(MountPoint.isMounted(first.root))
    }
}
