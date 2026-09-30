//
//  AttachRecordEdgeTests.swift
//  CryoframeKitTests
//
//  An attach record lets the next attach detach what a crashed Cryoframe process
//  left. It must never let it detach anyone else's disk: a holder whose disk a
//  reader borrowed, an attach whose helper's pid was handed out again after a
//  restart, or another program's attach made in the same moment as Cryoframe's.
//  These use real hdiutil attaches and a private records folder.
//

import Testing
import Foundation
@testable import CryoframeKit

private let hdiutil = "/usr/bin/hdiutil"

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-recedge-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

/// a small plain sparsebundle in `dir`
private func plainImage(in dir: URL) throws -> URL {
    let img = dir.appendingPathComponent("Lib.sparsebundle")
    let r = try ProcessCommandRunner().run(hdiutil, ["create", "-size", "20m", "-type", "SPARSEBUNDLE", "-fs", "APFS",
                                                     "-volname", "Lib", img.path])
    try #require(r.ok, "\(r.stderr)")
    return img
}

/// attach `img` as another program would, waiting out the OS scanner's hold (see qa notes)
private func outsideAttach(_ img: URL, _ extra: [String]) throws -> CommandResult {
    let args = ["attach"] + extra + [img.path]
    var r = try ProcessCommandRunner().run(hdiutil, args)
    let until = ProcessInfo.processInfo.systemUptime + 60
    while !r.ok, r.stderr.contains("temporarily unavailable"), ProcessInfo.processInfo.systemUptime < until {
        Thread.sleep(forTimeInterval: 2)
        r = try ProcessCommandRunner().run(hdiutil, args)
    }
    return r
}

private func detachAll(_ img: URL) {
    for d in MirrorMounts.attachedDevices(of: img, runner: ProcessCommandRunner()).sorted(by: { $0.count < $1.count }).prefix(1) {
        _ = try? ProcessCommandRunner().run(hdiutil, ["detach", "-force", d])
    }
}

/// a process that has run and exited, as it was while it ran
private func exitedProcess() throws -> ProcessIdentity {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sleep")
    p.arguments = ["30"]
    try p.run()
    let who = ProcessIdentity.of(pid: p.processIdentifier)
    p.terminate()
    p.waitUntilExit()
    return try #require(who)
}

private func records(in base: URL) -> [URL] {
    (try? FileManager.default.contentsOfDirectory(at: AttachRecords.folder(in: base), includingPropertiesForKeys: nil)) ?? []
}

