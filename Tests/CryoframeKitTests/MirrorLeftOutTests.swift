//
//  MirrorLeftOutTests.swift
//  CryoframeKitTests
//
//  Named pipes, sockets and devices are left out of a live mirror, and the run
//  says so. They are connections a running program makes and hold no data, and
//  openrsync can't copy them here (see MirrorCopy.isLeftOut), so a mirror of a
//  folder holding one used to fail every run.
//

import Testing
import Foundation
@testable import CryoframeKit

private let hdiutil = "/usr/bin/hdiutil"

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-left-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

/// a socket file in `dir`, bound from inside it: a socket's path may be only 104 bytes
private func makeSocket(_ name: String, in dir: URL) throws {
    let made = try ProcessCommandRunner().run("/bin/sh", ["-c", "cd '\(dir.path)' && /usr/bin/python3 -c \"import socket; socket.socket(socket.AF_UNIX).bind('\(name)')\""])
    try #require(made.ok, "couldn't make a socket: \(made.stderr)")
}

private func specials(in dir: URL) -> [String] {
    var out: [String] = []
    guard let walker = FileManager.default.enumerator(atPath: dir.path) else { return out }
    while let rel = walker.nextObject() as? String {
        var st = stat()
        if lstat(dir.appendingPathComponent(rel).path, &st) == 0, MirrorCopy.isLeftOut(st.st_mode) { out.append(rel) }
    }
    return out.sorted()
}

private func sync(_ src: URL, into next: URL) throws -> [String] {
    let runner = ProcessCommandRunner()
    return try MirrorCopy.sync(src, into: next, runner: runner) { cmd in
        let r = try runner.run(cmd.tool, cmd.args, stdin: nil)
        guard r.ok else { throw ArchiveError.toolFailed(tool: cmd.tool, status: r.status, stderr: r.stderr) }
    }
}

private func unlock(_ d: URL) {
    _ = try? ProcessCommandRunner().run("/bin/chmod", ["-R", "u+rwx", d.path])
}

@Suite(.serialized) struct MirrorLeftOutTests {

    // The copy holds everything but the pipe and the socket, reads back clean, and
    // the sync says what it left out. Each way the sync runs: nothing read-only, a
    // read-only file (a second pass), and a read-only file whose name holds a
    // backslash (no filters at all).
    @Test(arguments: ["plain", "readonly", "backslash"])
    func pipesAndSocketsAreLeftOutAndTheRestReadsBackClean(_ variant: String) throws {
        let base = folder(variant)
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        let src = base.appendingPathComponent("Lib"), next = base.appendingPathComponent("copy")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("tools"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: src.appendingPathComponent("notes.txt"))
        try #require(mkfifo(src.appendingPathComponent("build.pipe").path, 0o644) == 0)
        try #require(mkfifo(src.appendingPathComponent("tools/deep.pipe").path, 0o644) == 0)
        try makeSocket("editor.sock", in: src)
        if variant != "plain" {
            let name = variant == "backslash" ? "odd\\name.txt" : "objects.pack"
            let f = src.appendingPathComponent(name)
            try Data("packed".utf8).write(to: f)
            #expect(chmod(f.path, 0o444) == 0)
        }
        let left = try sync(src, into: next)
        #expect(left.sorted() == ["build.pipe", "editor.sock", "tools/deep.pipe"])
        #expect(specials(in: next).isEmpty, "\(specials(in: next))")
        #expect(FileManager.default.fileExists(atPath: next.appendingPathComponent("notes.txt").path))
        let found = try MirrorCopy.structure(of: next, against: src, previous: nil, control: nil)
        #expect(found.count == 0, "\(found.examples)")
    }

