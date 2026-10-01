//
//  ArchiveOpenerRaceEdgeTests.swift
//  CryoframeKitTests
//
//  Attacks on ArchiveOpener's races (close against finish, two opens, a real
//  encrypted image closed while it attaches) and on the pasted-path suffix rule.
//

import Testing
import Foundation
@testable import CryoframeKit

private final class Count: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func add() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

private func fake(_ c: Count) -> OpenedArchive {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("cf-oprace-\(UUID().uuidString)")
    return OpenedArchive(root: work.appendingPathComponent("mnt"), work: work, teardownFn: { c.add() })
}

private func hold(_ s: DispatchSemaphore) { s.wait() }

private func entry(_ p: String, _ k: ContentsEntry.Kind = .file) -> ContentsEntry {
    ContentsEntry(path: p, size: 1, modified: 0, kind: k)
}

@Suite(.serialized) struct ArchiveOpenerRaceEdgeTests {

    // Two opens, the first still running when the second starts: the first lands
    // later, is closed, and says canceled; the second is the one open.
    @Test func secondOpenSupersedesFirstWhoseResultIsClosed() async {
        let o = ArchiveOpener()
        let a = Count(), b = Count()
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let t1 = Task { await o.open(name: "A", passphrases: [nil]) { _, _ in started.signal(); hold(release); return fake(a) } }
        await Task.detached { hold(started) }.value
        let r2 = await o.open(name: "B", passphrases: [nil]) { _, _ in fake(b) }
        release.signal()
        let r1 = await t1.value
        guard case .canceled = r1 else { Issue.record("first: \(r1)"); return }
        guard case .opened = r2 else { Issue.record("second: \(r2)"); return }
        #expect(a.value == 1 && b.value == 0)
        o.close()
        #expect(b.value == 1 && a.value == 1)
    }

    // Hammer close() against a finishing open, 30 rounds: every archive an attempt
    // made is closed exactly once by the time everything settles.
    @Test func closeRacingFinishNeverLeaksOrDoubleCloses() async {
        for round in 0..<30 {
            let o = ArchiveOpener()
            let made = Count(), closed = Count()
            let t = Task {
                await o.open(name: "R", passphrases: [nil]) { _, _ in made.add(); return fake(closed) }
            }
            if round % 3 == 0 { await Task.yield() }
            if round % 3 == 1 { try? await Task.sleep(nanoseconds: UInt64(round) * 20_000) }
            o.close()
            _ = await t.value
            // close() before the open began leaves it held; either way, close again and
            // every archive made is closed exactly once
            let held = o.opened != nil ? 1 : 0
            o.close()
            #expect(closed.value == made.value, "round \(round): made \(made.value) closed \(closed.value) held \(held)")
        }
    }

    // A real encrypted image, closed at assorted moments mid-attach: nothing stays attached.
    @Test func realEncryptedImageClosedMidAttachLeavesNothing() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("cf-oprace-real-\(UUID().uuidString)")
        try fm.createDirectory(at: base.appendingPathComponent("src"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        try Data("hello".utf8).write(to: base.appendingPathComponent("src/a.txt"))
        let dmg = base.appendingPathComponent("enc.dmg")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = ["create", "-srcfolder", base.appendingPathComponent("src").path, "-encryption", "AES-256", "-stdinpass",
                       "-format", "UDZO", "-volname", "cfopr", "-ov", dmg.path]
        let inp = Pipe(); p.standardInput = inp; p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); inp.fileHandleForWriting.write(Data("pw".utf8)); try inp.fileHandleForWriting.close()
        p.waitUntilExit()
        try #require(p.terminationStatus == 0)
        let result = ArchiveResult(artifacts: [dmg], format: .sealedDMG)
        let work = base.appendingPathComponent("work")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        var opened = 0, canceled = 0
        for delay in [0, 20, 80, 150, 300, 500, 800, 1200] as [UInt64] {
            let o = ArchiveOpener()
            let t = Task {
                await o.open(name: "enc.dmg", passphrases: ["bad", "pw"]) { pass, control in
                    try ArchiveReader(runner: ProcessCommandRunner(control: control), workBase: work).open(result, passphrase: pass)
                }
            }
            try await Task.sleep(nanoseconds: delay * 1_000_000)
            o.close()
            let r = await t.value
            switch r { case .canceled: canceled += 1; case .opened: opened += 1; default: break }
        }
        print("REAL opened=\(opened) canceled=\(canceled)")
        let left = (try? fm.contentsOfDirectory(atPath: work.path)) ?? []
        #expect(left.isEmpty, "work left: \(left)")
        let info = Process(); info.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil"); info.arguments = ["info"]
        let out = Pipe(); info.standardOutput = out; try info.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        info.waitUntilExit()
        #expect(!text.contains("enc.dmg"), "still attached")
    }

    // The suffix rule: what a path query adds on top of the substring match.
    @Test func suffixRuleAddsOnlyShorterTailsOfTheQuery() throws {
        let q = try #require(ContentsQuery("/Volumes/Backup/Other/notes.txt"))
        #expect(q.matches(entry("Other/notes.txt")))
        #expect(q.matches(entry("notes.txt")), "top-level notes.txt is a different file: extra hit")
        #expect(!q.matches(entry("Elsewhere/notes.txt")))
        #expect(!q.matches(entry("Other")), "a parent folder of the file isn't the file")
        #expect(!q.matches(entry("Volumes")))
        // limit: the extras per version are at most one per tail of the query
        let deep = try #require(ContentsQuery("/a/b/c/d/e/f.txt"))
        #expect(["f.txt", "e/f.txt", "d/e/f.txt", "c/d/e/f.txt", "b/c/d/e/f.txt", "a/b/c/d/e/f.txt"].allSatisfy { deep.matches(entry($0)) })
        // no leading slash -> no suffix rule? "Other/notes.txt" is a substring query anyway
        // KNOWN ISSUE (0c207f9): the suffix rule also applies to a typed, relative
        // "Other/notes.txt" (the empty state suggests "Documents/Taxes"), where the
        // substring match already covers every real hit, so a top-level "notes.txt"
        // is only a false hit. Fixed when the rule is limited to "/", "~" and file-URL
        // queries: this fails, drop the withKnownIssue.
        let rel = try #require(ContentsQuery("Other/notes.txt"))
        #expect(rel.matches(entry("Deep/Other/notes.txt")))
        withKnownIssue("a typed relative path also matches a top-level name that is its last part") {
            #expect(!rel.matches(entry("notes.txt")))
        }
    }

    @Test func oddQueries() throws {
        // an unencoded space, a bad escape, a host, a trailing slash, a quoted path
        for q in ["file:///Users/b/W-2 form.pdf", "file://localhost/Users/b/W-2%20form.pdf", "file:///Users/b/W-2%20form.pdf/"] {
            let cq = try #require(ContentsQuery(q), "\(q)")
            #expect(cq.matches(entry("W-2 form.pdf")) || cq.matches(entry("b/W-2 form.pdf")), "\(q) -> \(cq.searched)")
        }
        let bad = try #require(ContentsQuery("file:///Users/b/100%.pdf"))
        #expect(bad.matches(entry("100%.pdf")), "a file URL with a bad escape still finds the file")
        let dots = try #require(ContentsQuery("/Users/b/Taxes/../Other/x.txt"))
        #expect(dots.matches(entry("Other/x.txt")))
        // a name that is just ".." parts of a name containing a slash char? ignore
        #expect(ContentsQuery("~") == nil || ContentsQuery("~")?.matchesPaths == false)
    }
}
