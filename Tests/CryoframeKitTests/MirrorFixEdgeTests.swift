//
//  MirrorFixEdgeTests.swift
//  CryoframeKitTests
//
//  The live mirror after the milestone 3 fixes: downloads kept exactly as the
//  library has them even when the file is read-only or locked in Finder, attributes
//  too big or flagged never-copy, the top folder checked after the swap, and a
//  library holding a named pipe or a socket.
//
//  Measured on macOS 26.7: openrsync can't make a socket at all ("mkstempsock:
//  Invalid argument", exit 23, with or without -E; the mirror's staging path is
//  already past the 104 bytes a socket's path may have), and with -E it fails on a
//  named pipe that carries any attribute ("copyfile: Operation not supported", exit
//  23). A pipe with none copies. Files this Mac's processes make carry a provenance
//  attribute, so on a Mac in use a pipe usually has one.
//

import Testing
import Foundation
@testable import CryoframeKit

private func dir(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-mfix-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

private func set(_ path: String, _ name: String, _ value: [UInt8]) -> Int32 {
    setxattr(path, name, value, value.count, 0, XATTR_NOFOLLOW)
}

private func unlockAll(_ d: URL) {
    _ = try? ProcessCommandRunner().run("/usr/bin/chflags", ["-R", "nouchg", d.path])
    _ = try? ProcessCommandRunner().run("/bin/chmod", ["-R", "u+rwx", d.path])
}

/// mirror `src` into `out` `times` times; the error of each run, nil for a clean one
private func mirror(_ src: URL, to out: URL, base: URL, times: Int, runner: CommandRunner? = nil,
                    between: (Int) -> Void = { _ in }) -> [String?] {
    (1...times).map { n in
        between(n)
        do {
            let engine = runner.map { SparseBundleMirrorEngine(sizeGB: 1, runner: $0, mountBase: base) }
                ?? SparseBundleMirrorEngine(sizeGB: 1, mountBase: base)
            _ = try engine.archive(ArchiveSource(name: "Lib", root: src), to: out)
            return nil
        } catch {
            return "\(error)"
        }
    }
}

/// Plants an attribute on the new copy's top folder at the detach after the swap:
/// written after the read-back, where only the check after the swap can see it.
private final class TouchesTopAfterSwap: CommandRunner, @unchecked Sendable {
    let inner = ProcessCommandRunner()
    private var staging: URL?
    private var detaches = 0
    private(set) var touched = false
    var forTeardown: CommandRunner { self }
    func run(_ launchPath: String, _ args: [String], stdin: Data?) throws -> CommandResult {
        let tool = (launchPath as NSString).lastPathComponent
        if tool == "hdiutil", args.first == "detach", let staging, !touched {
            detaches += 1
            if detaches == 2 {         // 1: the read-back's; 2: after the swap
                let top = staging.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Lib").path
                touched = set(top, "com.example.planted", [1, 2, 3]) == 0
            }
        }
        let r = try inner.run(launchPath, args, stdin: stdin)
        if tool == "rsync", r.ok, staging == nil, let dest = args.last { staging = URL(fileURLWithPath: dest) }
        return r
    }
}

@Suite(.serialized) struct MirrorFixEdgeTests {

    // A folder of projects with a program's named pipe and socket in it (a build
    // server, an editor, ssh). Every mirror run failed on them with rsync's own
    // error. They hold no data: the run either leaves them out and succeeds, or
    // names them up front, as the sealed formats now do.
    @Test func aLiveMirrorOfALibraryHoldingAPipeAndASocketIsMirroredOrNamedUpFront() throws {
        let src = dir("special").appendingPathComponent("Lib")
        let out = dir("special-out"), base = dir("base")
        defer { for d in [out, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: src.appendingPathComponent("notes.txt"))
        try #require(mkfifo(src.appendingPathComponent("build.pipe").path, 0o644) == 0)
        // a socket's path is limited to 104 bytes, so it is bound from inside the folder
        let made = try ProcessCommandRunner().run("/bin/sh", ["-c", "cd '\(src.path)' && /usr/bin/python3 -c \"import socket; socket.socket(socket.AF_UNIX).bind('editor.sock')\""])
        try #require(made.ok, "couldn't make a socket: \(made.stderr)")
        let runs = mirror(src, to: out, base: base, times: 2)
        for (i, r) in runs.enumerated() {
            guard let r else { continue }
            #expect(r.contains("build.pipe") && r.contains("editor.sock") && !r.contains("rsync"),
                    "run \(i + 1) failed without naming the pipe and socket: \(r)")
        }
    }

    // Downloads that are read-only (a saved attachment) or locked in Finder: the
    // library's quarantine has to be written onto a copy that refuses writes.
    @Test func lockedAndReadOnlyDownloadsMirrorCleanly() throws {
        let src = dir("locked").appendingPathComponent("Lib")
        let out = dir("locked-out"), base = dir("base")
        defer { unlockAll(src.deletingLastPathComponent()); unlockAll(out)
                for d in [out, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        let saved = src.appendingPathComponent("Saved")
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
        for (name, agent) in [("readonly.pdf", "Mail"), ("locked.pdf", "Safari"), ("Saved/inside.zip", "Safari"), ("plain.pdf", "Safari")] {
            let f = src.appendingPathComponent(name)
            try Data("body of \(name)".utf8).write(to: f)
            #expect(set(f.path, "com.apple.quarantine", Array("0083;66f9a1b2;\(agent);8E3C2F7A-1B2C-4D5E-9F00-112233445566".utf8)) == 0)
        }
        #expect(chmod(src.appendingPathComponent("readonly.pdf").path, 0o444) == 0)
        #expect(chmod(saved.appendingPathComponent("inside.zip").path, 0o444) == 0)
        #expect(chmod(saved.path, 0o555) == 0)
        #expect(chflags(src.appendingPathComponent("locked.pdf").path, UInt32(UF_IMMUTABLE)) == 0)
        let runs = mirror(src, to: out, base: base, times: 3) { n in
            if n == 3 {   // a download's quarantine changes (opened and approved, say)
                _ = set(src.appendingPathComponent("plain.pdf").path, "com.apple.quarantine",
                        Array("00c3;66f9a1b2;Safari;8E3C2F7A-1B2C-4D5E-9F00-112233445566".utf8))
            }
        }
        for (i, r) in runs.enumerated() { #expect(r == nil, "run \(i + 1): \(r ?? "")") }
    }

    // Attributes openrsync's AppleDouble transfer may not carry as they are: large
    // values, a large resource fork, and names flagged never to be copied ("#N").
    @Test func largeAndNeverCopyAttributesMirrorCleanly() throws {
        let src = dir("big").appendingPathComponent("Lib")
        let out = dir("big-out"), base = dir("base")
        defer { for d in [out, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let f = src.appendingPathComponent("heavy.txt").path
        try Data("heavy".utf8).write(to: URL(fileURLWithPath: f))
        #expect(set(f, "com.example.big", Array(repeating: 0x5A, count: 200_000)) == 0)
        #expect(set(f, "com.apple.ResourceFork", (0..<3_000_000).map { UInt8($0 % 251) }) == 0)
        #expect(set(f, "com.example.never#N", [1, 2, 3]) == 0)
        #expect(set(f, "com.apple.quarantine", Array("0083;66f9a1b2;Safari;".utf8)) == 0)
        let runs = mirror(src, to: out, base: base, times: 2)
        for (i, r) in runs.enumerated() { #expect(r == nil, "run \(i + 1): \(r ?? "")") }
    }

    // Something written onto the top folder after the read-back (the swap puts its
    // access list back then) is caught by the check after the swap, and the next run
    // puts it right.
    @Test func aTopFolderChangedAfterTheSwapIsCaughtAndRepaired() throws {
        let src = dir("top").appendingPathComponent("Lib")
        let out = dir("top-out"), base = dir("base")
        defer { for d in [out, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: src.appendingPathComponent("a.txt"))
        #expect(mirror(src, to: out, base: base, times: 1) == [nil])
        try Data("b".utf8).write(to: src.appendingPathComponent("b.txt"))
        let touch = TouchesTopAfterSwap()
        let second = mirror(src, to: out, base: base, times: 1, runner: touch)
        try #require(touch.touched, "nothing was planted, so this proves nothing")
        #expect(second[0]?.contains("topFolderNotRestored") == true, "\(second[0] ?? "the run succeeded")")
        #expect(mirror(src, to: out, base: base, times: 1) == [nil], "the next run didn't put it right")
    }
}
