//
//  MirrorStepTests.swift
//  CryoframeKitTests
//
//  A live mirror's run after its copy: every step says how far it has got, and Stop
//  ends each one without leaving the image attached. A first run of a 13.72 GB Photos
//  library to a microSD card sat at "archiving 99%", zero bytes a second, for 15 to
//  60 minutes after its copy; quitting then left the image attached.
//

import Testing
import Foundation
@testable import CryoframeKit

private func tempDir(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-steps-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// a library of `n` files of 64 KiB, half in a subfolder, one hidden and one locked
private func library(files n: Int) throws -> URL {
    let lib = tempDir("lib").appendingPathComponent("Lib")
    try FileManager.default.createDirectory(at: lib.appendingPathComponent("sub"), withIntermediateDirectories: true)
    for i in 0..<n {
        try Data(repeating: UInt8(i % 251), count: 64 * 1024).write(to: lib.appendingPathComponent(i % 2 == 0 ? "f\(i).bin" : "sub/f\(i).bin"))
    }
    #expect(chflags(lib.appendingPathComponent("f0.bin").path, UInt32(UF_HIDDEN)) == 0)
    #expect(chflags(lib.appendingPathComponent("sub/f1.bin").path, UInt32(UF_IMMUTABLE)) == 0)
    return lib
}

private func removeLibrary(_ lib: URL) {
    _ = chflags(lib.appendingPathComponent("sub/f1.bin").path, 0)
    try? FileManager.default.removeItem(at: lib.deletingLastPathComponent())
}

/// what a run's steps were, each with how far it had got when the next began
private final class Steps: @unchecked Sendable {
    private let lock = NSLock()
    private var ended: [RunStep] = [], begun: [RunStep] = []
    var stopAt: String?
    func follow(_ control: RunControl) {
        control.stepChanged = { [weak control] ended, begun in
            self.lock.lock()
            if let ended { self.ended.append(ended) }
            self.begun.append(begun)
            let stop = self.stopAt == begun.title
            self.lock.unlock()
            if stop { control?.cancel() }
        }
    }
    var titles: [String] { lock.lock(); defer { lock.unlock() }; return begun.map(\.title) }
    /// the step called `title` as it ended
    func finished(_ title: String) -> RunStep? { lock.lock(); defer { lock.unlock() }; return ended.last { $0.title == title } }
}

/// what is at the root of the mirror's image, and whether anything of it is attached
private func imageRoot(_ bundle: URL) throws -> [String] {
    let mnt = tempDir("look")
    defer { MountPoint.detach(mnt, runner: ProcessCommandRunner()); try? FileManager.default.removeItem(at: mnt) }
    let r = try DiskImageGate.serialized {
        try ProcessCommandRunner().runRetryingBusy("/usr/bin/hdiutil", ["attach", bundle.path, "-mountpoint", mnt.path, "-nobrowse", "-readonly"])
    }
    try #require(r.ok, "couldn't attach the mirror to look inside: \(r.stderr)")
    return (try FileManager.default.contentsOfDirectory(atPath: mnt.path)).filter { $0 != ".fseventsd" }.sorted()
}

@Suite(.serialized) struct MirrorSteps {

    // Every step after the copy is named, in order, and each counted step reaches its
    // total: the read-back in bytes (everything, on a first run), the rest in items.
    @Test func aFirstRunNamesEveryStepAfterTheCopyAndCountsThemToTheEnd() throws {
        let src = try library(files: 40)
        let out = tempDir("first"), base = tempDir("base")
        defer { for d in [out, base] { try? FileManager.default.removeItem(at: d) }; removeLibrary(src) }
        let control = RunControl(), steps = Steps()
        steps.follow(control)
        _ = try SparseBundleMirrorEngine(sizeGB: 1, runner: ProcessCommandRunner(control: control), mountBase: base)
            .archive(ArchiveSource(name: "Lib", root: src), to: out)

        #expect(steps.titles == ["Finishing the copy", "Writing the copy to the drive", "Checking the copy",
                                 "Reading the copy back", "Checking attributes", "Removing the previous copy",
                                 "Writing the copy to the drive", "Compacting the disk image", "Checking the disk image",
                                 "Confirming the update"])
        let items = UInt64(FileManager.default.enumerator(atPath: src.path)!.allObjects.count)
        let finished = try #require(steps.finished("Finishing the copy"))
        #expect(finished.done == items + 1 && finished.total == items + 1, "finished \(finished.done) of \(finished.total ?? 0)")
        let checked = try #require(steps.finished("Checking the copy"))
        #expect(checked.done == items && checked.total == items, "checked \(checked.done) of \(checked.total ?? 0)")
        let read = try #require(steps.finished("Reading the copy back"))
        #expect(read.unit == .bytes && read.stage == .verifying)
        #expect(read.total == 40 * 64 * 1024 && read.done == read.total, "read back \(read.done) of \(read.total ?? 0)")
        #expect(control.step == nil, "a step outlived the run")
    }

    // A run with nothing changed says it is copying what changed (the image already
    // holds the library, so its size can't show progress) and reads nothing back.
    @Test func aRunWithNothingChangedSaysSoAndReadsNothingBack() throws {
        let src = try library(files: 20)
        let out = tempDir("again"), base = tempDir("base")
        defer { for d in [out, base] { try? FileManager.default.removeItem(at: d) }; removeLibrary(src) }
        let engine = { (c: RunControl) in SparseBundleMirrorEngine(sizeGB: 1, runner: ProcessCommandRunner(control: c), mountBase: base) }
        _ = try engine(RunControl()).archive(ArchiveSource(name: "Lib", root: src), to: out)
        let control = RunControl(), steps = Steps()
        steps.follow(control)
        _ = try engine(control).archive(ArchiveSource(name: "Lib", root: src), to: out)
        #expect(steps.titles.first == "Copying what changed")
        #expect(steps.finished("Copying what changed")?.stage == .archiving)
        #expect(steps.finished("Reading the copy back")?.total == 0)
        #expect(steps.finished("Removing the previous copy").map { $0.done > 0 } == true, "the previous copy's removal wasn't counted")
    }

    // Stop during the read-back: the run ends, the image is detached, and the copy
    // being checked is left in staging rather than removed item by item (minutes on a
    // slow drive). The next run removes it, and the mirror is complete.
    @Test func stopDuringTheReadBackLeavesTheUncheckedCopyForTheNextRun() throws {
        let src = try library(files: 40)
        let out = tempDir("stopread"), base = tempDir("base")
        defer { for d in [out, base] { try? FileManager.default.removeItem(at: d) }; removeLibrary(src) }
        let control = RunControl(), steps = Steps()
        steps.stopAt = "Reading the copy back"
        steps.follow(control)
        let bundle = out.appendingPathComponent("Lib.sparsebundle")
        #expect(throws: CancelledError.self) {
            try SparseBundleMirrorEngine(sizeGB: 1, runner: ProcessCommandRunner(control: control), mountBase: base)
                .archive(ArchiveSource(name: "Lib", root: src), to: out)
        }
        #expect(!steps.titles.contains("Removing the unfinished copy"))
        #expect(MirrorMounts.mountPoints(of: bundle, runner: ProcessCommandRunner()).isEmpty, "the image was left attached")
        #expect(try imageRoot(bundle).contains(MirrorCopy.stagingName))

        let next = RunControl(), after = Steps()
        after.follow(next)
        _ = try SparseBundleMirrorEngine(sizeGB: 1, runner: ProcessCommandRunner(control: next), mountBase: base)
            .archive(ArchiveSource(name: "Lib", root: src), to: out)
        #expect(after.titles.first == "Removing an unfinished copy an earlier run left")
        #expect(try imageRoot(bundle) == ["Lib"])
        #expect(!MirrorSeal.isOpen(out))
    }

    // Stop while the previous copy is being removed, after the new one went in place:
    // the removal ends there, the image is detached, and the next run finishes it.
    @Test func stopWhileRemovingThePreviousCopyEndsItAndTheNextRunFinishes() throws {
        let src = try library(files: 40)
        let out = tempDir("stopremove"), base = tempDir("base")
        defer { for d in [out, base] { try? FileManager.default.removeItem(at: d) }; removeLibrary(src) }
        let bundle = try SparseBundleMirrorEngine(sizeGB: 1, mountBase: base)
            .archive(ArchiveSource(name: "Lib", root: src), to: out).artifacts[0]
        try Data("changed".utf8).write(to: src.appendingPathComponent("f2.bin"))

        let control = RunControl(), steps = Steps()
        steps.stopAt = "Removing the previous copy"
        steps.follow(control)
        #expect(throws: CancelledError.self) {
            try SparseBundleMirrorEngine(sizeGB: 1, runner: ProcessCommandRunner(control: control), mountBase: base)
                .archive(ArchiveSource(name: "Lib", root: src), to: out)
        }
        #expect(steps.finished("Removing the previous copy")?.done == 0, "the removal went on after Stop")
        #expect(MirrorMounts.mountPoints(of: bundle, runner: ProcessCommandRunner()).isEmpty, "the image was left attached")
        #expect(try imageRoot(bundle).sorted() == [MirrorCopy.stagingName, "Lib"].sorted())

        _ = try SparseBundleMirrorEngine(sizeGB: 1, mountBase: base).archive(ArchiveSource(name: "Lib", root: src), to: out)
        #expect(try imageRoot(bundle) == ["Lib"])
        #expect(!MirrorSeal.isOpen(out))
    }
}

