//
//  MirrorSafetyTests.swift
//  CryoframeKitTests
//
//  The live mirror is the only copy of a library, and it is written in place. These
//  cover the ways a run could destroy it while trying to clean up.
//

import Testing
import Foundation
@testable import CryoframeKit

private func tempDir(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func library(files n: Int) throws -> URL {
    let lib = tempDir("lib").appendingPathComponent("Lib")
    try FileManager.default.createDirectory(at: lib.appendingPathComponent("sub"), withIntermediateDirectories: true)
    for i in 0..<n { try Data("file \(i)".utf8).write(to: lib.appendingPathComponent(i % 2 == 0 ? "f\(i).txt" : "sub/f\(i).txt")) }
    return lib
}

/// regular files inside the mirror image, read through a read-only attach.
private func filesInMirror(_ bundle: URL) throws -> Int {
    let mnt = tempDir("count")
    defer { MountPoint.detach(mnt, runner: ProcessCommandRunner()) }
    let r = try ProcessCommandRunner().run("/usr/bin/hdiutil", ["attach", bundle.path, "-mountpoint", mnt.path, "-nobrowse", "-readonly"])
    try #require(r.ok, "couldn't attach the mirror to count it: \(r.stderr)")
    var n = 0
    let walker = FileManager.default.enumerator(at: mnt, includingPropertiesForKeys: [.isRegularFileKey])
    while let u = walker?.nextObject() as? URL {
        if u.path.contains("/.fseventsd") || u.lastPathComponent.hasPrefix(".") { continue }
        if (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { n += 1 }
    }
    return n
}

/// presses Stop the moment the run is about to launch one particular tool.
private struct StopBefore: CommandRunner {
    let inner: ProcessCommandRunner
    let tool: String
    var control: RunControl? { inner.control }
    var forTeardown: CommandRunner { inner.forTeardown }
    func run(_ launchPath: String, _ args: [String], stdin: Data?) throws -> CommandResult {
        if (launchPath as NSString).lastPathComponent == tool { inner.control?.cancel() }
        return try inner.run(launchPath, args, stdin: stdin)
    }
}

// Stop during a mirror run used to delete the mirror. The run's own runner refuses
// to launch anything once stopped, so the cleanup's detach never ran, and the
// cleanup then removed the mount directory recursively, straight through the
// still-attached image. Measured before the fix: 30 files, then 0.
@Test func stoppingAMirrorRunLeavesTheMirrorWhole() throws {
    let src = try library(files: 30)
    let out = tempDir("mirror")
    defer { try? FileManager.default.removeItem(at: out); try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }
    let bundle = try SparseBundleMirrorEngine(sizeGB: 1).archive(ArchiveSource(name: "Lib", root: src), to: out).artifacts[0]
    #expect(try filesInMirror(bundle) == 30)

    let stopper = StopBefore(inner: ProcessCommandRunner(control: RunControl()), tool: "rsync")
    #expect(throws: CancelledError.self) {
        try SparseBundleMirrorEngine(sizeGB: 1, runner: stopper).archive(ArchiveSource(name: "Lib", root: src), to: out)
    }
    #expect(!MountPoint.isMounted(out.appendingPathComponent(".Lib.mirror-mnt")), "the stopped run left the mirror attached")
    #expect(try filesInMirror(bundle) == 30, "stopping the run destroyed the mirror")
}

// A run that crashed leaves the image attached at the mirror's mountpoint. The next
// run cleared that directory with a recursive remove, which emptied the image before
// attaching it again, so everything then depended on that run's rsync finishing. Here
// the next run is stopped before rsync: the mirror has to come through it whole.
@Test func aMirrorLeftAttachedByACrashIsDetachedNotEmptied() throws {
    let src = try library(files: 12)
    let out = tempDir("crash")
    defer { try? FileManager.default.removeItem(at: out); try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }
    let bundle = try SparseBundleMirrorEngine(sizeGB: 1).archive(ArchiveSource(name: "Lib", root: src), to: out).artifacts[0]

    let mnt = out.appendingPathComponent(".Lib.mirror-mnt")
    try FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)
    let r = try ProcessCommandRunner().run("/usr/bin/hdiutil", ["attach", bundle.path, "-mountpoint", mnt.path, "-nobrowse"])
    try #require(r.ok && MountPoint.isMounted(mnt), "couldn't stage the leftover attach: \(r.stderr)")

    let stopper = StopBefore(inner: ProcessCommandRunner(control: RunControl()), tool: "rsync")
    #expect(throws: CancelledError.self) {
        try SparseBundleMirrorEngine(sizeGB: 1, runner: stopper).archive(ArchiveSource(name: "Lib", root: src), to: out)
    }
    #expect(!MountPoint.isMounted(mnt))
    #expect(try filesInMirror(bundle) == 12, "the leftover mount was deleted through, emptying the mirror")
}

// hdiutil answers 0 when asked to attach an image that is already open elsewhere, and
// then nothing is mounted at the mirror's mountpoint. rsync would have written into the
// destination folder itself. The run has to refuse instead.
@Test func aMirrorAlreadyOpenElsewhereIsNotWrittenBesideTheImage() throws {
    let src = try library(files: 6)
    let out = tempDir("busy")
    defer { try? FileManager.default.removeItem(at: out); try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }
    let bundle = try SparseBundleMirrorEngine(sizeGB: 1).archive(ArchiveSource(name: "Lib", root: src), to: out).artifacts[0]

    let browsing = tempDir("browse")
    defer { MountPoint.detach(browsing, runner: ProcessCommandRunner()) }
    let r = try ProcessCommandRunner().run("/usr/bin/hdiutil", ["attach", bundle.path, "-mountpoint", browsing.path, "-nobrowse", "-readonly"])
    try #require(r.ok, "couldn't stage the other open copy: \(r.stderr)")

    #expect(throws: (any Error).self) {
        try SparseBundleMirrorEngine(sizeGB: 1).archive(ArchiveSource(name: "Lib", root: src), to: out)
    }
    let stray = out.appendingPathComponent(".Lib.mirror-mnt/Lib")
    #expect(!FileManager.default.fileExists(atPath: stray.path), "rsync wrote the library into the destination folder, outside the image")
}
