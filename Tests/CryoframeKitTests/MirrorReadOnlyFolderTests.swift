//
//  MirrorReadOnlyFolderTests.swift
//  CryoframeKitTests
//
//  A mirror of a library holding folders their owner can't write to (0555), as Go's
//  module cache (~/go/pkg/mod) is throughout: a file deleted from such a folder, a
//  file added to one, and a whole read-only folder deleted. rsync --delete runs as the
//  user, and a folder the user can't write is one nothing can be removed from.
//

import Testing
import Foundation
@testable import CryoframeKit

private func dir(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-mirrorro-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

private func put(_ root: URL, _ rel: String, _ text: String) throws {
    let url = root.appendingPathComponent(rel)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

@Suite(.serialized) struct MirrorReadOnlyFolderTests {

    @Test func aMirrorOfReadOnlyFoldersRunsAfterADeletion() throws {
        let base = dir("base")
        defer {
            _ = try? ProcessCommandRunner().run("/bin/chmod", ["-R", "u+w", base.path], stdin: nil)
            try? FileManager.default.removeItem(at: base)
        }
        let src = base.appendingPathComponent("Lib"), out = base.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        func chmod(_ rel: String, _ mode: mode_t) { _ = Darwin.chmod(src.appendingPathComponent(rel).path, mode) }
        func mirror(_ what: String) -> URL? {
            do {
                return try SparseBundleMirrorEngine(sizeGB: 1, mountBase: base)
                    .archive(ArchiveSource(name: "Lib", root: src), to: out).artifacts.first
            } catch {
                Issue.record("\(what): \(error)")
                return nil
            }
        }
        try put(src, "mod/a.txt", "a")
        try put(src, "mod/b.txt", "b")
        try put(src, "mod/inner/c.txt", "c")
        try put(src, "gone/x.txt", "x")
        try put(src, "keep.txt", "k")
        for rel in ["mod/inner", "mod", "gone"] { chmod(rel, 0o555) }
        _ = mirror("the first run")

        // a file deleted from a read-only folder, one added to another, and a whole
        // read-only folder deleted
        chmod("mod", 0o755)
        try FileManager.default.removeItem(at: src.appendingPathComponent("mod/b.txt"))
        chmod("mod", 0o555)
        chmod("mod/inner", 0o755)
        try put(src, "mod/inner/d.txt", "d")
        chmod("mod/inner", 0o555)
        chmod("gone", 0o755)
        try FileManager.default.removeItem(at: src.appendingPathComponent("gone"))
        guard let image = mirror("the run after a deletion") else { return }

        // what the image holds: the library as it is now, its folders still read-only
        let mount = base.appendingPathComponent("look", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let attached = try DiskImageGate.serialized {
            try ProcessCommandRunner().runRetryingBusy("/usr/bin/hdiutil", ["attach", image.path, "-readonly", "-nobrowse", "-mountpoint", mount.path])
        }
        try #require(attached.ok, "couldn't attach the mirror: \(attached.stderr)")
        defer { MountPoint.detach(mount, runner: ProcessCommandRunner()) }
        let copy = mount.appendingPathComponent("Lib")
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: copy.appendingPathComponent("mod/b.txt").path))
        #expect(!fm.fileExists(atPath: copy.appendingPathComponent("gone").path))
        #expect(fm.fileExists(atPath: copy.appendingPathComponent("mod/inner/d.txt").path))
        for rel in ["mod", "mod/inner"] {
            var st = stat()
            #expect(lstat(copy.appendingPathComponent(rel).path, &st) == 0 && st.st_mode & 0o7777 == 0o555, "\(rel) is \(String(st.st_mode & 0o7777, radix: 8))")
        }
    }
}
