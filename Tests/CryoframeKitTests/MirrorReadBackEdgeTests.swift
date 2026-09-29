//
//  MirrorReadBackEdgeTests.swift
//  CryoframeKitTests
//
//  The fourth round of mirror edges: what the read-back before the swap compares,
//  and whether the up-front room check and the cap on the image agree.
//

import Testing
import Foundation
@testable import CryoframeKit

private let hdiutil = "/usr/bin/hdiutil"

/// a fresh folder, named by its real path (see MirrorEdgeTests' edgeDir)
private func rbDir(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-mrb-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

private func randomData(_ n: Int) -> Data {
    var d = Data(count: n)
    d.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, n) }
    return d
}

private func xattr(_ url: URL, _ name: String) -> [UInt8]? {
    let n = getxattr(url.path, name, nil, 0, 0, 0)
    guard n >= 0 else { return nil }
    var v = [UInt8](repeating: 0, count: n)
    _ = getxattr(url.path, name, &v, n, 0, 0)
    return v
}

private func lookInside<T>(_ bundle: URL, _ body: (URL) throws -> T) throws -> T {
    let mnt = rbDir("look")
    defer { MountPoint.detach(mnt, runner: ProcessCommandRunner()); try? FileManager.default.removeItem(at: mnt) }
    let r = try DiskImageGate.serialized {
        try ProcessCommandRunner().runRetryingBusy(hdiutil, ["attach", bundle.path, "-mountpoint", mnt.path, "-nobrowse", "-readonly"])
    }
    try #require(r.ok && MountPoint.isMounted(mnt), "\(r.stderr)")
    return try body(mnt)
}

@Suite(.serialized) struct MirrorReadBackEdgeTests {