    // A copy made before they were left out can hold a pipe (one without attributes
    // did copy). It is taken out, and the copy reads back clean.
    @Test func aPipeAnEarlierCopyHeldIsTakenOut() throws {
        let base = folder("earlier")
        defer { try? FileManager.default.removeItem(at: base) }
        let src = base.appendingPathComponent("Lib"), next = base.appendingPathComponent("copy")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: src.appendingPathComponent("a.txt"))
        try #require(mkfifo(src.appendingPathComponent("p.pipe").path, 0o644) == 0)
        try #require(mkfifo(next.appendingPathComponent("p.pipe").path, 0o644) == 0)
        try #require(mkfifo(next.appendingPathComponent("gone.pipe").path, 0o644) == 0)
        _ = try sync(src, into: next)
        #expect(specials(in: next).isEmpty, "\(specials(in: next))")
        #expect(try MirrorCopy.structure(of: next, against: src, previous: nil, control: nil).count == 0)
    }

    @Test func theRunNoteNamesThemAndSaysWhy() throws {
        let base = folder("note")
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("x".utf8).write(to: base.appendingPathComponent("x.txt"))
        try #require(mkfifo(base.appendingPathComponent("build.pipe").path, 0o644) == 0)
        let stats = JobExecutor.directoryStats(base, forMirror: true)
        #expect(stats.dmgBlockers.counts == [.special: 1])
        let note = try #require(stats.dmgBlockers.leftOutOfMirror(library: "Projects"))
        #expect(note.hasPrefix("Projects: left 1 named pipe, socket or device out of the mirror (build.pipe)."), "\(note)")
        #expect(note.contains("hold no data"))
        #expect(DMGBlockers().leftOutOfMirror(library: "Projects") == nil)
        // owners and modes don't matter to a mirror: only these are looked for
        #expect(JobExecutor.directoryStats(base).dmgBlockers.isEmpty)
    }

    // A whole run of a mirror job over a library holding a pipe and a socket: it
    // succeeds, and its warning names them.
    @Test func aMirrorRunSucceedsAndItsWarningNamesThem() async throws {
        let base = folder("run")
        let mnt = base.appendingPathComponent("vol")
        try FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)
        // the library on a volume that isn't APFS, so the run reads it where it is (no
        // snapshot), as the fake helper can't make one
        let made = try ProcessCommandRunner().run(hdiutil, ["create", "-size", "20m", "-fs", "HFS+", "-volname", "Src",
                                                            base.appendingPathComponent("src.dmg").path])
        try #require(made.ok, "\(made.stderr)")
        let attached = try DiskImageGate.serialized {
            try ProcessCommandRunner().runRetryingBusy(hdiutil, ["attach", base.appendingPathComponent("src.dmg").path,
                                                                 "-mountpoint", mnt.path, "-nobrowse", "-owners", "on"])
        }
        try #require(attached.ok && MountPoint.isMounted(mnt), "\(attached.stderr)")
        defer {
            MountPoint.detach(mnt, runner: ProcessCommandRunner())
            try? FileManager.default.removeItem(at: base)
        }
        let lib = mnt.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: lib.appendingPathComponent("main.swift"))
        try #require(mkfifo(lib.appendingPathComponent("build.pipe").path, 0o644) == 0)
        try makeSocket("editor.sock", in: lib)
        let dest = base.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let projects = ContentType.genericFolder(id: "projects", displayName: "Projects", path: .absolute(lib.path))
        let job = BackupJob(name: "Projects", libraries: [projects], target: .localVolume(id: "d", name: "Dest", dir: dest),
                            format: .liveMirror(sizeGB: 1), frequency: .manual, createdAt: Date(timeIntervalSince1970: 0))
        let exec = JobExecutor(helper: FakePrivilegedHelper(), detector: FakeProcessDetector(),
                               scratchBase: base.appendingPathComponent("scratch"))
        let outcome = try await exec.run(job, ownerUID: getuid(), now: Date())
        guard case .finished(let results, let warning) = outcome else { Issue.record("\(outcome)"); return }
        guard case .completed? = results.first else { Issue.record("\(results)"); return }
        #expect(warning?.contains("Projects: left 2 named pipes, sockets or devices out of the mirror") == true, "\(warning ?? "no warning")")
        #expect(warning?.contains("build.pipe") == true && warning?.contains("editor.sock") == true)
    }
}