@Suite struct RunStepProgress {

    // The line a step shows: bytes with the time left from the speed, items as a
    // count, and a step that can't count just its name. Never 100% before the run ends.
    @Test func aStepShowsWhatItCountsAndTheTimeLeft() {
        var bytes = RunStep(title: "Reading the copy back", stage: .verifying, unit: .bytes, total: 4_000_000_000)
        bytes.done = 1_000_000_000
        let p = RunProgress(step: bytes, libraryIndex: 1, libraryCount: 3, speed: 10_000_000, elapsed: 5)
        #expect(p.stage == .verifying && p.fraction == 0.25 && p.speed == 10_000_000)
        #expect(p.eta == 300)
        #expect(p.detail == "Reading the copy back: \(JobExecutor.human(1_000_000_000)) of \(JobExecutor.human(4_000_000_000))")

        var items = RunStep(title: "Finishing the copy", stage: .finishing, total: 120_302)
        items.done = 120_302
        let q = RunProgress(step: items, libraryIndex: 1, libraryCount: 1, speed: 5, elapsed: nil)
        #expect(q.fraction == 0.99 && q.speed == nil && q.eta == nil)
        #expect(q.detail == "Finishing the copy: \(RunProgress.count(120_302)) of \(RunProgress.count(120_302)) items")

        let none = RunProgress(step: RunStep(title: "Compacting the disk image", stage: .finishing), libraryIndex: 1,
                               libraryCount: 1, speed: nil, elapsed: nil)
        #expect(none.fraction == nil && none.detail == "Compacting the disk image…")
    }

    // The speed of a step counted in bytes starts afresh with each step.
    @Test func aStepsSpeedStartsAfreshWithEachStep() {
        var rate = StepRate()
        let t = Date()
        var s = RunStep(title: "Reading the copy back", stage: .verifying, unit: .bytes, total: 100, started: t)
        #expect(rate.update(s, now: t) == nil)
        s.done = 50
        #expect(rate.update(s, now: t.addingTimeInterval(1)) == 50)
        let next = RunStep(title: "Reading the copy back", stage: .verifying, unit: .bytes, total: 100, started: t.addingTimeInterval(2))
        #expect(rate.update(next, now: t.addingTimeInterval(2)) == nil)
        #expect(rate.update(RunStep(title: "Checking attributes", stage: .verifying, total: 9), now: t.addingTimeInterval(3)) == nil)
    }
}
