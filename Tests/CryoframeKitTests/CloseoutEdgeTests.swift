//
//  CloseoutEdgeTests.swift
//  CryoframeKitTests
//
//  The milestone 3 close-out at its edges: named pipes and sockets that come and
//  go between mirror runs, sit deep in the tree, hide in a read-only folder of an
//  earlier copy, carry names rsync reads as patterns, or are the target of a link;
//  and a cloud download that moves after its fetch returns and then stops.
//

import Testing
import Foundation
@testable import CryoframeKit

private func dir(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-close-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

/// a socket file `name` in `dir`, bound from inside it (a socket's path may be only 104 bytes)
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

private func unlock(_ d: URL) {
    _ = try? ProcessCommandRunner().run("/bin/chmod", ["-R", "u+rwx", d.path])
}

private func sync(_ src: URL, into next: URL) throws -> [String] {
    let runner = ProcessCommandRunner()
    return try MirrorCopy.sync(src, into: next, runner: runner) { cmd in
        let r = try runner.run(cmd.tool, cmd.args, stdin: nil)
        guard r.ok else { throw ArchiveError.toolFailed(tool: cmd.tool, status: r.status, stderr: r.stderr) }
    }
}

private final class Moves: @unchecked Sendable {
    let start = ProcessInfo.processInfo.systemUptime
    var elapsed: TimeInterval { ProcessInfo.processInfo.systemUptime - start }
}

@Suite(.serialized) struct CloseoutEdgeTests {

    // A developer's folder over three runs: a pipe deep in the tree, a socket, and a
    // link to that socket; then a pipe and a socket that appear in a new folder;
    // then all of them gone. Every run succeeds, the links come back as links, and
    // no pipe or socket reaches the restored copy.
    @Test func specialsThatComeAndGoBetweenRunsNeverFailAMirror() throws {
        let base = dir("runs")
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        let src = base.appendingPathComponent("Lib"), out = base.appendingPathComponent("out")
        let deep = src.appendingPathComponent("a/b/c/d/e/f")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: src.appendingPathComponent("notes.txt"))
        try #require(mkfifo(deep.appendingPathComponent("deep.pipe").path, 0o644) == 0)
        try makeSocket("editor.sock", in: src)
        try FileManager.default.createSymbolicLink(atPath: src.appendingPathComponent("sock-link").path, withDestinationPath: "editor.sock")
        try FileManager.default.createSymbolicLink(atPath: src.appendingPathComponent("abs-link").path,
                                                   withDestinationPath: src.appendingPathComponent("editor.sock").path)
        let engine = SparseBundleMirrorEngine(sizeGB: 1, mountBase: base)
        func run(_ n: Int) {
            do { _ = try engine.archive(ArchiveSource(name: "Lib", root: src), to: out) }
            catch { Issue.record("run \(n) failed: \(error)") }
        }
        run(1)
        let late = src.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: late, withIntermediateDirectories: true)
        try #require(mkfifo(late.appendingPathComponent("late.pipe").path, 0o600) == 0)
        try makeSocket("late.sock", in: late)
        run(2)
        for p in ["a/b/c/d/e/f/deep.pipe", "editor.sock"] { try FileManager.default.removeItem(at: src.appendingPathComponent(p)) }
        try FileManager.default.removeItem(at: late)
        run(3)
        let a = try #require(RestoreDiscovery.archive(at: out))
        let got = try RestoreEngine().restore(a, to: base.appendingPathComponent("dest"))
        #expect(specials(in: got).isEmpty, "\(specials(in: got))")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: got.appendingPathComponent("sock-link").path)) == "editor.sock")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: got.appendingPathComponent("abs-link").path))
                == src.appendingPathComponent("editor.sock").path)
        #expect(!FileManager.default.fileExists(atPath: got.appendingPathComponent("new").path), "a folder deleted from the library came back")
    }

    // The next copy is a clone of the last, so a pipe an earlier copy held keeps the
    // folder it was in, and a read-only folder stays read-only in the clone. The pipe
    // has to come out of it all the same, or every read-back after says the copy
    // holds something the library doesn't.
    @Test func aPipeAnEarlierCopyHeldInAReadOnlyFolderIsTakenOut() throws {
        let base = dir("ro")
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        let src = base.appendingPathComponent("Lib"), next = base.appendingPathComponent("copy")
        for root in [src, next] {
            let ro = root.appendingPathComponent("vendor")
            try FileManager.default.createDirectory(at: ro, withIntermediateDirectories: true)
            try Data("pinned".utf8).write(to: ro.appendingPathComponent("lock.txt"))
            try #require(mkfifo(ro.appendingPathComponent("hook.pipe").path, 0o644) == 0)
        }
        // the same file, dated the same, as rsync would have left it
        var st = stat()
        try #require(lstat(src.appendingPathComponent("vendor/lock.txt").path, &st) == 0)
        var times = [timespec(tv_sec: st.st_atimespec.tv_sec, tv_nsec: 0), timespec(tv_sec: st.st_mtimespec.tv_sec, tv_nsec: 0)]
        _ = utimensat(AT_FDCWD, next.appendingPathComponent("vendor/lock.txt").path, &times, AT_SYMLINK_NOFOLLOW)
        for root in [src, next] { #expect(chmod(root.appendingPathComponent("vendor").path, 0o555) == 0) }
        _ = try sync(src, into: next)
        #expect(specials(in: next).isEmpty, "the earlier copy's pipe is still there: \(specials(in: next))")
        let found = try MirrorCopy.structure(of: next, against: src, previous: nil, control: nil)
        #expect(found.count == 0, "\(found.examples)")
    }

    // Names openrsync's filters read as patterns or comments.
    @Test func pipesWithPatternLikeNamesAreLeftOut() throws {
        let base = dir("names")
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        let src = base.appendingPathComponent("Lib"), next = base.appendingPathComponent("copy")
        let odd = src.appendingPathComponent("[x] *?")
        try FileManager.default.createDirectory(at: odd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: src.appendingPathComponent("keep.txt"))
        let names = ["#comment.pipe", ";semi.pipe", "- dash.pipe", "+ plus.pipe", "[a-z]*.pipe", "**", "[x] *?/inner?.pipe"]
        for n in names { try #require(mkfifo(src.appendingPathComponent(n).path, 0o644) == 0, "\(n)") }
        try Data("inner".utf8).write(to: odd.appendingPathComponent("inner.txt"))
        let left = try sync(src, into: next)
        #expect(Set(left) == Set(names), "\(left)")
        #expect(specials(in: next).isEmpty, "\(specials(in: next))")
        #expect(FileManager.default.fileExists(atPath: next.appendingPathComponent("[x] *?/inner.txt").path))
        #expect(try MirrorCopy.structure(of: next, against: src, previous: nil, control: nil).count == 0)
    }

    // A sealed format leaves them out too (see FilteredCopy) and says so in the
    // mirror's words; each note names five and says there are more.
    @Test func theWordsForSealedFormatsAndForManySpecials() throws {
        let base = dir("words")
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("x".utf8).write(to: base.appendingPathComponent("x.txt"))
        for i in 1...7 { try #require(mkfifo(base.appendingPathComponent("p\(i).pipe").path, 0o644) == 0) }
        for zip in [false, true] {
            let stats = JobExecutor.directoryStats(base, forDMG: !zip, forZip: zip)
            #expect(stats.dmgBlockers.refusing.isEmpty)
            let why = try #require(stats.dmgBlockers.leftOutOfSealed(library: "Projects", zip: zip))
            #expect(why.contains("left 7 named pipes, sockets or devices out of \(zip ? "the zip" : "the disk image") (")
                    && why.contains(", …).") && !why.contains("Nothing was backed up"), "\(why)")
            #expect(why.components(separatedBy: ".pipe").count - 1 == DMGBlockers.examplesKept, "\(why)")
        }
        let note = try #require(JobExecutor.directoryStats(base, forMirror: true).dmgBlockers.leftOutOfMirror(library: "Projects"))
        #expect(note.contains("left 7 named pipes, sockets or devices out of the mirror (") && note.contains(", …)."), "\(note)")
        #expect(note.components(separatedBy: ".pipe").count - 1 == DMGBlockers.examplesKept, "\(note)")
    }

    // After the fetch returns, the download moves for a while and then stops for
    // good: it is called not downloaded soon after it stops (not after the fifteen
    // minutes the fetch itself is given), and not while it still moved.
    @Test func aDownloadThatMovesAfterTheFetchAndThenStopsIsReportedSoonAfter() throws {
        let clock = Moves()
        let cloud = CloudDownload(isEvicted: { _ in true }, fetch: { _ in },
                                  progress: { _ in UInt64(min(clock.elapsed, 3) * 10) })
        #expect(throws: CloudDownloadIncomplete.self) {
            try cloud.bringDown([URL(fileURLWithPath: "/nowhere/a.dmg")], quietLimit: 900, control: nil)
        }
        #expect(clock.elapsed >= 3 + CloudDownload.settleLimit - 0.5, "gave up while it still moved: \(clock.elapsed) s")
        #expect(clock.elapsed < 3 + CloudDownload.settleLimit + 3, "took \(clock.elapsed) s")
    }

    // Moving in bursts with pauses shorter than the grace, then local: waited for.
    @Test func aDownloadWithShortPausesAfterTheFetchIsWaitedFor() throws {
        let clock = Moves()
        // moves during the first half of every 5 s (pauses of 2.5 s), local after 11 s
        let cloud = CloudDownload(isEvicted: { _ in clock.elapsed < 11 }, fetch: { _ in },
                                  progress: { _ in
                                      let t = clock.elapsed, cycle = floor(t / 5)
                                      return UInt64(cycle * 25 + min(t - cycle * 5, 2.5) * 10)
                                  })
        try cloud.bringDown([URL(fileURLWithPath: "/nowhere/a.dmg")], quietLimit: 900, control: nil)
        #expect(clock.elapsed >= 11)
    }
}