@Suite(.serialized) struct AttachRecordEdgeTests {
    // A plain image held read-only with nothing mounted, by another program. A
    // reader's attach hands back the holder's own disk (measured on macOS 26). The
    // reader then crashes. Nothing may be recorded as the reader's, so the next
    // attach leaves the holder's disk alone. Also when the holder attached after
    // the reader listed the image's devices.
    @Test(arguments: ["listed before", "missed by the listing"])
    func aReaderThatBorrowedAHoldersDiskRecordsNothing(_ how: String) throws {
        let base = folder("borrow")
        let img = try plainImage(in: base)
        defer { detachAll(img); try? FileManager.default.removeItem(at: base) }
        let held = try outsideAttach(img, ["-readonly", "-nomount"])
        try #require(held.ok, "\(held.stderr)")
        let holder = MirrorMounts.attachedDevices(of: img, runner: ProcessCommandRunner())
        try #require(!holder.isEmpty)
        let dead = try exitedProcess()

        let lock = try #require(ImageLock.acquire(img, wait: 30, in: base))
        let before: Set<String> = how == "listed before" ? Set(holder) : []
        Thread.sleep(forTimeInterval: 0.05)
        let borrowed = try AttachRecords.recording(img, sparing: before, runner: ProcessCommandRunner(), owner: dead, in: base) {
            try ProcessCommandRunner().run(hdiutil, ["attach", "-readonly", "-nomount", img.path])
        }
        #expect(records(in: base).isEmpty, "\(how): the holder's attach was recorded as the reader's (hdiutil said \(borrowed.status))")
        AttachRecords.releaseLeftovers(of: img, runner: ProcessCommandRunner(), holding: lock, in: base)
        lock.release()
        #expect(Set(MirrorMounts.attachedDevices(of: img, runner: ProcessCommandRunner())) == Set(holder),
                "\(how): the holder's disk was detached")
    }

    // A record written before a restart. Its helper's pid now belongs to the
    // disk-image process serving another program's attach of the same image, on
    // the same device names. The start time differs, so the record is not that
    // attach's: the disk stays and the record goes.
    @Test func aRecordFromBeforeARestartLeavesTheAttachThatHasItsPidNow() throws {
        let base = folder("reboot")
        let img = try plainImage(in: base)
        defer { detachAll(img); try? FileManager.default.removeItem(at: base) }
        let held = try outsideAttach(img, ["-readonly", "-nomount"])
        try #require(held.ok, "\(held.stderr)")
        let attach = try #require(MirrorMounts.attachesIfKnown(runner: ProcessCommandRunner())?
            .first { AttachRecords.key($0.path) == AttachRecords.key(img.path) })
        let helper = try #require(attach.helper.flatMap { ProcessIdentity.of(pid: $0) })

        let stale = AttachRecords.Record(image: AttachRecords.key(img.path), devices: attach.devices,
                                         helper: ProcessIdentity(pid: helper.pid, startedAt: helper.startedAt - 86_400),
                                         owner: try exitedProcess())
        let dir = AttachRecords.folder(in: base)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(stale).write(to: dir.appendingPathComponent("stale.json"))

        let lock = try #require(ImageLock.acquire(img, wait: 30, in: base))
        AttachRecords.releaseLeftovers(of: img, runner: ProcessCommandRunner(), holding: lock, in: base)
        lock.release()
        #expect(Set(MirrorMounts.attachedDevices(of: img, runner: ProcessCommandRunner())) == Set(attach.devices),
                "a record from before a restart detached a later attach")
        #expect(records(in: base).isEmpty, "the stale record stayed")
    }

    // Another program attaches and mounts the same image while Cryoframe's attach
    // is under way (Finder opening it, a script), and Cryoframe's own attach fails.
    // The record takes the other attach for Cryoframe's: it is new and its helper
    // started after the attach began. Mounted, the attach's cleanup spares it. Later
    // its volume is unmounted without ejecting the image, and the Cryoframe process
    // has exited. The next attach must not detach the other program's disk.
    @Test func anotherProgramsAttachMadeDuringOursIsNotRecordedAsOurs() throws {
        let base = folder("race")
        let img = try plainImage(in: base)
        let mnt = base.appendingPathComponent("theirs")
        try FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)
        defer { detachAll(img); try? FileManager.default.removeItem(at: base) }
        let dead = try exitedProcess()

        let lock = try #require(ImageLock.acquire(img, wait: 30, in: base))
        let ours = try AttachRecords.recording(img, sparing: [], runner: ProcessCommandRunner(), owner: dead, in: base) { () throws -> Bool in
            // the other program's attach, in the same moment as ours
            let theirs = try outsideAttach(img, ["-nobrowse", "-mountpoint", mnt.path])
            try #require(theirs.ok, "\(theirs.stderr)")
            // ours: refused, as a read-write attach of an image attached elsewhere is
            return false
        }
        lock.release()
        #expect(!ours)
        let theirs = MirrorMounts.attachedDevices(of: img, runner: ProcessCommandRunner())
        try #require(!theirs.isEmpty && MountPoint.isMounted(mnt))
        let unmounted = try ProcessCommandRunner().run(hdiutil, ["unmount", mnt.path])
        try #require(unmounted.ok, "\(unmounted.stderr)")

        let next = try #require(ImageLock.acquire(img, wait: 30, in: base))
        AttachRecords.releaseLeftovers(of: img, runner: ProcessCommandRunner(), holding: next, in: base)
        next.release()
        #expect(Set(MirrorMounts.attachedDevices(of: img, runner: ProcessCommandRunner())) == Set(theirs),
                "another program's attach was recorded as Cryoframe's and detached (\(records(in: base).count) record(s))")
    }
}
