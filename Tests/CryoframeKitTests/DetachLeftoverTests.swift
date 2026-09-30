//
//  DetachLeftoverTests.swift
//  CryoframeKitTests
//
//  A mirror run must never be refused over a disk image attach of its own, or over
//  one that ends by itself. Seen on CI (macOS 26): the third of three back-to-back
//  runs of the same mirror refused "attached with nothing mounted".
//
//  Measured on macOS 26.7: `hdiutil detach <mount point>` while another process has
//  the image's disk open unmounts the volume, then fails the eject ("couldn't eject
//  disk4 - Resource busy", exit 16), and the image stays attached with nothing
//  mounted after that process lets go.
//

import Testing
import Foundation
@testable import CryoframeKit

private let hdiutil = "/usr/bin/hdiutil"

private func scratch(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-detachleft-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

/// the image's attaches, as `hdiutil info` lists them
private func attaches(of image: URL) -> [MirrorMounts.Attach] {
    let target = image.resolvingSymlinksInPath().path
    return (MirrorMounts.attachesIfKnown(runner: ProcessCommandRunner()) ?? [])
        .filter { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == target }
}

/// a process that holds `device` open for `seconds`
private func holdOpen(_ device: String, for seconds: Double) throws -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "exec 3< \(device); sleep \(seconds)"]
    try p.run()
    Thread.sleep(forTimeInterval: 0.3)
    return p
}

@Suite(.serialized) struct DetachLeftoverTests {

    // A detach whose eject comes back busy leaves the image attached with nothing
    // mounted, and a later mirror run of the same process was refused over it. The
    // detach follows its attach until it has gone.
    @Test func aDetachWhoseEjectComesBackBusyLeavesNothingAttached() throws {
        let dir = scratch("busy")
        let img = dir.appendingPathComponent("B.sparsebundle"), mnt = dir.appendingPathComponent("mnt")
        defer {
            ArchiveReader.detachOrphans(ofImage: img, runner: ProcessCommandRunner())
            try? FileManager.default.removeItem(at: dir)
        }
        let made = try ProcessCommandRunner().run(hdiutil, ["create", "-size", "64m", "-type", "SPARSEBUNDLE", "-fs", "APFS",
                                                            "-volname", "B", img.path])
        try #require(made.ok, "\(made.stderr)")
        try FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)
        let attached = try ProcessCommandRunner().runRetryingBusy(hdiutil, ["attach", "-readonly", "-nobrowse", "-mountpoint", mnt.path, img.path])
        try #require(attached.ok && MountPoint.isMounted(mnt), "\(attached.stderr)")
        let whole = try #require(attaches(of: img).first?.devices.first)

        let holder = try holdOpen(whole, for: 1.5)
        MountPoint.detach(mnt, runner: ProcessCommandRunner())
        holder.waitUntilExit()

        #expect(!MountPoint.isMounted(mnt))
        #expect(attaches(of: img).isEmpty, "left attached: \(attaches(of: img).map(\.devices))")
    }

    // An attach of the mirror's image with nothing mounted that isn't Cryoframe's and
    // ends by itself a moment later (a scan by macOS, a detach still finishing): the
    // run waits it out and goes ahead. It never detaches it: the attach's own detach,
    // made after the run began, still finds it there.
    @Test func aMirrorRunWaitsOutAnAttachThatEndsByItself() throws {
        let src = scratch("src").appendingPathComponent("Lib")
        let out = scratch("out"), base = scratch("base")
        defer { for d in [out, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: src.appendingPathComponent("one.txt"))
        let engine = SparseBundleMirrorEngine(sizeGB: 1, mountBase: base)
        let bundle = try engine.archive(ArchiveSource(name: "Lib", root: src), to: out).artifacts[0]
        defer { ArchiveReader.detachOrphans(ofImage: bundle, runner: ProcessCommandRunner()) }

        let held = try ProcessCommandRunner().runRetryingBusy(hdiutil, ["attach", "-nomount", "-readonly", "-nobrowse", bundle.path])
        try #require(held.ok, "\(held.stderr)")
        let whole = try #require(held.stdout.split(whereSeparator: \.isWhitespace).first(where: { $0.hasPrefix("/dev/disk") }).map(String.init))
        let ends = Process()
        ends.executableURL = URL(fileURLWithPath: "/bin/sh")
        ends.arguments = ["-c", "sleep 3; \(hdiutil) detach -force \(whole)"]
        try ends.run()

        try Data("two".utf8).write(to: src.appendingPathComponent("two.txt"))
        #expect(throws: Never.self) { try engine.archive(ArchiveSource(name: "Lib", root: src), to: out) }
        ends.waitUntilExit()
        #expect(ends.terminationStatus == 0, "the run detached the other attach itself")
        #expect(attaches(of: bundle).isEmpty)
    }
}
