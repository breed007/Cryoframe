//
//  MirrorStepStopEdgeTests.swift
//  CryoframeKitTests
//
//  Stop pressed part way through each step of a live mirror's run after its copy,
//  on a first run and on a run with changes: the run ends soon after, the image is
//  detached, nothing is left in the mount base, the mirror is either sealed or marked
//  open (never sealed over a copy it doesn't hold), and the next run finishes with a
//  copy that matches the library byte for byte.
//

import Testing
import Foundation
@testable import CryoframeKit

private func realTemp(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-stepstop-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    // the walk's spelling (/private/var), so paths compare whole
    var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(d.path, &buf) != nil else { return d }
    return URL(fileURLWithPath: String(cString: buf), isDirectory: true)
}

/// 3,000 small files in 30 folders, one hidden and one locked
private func library(in base: URL) throws -> URL {
    let lib = base.appendingPathComponent("Lib")
    for i in 0..<3000 {
        let dir = lib.appendingPathComponent("d\(i % 30)")
        if i < 30 { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try Data(repeating: UInt8(i % 251), count: 4096 + (i % 7) * 1024).write(to: dir.appendingPathComponent("f\(i).bin"))
    }
    #expect(chflags(lib.appendingPathComponent("d0/f0.bin").path, UInt32(UF_HIDDEN)) == 0)
    #expect(chflags(lib.appendingPathComponent("d1/f1.bin").path, UInt32(UF_IMMUTABLE)) == 0)
    return lib
}

/// 300 files changed in size and content
private func change(_ lib: URL) throws {
    for i in stride(from: 2, to: 3000, by: 10) {
        try Data(repeating: UInt8((i + 7) % 251), count: 9000 + i).write(to: lib.appendingPathComponent("d\(i % 30)/f\(i).bin"))
    }
}

/// Presses Stop part way through the `occurrence`th step called `title`: once it is
/// half done, or 50 ms in for a step that can't count.
private final class StopPart: @unchecked Sendable {
    let title: String, occurrence: Int
    private let lock = NSLock()
    private var seen = 0
    private var _titles: [String] = []
    private var _stoppedIn: String?
    private var _stoppedAt: Date?
    init(_ title: String, _ occurrence: Int) { self.title = title; self.occurrence = occurrence }

    var titles: [String] { lock.lock(); defer { lock.unlock() }; return _titles }
    var stoppedIn: String? { lock.lock(); defer { lock.unlock() }; return _stoppedIn }
    var stoppedAt: Date? { lock.lock(); defer { lock.unlock() }; return _stoppedAt }

    func follow(_ control: RunControl) {
        control.stepChanged = { [weak control] _, begun in
            guard let control else { return }
            self.lock.lock()
            self._titles.append(begun.title)
            var go = false
            if begun.title == self.title { self.seen += 1; go = self.seen == self.occurrence }
            self.lock.unlock()
            guard go else { return }
            let started = begun.started
            DispatchQueue.global().async {
                let until = Date().addingTimeInterval(0.05)
                while let s = control.step, s.started == started, s.title == begun.title {
                    if let t = s.total, t > 0 { if s.done * 2 >= t { break } } else if Date() >= until { break }
                    usleep(200)
                }
                self.lock.lock(); self._stoppedIn = control.step?.title ?? "(no step)"; self._stoppedAt = Date(); self.lock.unlock()
                control.cancel()
            }
        }
    }
}

private func hdiutilInfo() -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil"); p.arguments = ["info"]
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    guard (try? p.run()) != nil else { return "" }
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return text
}

/// the image's library copy against the library: by structure, and byte for byte
private func copyMatches(_ bundle: URL, _ lib: URL, root expected: [String]) throws {
    let mnt = realTemp("look")
    defer { MountPoint.detach(mnt, runner: ProcessCommandRunner()); try? FileManager.default.removeItem(at: mnt) }
    let r = try DiskImageGate.serialized {
        try ProcessCommandRunner().runRetryingBusy("/usr/bin/hdiutil", ["attach", bundle.path, "-mountpoint", mnt.path, "-nobrowse", "-readonly"])
    }
    try #require(r.ok, "couldn't attach the mirror: \(r.stderr)")
    let root = try FileManager.default.contentsOfDirectory(atPath: mnt.path).filter { $0 != ".fseventsd" }.sorted()
    #expect(root == expected, "image root: \(root)")
    let found = try MirrorCopy.structure(of: mnt.appendingPathComponent("Lib"), against: lib, previous: nil, control: nil)
    #expect(found.count == 0, "differs by structure: \(found.examples)")
    let diff = Process(); diff.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
    diff.arguments = ["-rq", lib.path, mnt.appendingPathComponent("Lib").path]
    let out = Pipe(); diff.standardOutput = out; diff.standardError = out
    try diff.run()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    diff.waitUntilExit()
    #expect(diff.terminationStatus == 0, "bytes differ: \(text.prefix(400))")
}

@Suite(.serialized) struct MirrorStepStopEdgeTests {