    // The read-back compares every written file's data with the library, and the
    // structure of everything else; it doesn't read extended attributes. A resource
    // fork (or any attribute) is written through the same image and lost the same way
    // when the drive fills for an instant. Here one is lost after rsync, same length,
    // different bytes, and the run must not put that copy in place as a success.
    @Test func aResourceForkLostOnTheWayToTheDriveIsCaughtBeforeTheSwap() throws {
        let src = rbDir("forksrc").appendingPathComponent("Lib")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let doc = src.appendingPathComponent("doc.txt")
        try Data("body".utf8).write(to: doc)
        let fork = randomData(4096)
        #expect(fork.withUnsafeBytes { setxattr(doc.path, "com.apple.ResourceFork", $0.baseAddress, 4096, 0, 0) } == 0)
        try Data("other".utf8).write(to: src.appendingPathComponent("other.txt"))
        let out = rbDir("fork"), base = rbDir("base")
        defer { for d in [out, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        let bundle = try SparseBundleMirrorEngine(sizeGB: 1, mountBase: base).archive(ArchiveSource(name: "Lib", root: src), to: out).artifacts[0]

        // the fork changes; the run writes it; the write is lost on its way
        let fork2 = randomData(4096)
        #expect(fork2.withUnsafeBytes { setxattr(doc.path, "com.apple.ResourceFork", $0.baseAddress, 4096, 0, 0) } == 0)
        let loses = LosesAFork()
        _ = try? SparseBundleMirrorEngine(sizeGB: 1, runner: loses, mountBase: base).archive(ArchiveSource(name: "Lib", root: src), to: out)
        try #require(loses.lost, "no fork was lost, so this proves nothing")

        let inMirror = try lookInside(bundle) { xattr($0.appendingPathComponent("Lib/doc.txt"), "com.apple.ResourceFork") }
        #expect(inMirror == [UInt8](fork) || inMirror == [UInt8](fork2),
                "the run put in place a copy whose resource fork is neither the old nor the new one")
    }

    // The room check refuses a run the drive can't hold: the library less what the
    // image holds, plus a margin of 5% of the library (at most 1 GiB). The cap on the
    // image keeps 5% of the drive (at most 1 GiB) free. When the library is small
    // beside the drive, the margin is smaller than the reserve, and a run with free
    // space between the two passes the check and then runs out of room inside the
    // image. It has to be refused up front instead, with nothing written into the
    // image: measured, the image made at free-now less the reserve is then found too
    // small for the library and the run is refused (imageTooSmall).
    @Test func aRunThatPassesTheRoomCheckFits() throws {
        let scratch = rbDir("gap"), base = rbDir("base")
        let src = rbDir("gapsrc").appendingPathComponent("Lib")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        for i in 0..<10 { try randomData(10 << 20).write(to: src.appendingPathComponent("p\(i).raw")) }
        let made = try ProcessCommandRunner().run(hdiutil, ["create", "-size", "380m", "-fs", "APFS", "-volname", "Drive", "-type", "SPARSE",
                                                            scratch.appendingPathComponent("drive").path])
        try #require(made.ok, "\(made.stderr)")
        let drive = scratch.appendingPathComponent("mnt")
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        let a = try DiskImageGate.serialized {
            try ProcessCommandRunner().runRetryingBusy(hdiutil, ["attach", scratch.appendingPathComponent("drive.sparseimage").path, "-mountpoint", drive.path, "-nobrowse"])
        }
        try #require(a.ok, "\(a.stderr)")
        defer {
            MountPoint.detach(drive, runner: ProcessCommandRunner())
            for d in [scratch, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) }
        }

        // leave free what the check asks for and a little more, still short of the reserve
        let needs = JobExecutor.directorySize(src)
        let margin = min(needs / 20, 1 << 30)
        let reserve = MirrorSizing.reserve(capacity: StorageReporter.volume(of: drive).total)
        try #require(margin + (4 << 20) < reserve, "margin \(margin) isn't below the reserve \(reserve), so this proves nothing")
        let leave = needs + margin + (reserve - margin) / 2
        let filler = drive.appendingPathComponent("other.bin")
        let h = try #require(FileHandle(forWritingAtPath: { FileManager.default.createFile(atPath: filler.path, contents: nil); return filler.path }()))
        while let now = JobExecutor.freeNow(for: drive), now > leave + (1 << 20) {
            try h.write(contentsOf: Data(count: Int(min(now - leave, 8 << 20))))
            try h.synchronize()
        }
        try h.close()
        let free = try #require(JobExecutor.freeNow(for: drive))
        try #require(free >= needs + margin && free < needs + reserve, "free \(free) isn't between \(needs + margin) and \(needs + reserve)")

        let out = drive.appendingPathComponent("Lib")
        var failure: Error?
        do {
            _ = try SparseBundleMirrorEngine(mountBase: base).archive(ArchiveSource(name: "Lib", root: src, sizeHint: needs), to: out)
        } catch { failure = error }
        if let failure {
            #expect(failure is MirrorSpaceError, "passed the room check, then failed writing: \(failure)")
        }
    }
}

/// loses the resource fork rsync wrote: overwrites it in staging with other bytes of
/// the same length after the last rsync pass
private final class LosesAFork: CommandRunner, @unchecked Sendable {
    let inner = ProcessCommandRunner()
    private(set) var lost = false
    var forTeardown: CommandRunner { inner }
    func run(_ launchPath: String, _ args: [String], stdin: Data?) throws -> CommandResult {
        let r = try inner.run(launchPath, args, stdin: stdin)
        if (launchPath as NSString).lastPathComponent == "rsync", !lost, r.ok, let dest = args.last {
            let doc = URL(fileURLWithPath: dest).appendingPathComponent("doc.txt").path
            var junk = [UInt8](repeating: 0, count: 4096)
            arc4random_buf(&junk, 4096)
            // writing a fork moves the file's date; a lost write wouldn't, so put it back
            let date = (try? FileManager.default.attributesOfItem(atPath: doc))?[.modificationDate] as? Date
            if setxattr(doc, "com.apple.ResourceFork", junk, 4096, 0, 0) == 0, let date {
                try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: doc)
                lost = true
            }
        }
        return r
    }
}
