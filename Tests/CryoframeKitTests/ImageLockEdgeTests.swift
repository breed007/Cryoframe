//
//  ImageLockEdgeTests.swift
//  CryoframeKitTests
//
//  The image lock coordinates Cryoframe's own attaches. An image attached outside
//  Cryoframe with nothing mounted (Disk Utility's First Aid, `hdiutil attach
//  -nomount` in Terminal, a script) takes no lock, so to every Cryoframe cleanup
//  it looks like an orphan. Opening that image to restore from it must leave the
//  holder's disk alone.
//

import Testing
import Foundation
@testable import CryoframeKit

private let hdiutil = "/usr/bin/hdiutil"

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-lockedge-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

@Suite(.serialized) struct ImageLockEdgeTests {
    // A sealed encrypted DMG attached outside Cryoframe without a mount, read-only
    // or read-write. Cryoframe opens it to restore, then closes it. The outside
    // holder still has its disk afterwards.
    @Test(arguments: ["read-only", "read-write"])
    func anOutsideAttachWithoutAMountKeepsItsDiskThroughARestore(_ mode: String) throws {
        let base = folder(mode == "read-only" ? "ro" : "rw")
        var image: URL?
        defer {
            if let image {
                for d in MirrorMounts.attachedDevices(of: image, runner: ProcessCommandRunner()).prefix(1) {
                    _ = try? ProcessCommandRunner().run(hdiutil, ["detach", "-force", d])
                }
            }
            try? FileManager.default.removeItem(at: base)
        }
        let lib = base.appendingPathComponent("src/Documents")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: lib.appendingPathComponent("a.txt"))
        let dir = base.appendingPathComponent("dest/Documents")
        let result = try SealedArchiveEngine(.dmg, passphrase: "right").archive(ArchiveSource(name: "Documents", root: lib), to: dir)
        image = result.artifacts.first
        let img = try #require(image)

        // the outside holder (as Disk Utility or Terminal would attach it)
        var args = ["attach", "-nomount", "-stdinpass", img.path]
        if mode == "read-only" { args.insert("-readonly", at: 1) }
        var held = try ProcessCommandRunner().run(hdiutil, args, stdin: Data("right".utf8))
        let until = ProcessInfo.processInfo.systemUptime + 60      // the OS scanner (see qa notes)
        while !held.ok, held.stderr.contains("temporarily unavailable"), ProcessInfo.processInfo.systemUptime < until {
            Thread.sleep(forTimeInterval: 2)
            held = try ProcessCommandRunner().run(hdiutil, args, stdin: Data("right".utf8))
        }
        try #require(held.ok, "\(held.stderr)")
        let device = try #require(held.stdout.split(whereSeparator: \.isWhitespace).first(where: { $0.hasPrefix("/dev/disk") }).map(String.init))

        do {
            let opened = try ArchiveReader(workBase: base).open(result, passphrase: "right")
            opened.close()
        } catch {
            // refusing is fine; taking the holder's disk is not
        }
        let after = MirrorMounts.attachedDevices(of: img, runner: ProcessCommandRunner())
        #expect(after.contains(device), "\(mode): the outside holder's \(device) was detached; attached now: \(after)")
    }
}