    /// (run: 1 for a first run, 2 for a run with changes; the step; which occurrence)
    static let cases: [(Int, String, Int)] = [
        (1, "Finishing the copy", 1), (1, "Writing the copy to the drive", 1), (1, "Checking the copy", 1),
        (1, "Reading the copy back", 1), (1, "Checking attributes", 1), (1, "Removing the previous copy", 1),
        (1, "Writing the copy to the drive", 2), (1, "Compacting the disk image", 1), (1, "Checking the disk image", 1),
        (1, "Confirming the update", 1),
        (2, "Copying what changed", 1), (2, "Finishing the copy", 1), (2, "Writing the copy to the drive", 1),
        (2, "Checking the copy", 1), (2, "Reading the copy back", 1), (2, "Checking attributes", 1),
        (2, "Removing the previous copy", 1), (2, "Writing the copy to the drive", 2), (2, "Compacting the disk image", 1),
        (2, "Checking the disk image", 1), (2, "Confirming the update", 1),
    ]

    @Test(arguments: cases)
    func stopPartWayThroughEachStepLeavesAMirrorTheNextRunFinishes(_ run: Int, _ title: String, _ occurrence: Int) throws {
        let base = realTemp("case")
        let out = base.appendingPathComponent("out"), mounts = base.appendingPathComponent("mounts")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mounts, withIntermediateDirectories: true)
        let lib = try library(in: base)
        defer {
            _ = chflags(lib.appendingPathComponent("d1/f1.bin").path, 0)
            try? FileManager.default.removeItem(at: base)
        }
        let engine = { (c: RunControl) in
            SparseBundleMirrorEngine(sizeGB: 1, runner: ProcessCommandRunner(control: c), mountBase: mounts)
        }
        let bundle = out.appendingPathComponent("Lib.sparsebundle")
        if run == 2 {
            _ = try engine(RunControl()).archive(ArchiveSource(name: "Lib", root: lib), to: out)
            try change(lib)
        }

        let control = RunControl(), stop = StopPart(title, occurrence)
        stop.follow(control)
        var outcome = "finished"
        do {
            _ = try engine(control).archive(ArchiveSource(name: "Lib", root: lib), to: out)
        } catch is CancelledError {
            outcome = "stopped"
        } catch {
            outcome = "failed: \(error)"
        }
        let ended = Date()
        let latency = stop.stoppedAt.map { ended.timeIntervalSince($0) } ?? -1
        print("STEPSTOP run=\(run) step=\(title)#\(occurrence) stoppedIn=\(stop.stoppedIn ?? "-") outcome=\(outcome) "
              + "latency=\(String(format: "%.2f", latency))s open=\(MirrorSeal.isOpen(out)) steps=\(stop.titles.count)")

        #expect(stop.stoppedAt != nil, "the step never began: \(stop.titles)")
        #expect(outcome == "stopped", "Stop in \(title) ended the run as: \(outcome)")
        #expect(latency < 10, "the run went on \(latency) s after Stop")
        #expect(control.step == nil, "a step outlived the run")
        #expect(MirrorMounts.mountPoints(of: bundle, runner: ProcessCommandRunner()).isEmpty, "the image was left mounted")
        #expect(!hdiutilInfo().contains(base.lastPathComponent), "the image was left attached")
        // the volume's lock file stays, by design; a work folder or mountpoint must not
        let left = ((try? FileManager.default.contentsOfDirectory(atPath: mounts.path)) ?? []).filter { !$0.hasPrefix("cf-volume-lock-") }
        #expect(left.isEmpty, "the mount base kept \(left)")

        // the next run finishes, from whatever this one left
        _ = try engine(RunControl()).archive(ArchiveSource(name: "Lib", root: lib), to: out)
        #expect(!MirrorSeal.isOpen(out))
        try copyMatches(bundle, lib, root: ["Lib"])
    }

    // Stop while the next run removes what a stopped one left in staging: that run
    // ends too, and the one after it finishes.
    @Test func stopWhileRemovingAnEarlierRunsLeftoverAndTheRunAfterFinishes() throws {
        let base = realTemp("leftover")
        let out = base.appendingPathComponent("out"), mounts = base.appendingPathComponent("mounts")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mounts, withIntermediateDirectories: true)
        let lib = try library(in: base)
        defer {
            _ = chflags(lib.appendingPathComponent("d1/f1.bin").path, 0)
            try? FileManager.default.removeItem(at: base)
        }
        let engine = { (c: RunControl) in
            SparseBundleMirrorEngine(sizeGB: 1, runner: ProcessCommandRunner(control: c), mountBase: mounts)
        }
        let first = RunControl(), s1 = StopPart("Checking attributes", 1)
        s1.follow(first)
        #expect(throws: CancelledError.self) { try engine(first).archive(ArchiveSource(name: "Lib", root: lib), to: out) }

        let second = RunControl(), s2 = StopPart("Removing an unfinished copy an earlier run left", 1)
        s2.follow(second)
        #expect(throws: CancelledError.self) { try engine(second).archive(ArchiveSource(name: "Lib", root: lib), to: out) }
        #expect(s2.stoppedIn == "Removing an unfinished copy an earlier run left", "stopped in \(s2.stoppedIn ?? "-")")
        #expect(!hdiutilInfo().contains(base.lastPathComponent), "the image was left attached")

        _ = try engine(RunControl()).archive(ArchiveSource(name: "Lib", root: lib), to: out)
        #expect(!MirrorSeal.isOpen(out))
        try copyMatches(out.appendingPathComponent("Lib.sparsebundle"), lib, root: ["Lib"])
    }
}
