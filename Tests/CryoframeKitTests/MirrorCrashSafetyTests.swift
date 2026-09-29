//
//  MirrorCrashSafetyTests.swift
//  CryoframeKitTests
//
//  The live mirror is the only copy of a library. A run that stops, fails or
//  crashes part-way must leave the last complete copy exactly as it was, and the
//  next run must finish the job from whatever was left.
//

import Testing
import Foundation
@testable import CryoframeKit

private func tempDir(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-mcs-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private let hdiutil = "/usr/bin/hdiutil"

/// a library of `n` small files, half of them in a subfolder.
private func library(files n: Int) throws -> URL {
    let lib = tempDir("lib").appendingPathComponent("Lib")
    try FileManager.default.createDirectory(at: lib.appendingPathComponent("sub"), withIntermediateDirectories: true)
    for i in 0..<n { try Data("v1 file \(i)".utf8).write(to: lib.appendingPathComponent(i % 2 == 0 ? "f\(i).txt" : "sub/f\(i).txt")) }
    return lib
}

/// every file under `root` by relative path, with its contents.
private func tree(_ root: URL) -> [String: Data] {
    var out: [String: Data] = [:]
    let base = root.resolvingSymlinksInPath().path
    let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
    while let u = walker?.nextObject() as? URL {
        guard (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
        let p = u.resolvingSymlinksInPath().path
        out[String(p.dropFirst(base.count))] = try? Data(contentsOf: u)
    }
    return out
}

/// the mirror's library copy and whatever else is at the image's root, read-only.
private func insideMirror(_ bundle: URL) throws -> (library: [String: Data], root: [String]) {
    let mnt = tempDir("look")
    defer { MountPoint.detach(mnt, runner: ProcessCommandRunner()); try? FileManager.default.removeItem(at: mnt) }
    let r = try DiskImageGate.serialized {
        try ProcessCommandRunner().runRetryingBusy(hdiutil, ["attach", bundle.path, "-mountpoint", mnt.path, "-nobrowse", "-readonly"])
    }
    try #require(r.ok, "couldn't attach the mirror to look inside: \(r.stderr)")
    let root = (try FileManager.default.contentsOfDirectory(atPath: mnt.path)).filter { $0 != ".fseventsd" }.sorted()
    return (tree(mnt.appendingPathComponent("Lib")), root)
}

/// change every file in the library, delete a few, add a few: a run's worth of work.
private func editEverything(_ lib: URL, files n: Int) throws {
    for i in 0..<n where i % 5 != 0 {
        try Data("v2 file \(i)".utf8).write(to: lib.appendingPathComponent(i % 2 == 0 ? "f\(i).txt" : "sub/f\(i).txt"))
    }
    for i in stride(from: 0, to: n, by: 5) {
        try FileManager.default.removeItem(at: lib.appendingPathComponent(i % 2 == 0 ? "f\(i).txt" : "sub/f\(i).txt"))
    }
    for i in 0..<4 { try Data("new \(i)".utf8).write(to: lib.appendingPathComponent("sub/new\(i).txt")) }
}

/// A run that dies part-way through its rsync. The real rsync is run over half the
/// tree (everything but `sub/`, so the other half is left exactly as it was), and
/// the run is then stopped as if Stop had landed mid-transfer.
private struct DiesMidRsync: CommandRunner {
    let inner = ProcessCommandRunner()
    var forTeardown: CommandRunner { inner }
    func run(_ launchPath: String, _ args: [String], stdin: Data?) throws -> CommandResult {
        guard (launchPath as NSString).lastPathComponent == "rsync" else { return try inner.run(launchPath, args, stdin: stdin) }
        let partial = try inner.run(launchPath, ["--exclude", "sub/"] + args, stdin: stdin)
        #expect(partial.ok, "\(partial.stderr)")
        throw CancelledError()
    }
}

@Suite(.serialized) struct MirrorCrashSafety {

    // Before: rsync --delete rewrote the only copy in place, so a run that stopped
    // part-way left a library that was half one day and half the next. The copy a
    // restore reads now stays exactly the previous complete one.
    @Test func aRunThatDiesMidRsyncLeavesThePreviousCopyWhole() throws {
        let src = try library(files: 40)
        let out = tempDir("die"), base = tempDir("base")
        defer { for d in [out, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        let bundle = try SparseBundleMirrorEngine(sizeGB: 1, mountBase: base)
            .archive(ArchiveSource(name: "Lib", root: src), to: out).artifacts[0]
        let before = tree(src)

        try editEverything(src, files: 40)
        #expect(throws: CancelledError.self) {
            try SparseBundleMirrorEngine(sizeGB: 1, runner: DiesMidRsync(), mountBase: base)
                .archive(ArchiveSource(name: "Lib", root: src), to: out)
        }
        let inside = try insideMirror(bundle)
        #expect(inside.library == before, "the copy a restore reads was changed by a run that didn't finish")
    }

    // The next run takes whatever the dead one left in staging and finishes the job:
    // the library matches the source exactly and nothing is left beside it.
    @Test func theRunAfterACrashRepairsWhatWasLeft() throws {
        let src = try library(files: 40)
        let out = tempDir("repair"), base = tempDir("base")
        defer { for d in [out, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        let engine = SparseBundleMirrorEngine(sizeGB: 1, mountBase: base)
        let bundle = try engine.archive(ArchiveSource(name: "Lib", root: src), to: out).artifacts[0]
        try editEverything(src, files: 40)
        _ = try? SparseBundleMirrorEngine(sizeGB: 1, runner: DiesMidRsync(), mountBase: base)
            .archive(ArchiveSource(name: "Lib", root: src), to: out)
        #expect(try insideMirror(bundle).root.contains(MirrorCopy.stagingName), "the dead run should have left its work in staging")

        _ = try engine.archive(ArchiveSource(name: "Lib", root: src), to: out)
        let inside = try insideMirror(bundle)
        #expect(inside.library == tree(src))
        #expect(inside.root == ["Lib"], "left behind at the image's root: \(inside.root)")
    }

    // Stop pressed for real while rsync is copying: the rsync process is terminated.
    @Test func stoppingWhileRsyncIsCopyingLeavesThePreviousCopyWhole() throws {
        let src = try library(files: 40)
        let out = tempDir("stop"), base = tempDir("base")
        defer { for d in [out, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        let bundle = try SparseBundleMirrorEngine(sizeGB: 1, mountBase: base)
            .archive(ArchiveSource(name: "Lib", root: src), to: out).artifacts[0]
        let before = tree(src)
        // enough new data that rsync is still at it when the first new file lands
        try editEverything(src, files: 40)
        let bulk = src.appendingPathComponent("bulk")
        try FileManager.default.createDirectory(at: bulk, withIntermediateDirectories: true)
        for i in 0..<400 { try Data(repeating: UInt8(i % 251), count: 256 * 1024).write(to: bulk.appendingPathComponent("b\(i).bin")) }

        let control = RunControl()
        let stopper = StopOnceCopying(inner: ProcessCommandRunner(control: control), base: base)
        #expect(throws: CancelledError.self) {
            try SparseBundleMirrorEngine(sizeGB: 1, runner: stopper, mountBase: base)
                .archive(ArchiveSource(name: "Lib", root: src), to: out)
        }
        #expect(stopper.stoppedWhileCopying, "Stop didn't land while rsync was running, so this proves nothing")
        #expect(try insideMirror(bundle).library == before)
    }

    // After a completed run, a restore returns the new state, not the old one.
    @Test func aRestoreAfterTheSwapReturnsTheNewCopy() throws {
        let src = try library(files: 20)
        let out = tempDir("restore"), base = tempDir("base"), back = tempDir("back")
        defer { for d in [out, base, back, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        let engine = SparseBundleMirrorEngine(sizeGB: 1, mountBase: base)
        _ = try engine.archive(ArchiveSource(name: "Lib", root: src), to: out)
        try editEverything(src, files: 20)
        let result = try engine.archive(ArchiveSource(name: "Lib", root: src), to: out)
        try ArchiveManifest.write(try ArchiveManifest.build(for: result), toDir: out)

        let archive = try #require(RestoreDiscovery.archive(at: out))
        let restored = try RestoreEngine().restore(archive, to: back)
        #expect(tree(restored) == tree(src))
    }

    // The copy being updated must be a clone: a copy of a large library inside the
    // image would double its size on every run.
    @Test func theStagingCopyIsAClone() throws {
        let src = try library(files: 10)
        try Data(repeating: 0x5A, count: 64 << 20).write(to: src.appendingPathComponent("big.bin"))
        let out = tempDir("clone"), base = tempDir("base")
        defer { for d in [out, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        _ = try SparseBundleMirrorEngine(sizeGB: 1, mountBase: base).archive(ArchiveSource(name: "Lib", root: src), to: out)

        let meter = UsageAtRsync()
        _ = try SparseBundleMirrorEngine(sizeGB: 1, runner: meter, mountBase: base).archive(ArchiveSource(name: "Lib", root: src), to: out)
        let (atAttach, atRsync) = try #require(meter.usage)
        #expect(atRsync >= atAttach)
        #expect(atRsync - atAttach < 8 << 20, "the staging copy took \(atRsync - atAttach) bytes for a 64 MB library")
    }

    // Every standard home folder carries a deny-delete ACL, which rsync -E copies
    // onto the mirror's top folder. A folder with one can't be renamed, so the swap
    // has to lift it, and put it back on the new copy.
    @Test func aLibraryWhoseFolderDeniesDeleteIsStillSwapped() throws {
        let src = try library(files: 6)
        let out = tempDir("acl"), base = tempDir("base")
        defer {
            _ = try? ProcessCommandRunner().run("/bin/chmod", ["-R", "-N", src.path])
            for d in [out, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) }
        }
        for dir in [src, src.appendingPathComponent("sub")] {
            let r = try ProcessCommandRunner().run("/bin/chmod", ["+a", "everyone deny delete", dir.path])
            try #require(r.ok, "\(r.stderr)")
        }
        let engine = SparseBundleMirrorEngine(sizeGB: 1, mountBase: base)
        let bundle = try engine.archive(ArchiveSource(name: "Lib", root: src), to: out).artifacts[0]
        try editEverything(src, files: 6)
        _ = try engine.archive(ArchiveSource(name: "Lib", root: src), to: out)

        let inside = try insideMirror(bundle)
        #expect(inside.library == tree(src))
        #expect(inside.root == ["Lib"], "the previous copy was left behind: \(inside.root)")
        let mnt = tempDir("acl-look")
        defer { MountPoint.detach(mnt, runner: ProcessCommandRunner()); try? FileManager.default.removeItem(at: mnt) }
        let r = try DiskImageGate.serialized { try ProcessCommandRunner().runRetryingBusy(hdiutil, ["attach", bundle.path, "-mountpoint", mnt.path, "-nobrowse", "-readonly"]) }
        try #require(r.ok)
        let ls = try ProcessCommandRunner().run("/bin/ls", ["-led", mnt.appendingPathComponent("Lib").path])
        #expect(ls.stdout.contains("deny delete"), "the new copy lost its folder's ACL:\n\(ls.stdout)")
    }

    // A drill of a mirror checks what a restore would copy, not the whole volume: a
    // copy left in staging by a crash isn't counted as part of the library.
    @Test func aDrillLooksOnlyAtTheLibraryCopy() throws {
        let src = try library(files: 10)
        let out = tempDir("drill"), base = tempDir("base")
        defer { for d in [out, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        let result = try SparseBundleMirrorEngine(sizeGB: 1, mountBase: base).archive(ArchiveSource(name: "Lib", root: src), to: out)
        try editEverything(src, files: 10)
        _ = try? SparseBundleMirrorEngine(sizeGB: 1, runner: DiesMidRsync(), mountBase: base)
            .archive(ArchiveSource(name: "Lib", root: src), to: out)

        let type = ContentType.genericFolder(id: "l", displayName: "Lib", path: .home("Lib"))
        let rep = try StrongVerifier().verify(result, type: type)
        #expect(rep.passed, "\(rep.details)")
        #expect(rep.details.contains("10 file(s)"), "\(rep.details)")
    }
}

/// presses Stop once rsync has written a new file into the staging copy.
private final class StopOnceCopying: CommandRunner, @unchecked Sendable {
    let inner: ProcessCommandRunner
    let base: URL
    private(set) var stoppedWhileCopying = false
    init(inner: ProcessCommandRunner, base: URL) { self.inner = inner; self.base = base }
    var control: RunControl? { inner.control }
    var forTeardown: CommandRunner { inner.forTeardown }
    func run(_ launchPath: String, _ args: [String], stdin: Data?) throws -> CommandResult {
        guard (launchPath as NSString).lastPathComponent == "rsync", let dest = args.last else {
            return try inner.run(launchPath, args, stdin: stdin)
        }
        let marker = URL(fileURLWithPath: dest).appendingPathComponent("bulk/b0.bin").path
        let control = inner.control
        let watcher = Thread { [weak self] in
            let start = ProcessInfo.processInfo.systemUptime
            while ProcessInfo.processInfo.systemUptime - start < 60 {
                if FileManager.default.fileExists(atPath: marker) {
                    self?.stoppedWhileCopying = true
                    control?.cancel(); return
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        watcher.start()
        return try inner.run(launchPath, args, stdin: stdin)
    }
}

/// the image volume's used bytes when it is attached, and again when rsync starts.
private final class UsageAtRsync: CommandRunner, @unchecked Sendable {
    let inner = ProcessCommandRunner()
    var forTeardown: CommandRunner { inner }
    private var atAttach: UInt64?
    private(set) var usage: (UInt64, UInt64)?
    func run(_ launchPath: String, _ args: [String], stdin: Data?) throws -> CommandResult {
        let tool = (launchPath as NSString).lastPathComponent
        if tool == "rsync", let dest = args.last, let a = atAttach { usage = (a, Self.used(dest)) }
        let r = try inner.run(launchPath, args, stdin: stdin)
        if tool == "hdiutil", args.first == "attach", r.ok, let i = args.firstIndex(of: "-mountpoint") {
            atAttach = Self.used(args[i + 1])
        }
        return r
    }
    static func used(_ path: String) -> UInt64 {
        sync()
        var s = statfs()
        guard statfs(path, &s) == 0 else { return 0 }
        return (UInt64(s.f_blocks) - UInt64(s.f_bfree)) * UInt64(s.f_bsize)
    }
}
