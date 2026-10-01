//
//  ScratchOwnershipTests.swift
//  CryoframeKitTests
//
//  Every cleanup of scratch and of the temp folder touches only what Cryoframe
//  provably made (see ScratchLayout and OpenedArchive.isWorkFolder): a scratch
//  location chosen in Settings is the user's own folder, and the temp folder is
//  shared with every program the user runs.
//

import Testing
import Foundation
@testable import CryoframeKit

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-scrown-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

private func write(_ text: String, _ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

private func exists(_ url: URL) -> Bool {
    var st = stat()
    return lstat(url.path, &st) == 0
}

/// a disk image of `size` and `fs` made at `image` and mounted at `mnt`: a library on
/// it is read live, as from a drive that can't be frozen (the fake helper makes no
/// snapshots)
private func mountedImage(_ image: URL, at mnt: URL, size: String = "40m", fs: String = "HFS+") throws {
    try FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)
    let made = try ProcessCommandRunner().run("/usr/bin/hdiutil", ["create", "-size", size, "-fs", fs, "-type", "SPARSE",
                                                                   "-volname", "Lib", image.path])
    try #require(made.ok, "\(made.stderr)")
    let attached = try DiskImageGate.serialized {
        try ProcessCommandRunner().runRetryingBusy("/usr/bin/hdiutil", ["attach", image.path + ".sparseimage",
                                                                        "-mountpoint", mnt.path, "-nobrowse", "-owners", "on"])
    }
    try #require(attached.ok && MountPoint.isMounted(mnt), "\(attached.stderr)")
}

@Suite(.serialized) struct ScratchOwnershipTests {

    // A chosen location gets a folder of Cryoframe's inside it; the app builds there.
    @Test func aChosenScratchLocationGetsAFolderOfItsOwn() {
        let chosen = URL(fileURLWithPath: "/Users/someone/Developer", isDirectory: true)
        #expect(ScratchLayout.root(inChosen: chosen).path == "/Users/someone/Developer/Cryoframe Scratch")
    }

    // The launch sweep takes a marked job folder's unreferenced builds and the folder
    // itself once empty, and leaves alone: a 1.5 build (no mark), a mark naming
    // another job, a folder that isn't a job's name, a job folder that is a link, and
    // links where `build` or a library's folder should be, with what they point at.
    @Test func theSweepTakesOnlyMarkedJobFolders() throws {
        let base = folder("sweep")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Cryoframe Scratch")
        let outside = base.appendingPathComponent("outside")
        try write("mine", outside.appendingPathComponent("keep.txt"))

        let crashed = UUID().uuidString, legacy = UUID().uuidString, wrongMark = UUID().uuidString, other = UUID().uuidString
        let linkedJob = UUID().uuidString, linkedBuild = UUID().uuidString, linkedLib = UUID().uuidString
        let crashedLib = root.appendingPathComponent("\(crashed)/build/lib")
        try ScratchLayout.claim(libraryDir: crashedLib)
        try write("half", crashedLib.appendingPathComponent("Lib.dmg"))
        try write("1.5", root.appendingPathComponent("\(legacy)/build/lib/Lib.dmg"))
        try write("x", root.appendingPathComponent("\(wrongMark)/build/lib/Lib.dmg"))
        try write(ScratchLayout.markText(other), root.appendingPathComponent("\(wrongMark)/\(ScratchLayout.markName)"))
        let named = root.appendingPathComponent("MyApp/build/Release")
        try write(ScratchLayout.markText("MyApp"), root.appendingPathComponent("MyApp/\(ScratchLayout.markName)"))
        try write("app", named.appendingPathComponent("MyApp"))
        // a link named for a job, to a folder carrying that job's mark
        let elsewhere = base.appendingPathComponent("elsewhere/\(linkedJob)")
        try ScratchLayout.claim(libraryDir: elsewhere.appendingPathComponent("build/lib"))
        try write("there", elsewhere.appendingPathComponent("build/lib/Lib.dmg"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(linkedJob), withDestinationURL: elsewhere)
        // marked job folders whose `build`, or a library's folder in it, is a link outside
        try ScratchLayout.claim(libraryDir: root.appendingPathComponent("\(linkedBuild)/build/lib"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("\(linkedBuild)/build"), withDestinationURL: outside)
        try ScratchLayout.claim(libraryDir: root.appendingPathComponent("\(linkedLib)/build/lib"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("\(linkedLib)/build"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("\(linkedLib)/build/lib"), withDestinationURL: outside)

        let store = PendingTransferStore(url: base.appendingPathComponent("pending.json"))
        JobExecutor.sweepOrphanedScratch(scratchBase: root, pendingStore: store, locks: RunLocks(directory: base.appendingPathComponent("locks")))

        #expect(!exists(root.appendingPathComponent(crashed)), "a marked crash leftover, or its emptied folder, was left")
        #expect(exists(root.appendingPathComponent("\(legacy)/build/lib/Lib.dmg")), "a 1.5 build without a mark was removed")
        #expect(exists(root.appendingPathComponent("\(wrongMark)/build/lib/Lib.dmg")), "a mark naming another job was believed")
        #expect(exists(named.appendingPathComponent("MyApp")), "a folder that isn't a job's was swept")
        #expect(exists(elsewhere.appendingPathComponent("build/lib/Lib.dmg")), "the sweep followed a job folder that is a link")
        #expect(exists(root.appendingPathComponent(linkedJob)))
        #expect(exists(outside.appendingPathComponent("keep.txt")), "the sweep followed a link out of scratch")
        #expect(exists(root.appendingPathComponent("\(linkedBuild)/build")) && exists(root.appendingPathComponent("\(linkedLib)/build/lib")))

        // a folder named for a job the app knows (not a UUID) counts once it is known
        JobExecutor.sweepOrphanedScratch(scratchBase: root, pendingStore: store, knownJobIDs: ["MyApp"])
        #expect(!exists(root.appendingPathComponent("MyApp")))
    }

    // A run marks its job's folder before building there, and leaves nothing behind
    // when it finishes; another job's 1.5 build beside it stays.
    @Test func aRunMarksItsFolderAndLeavesNothingBehind() async throws {
        let base = folder("run")
        defer { try? FileManager.default.removeItem(at: base) }
        let mnt = base.appendingPathComponent("vol")
        try mountedImage(base.appendingPathComponent("src"), at: mnt)
        defer { MountPoint.detach(mnt, runner: ProcessCommandRunner()) }
        let lib = mnt.appendingPathComponent("Projects")
        try write("one", lib.appendingPathComponent("a.txt"))
        let dest = base.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let root = base.appendingPathComponent("Cryoframe Scratch")
        let legacy = root.appendingPathComponent("\(UUID().uuidString)/build/lib/Lib.zip")
        try write("1.5", legacy)
        let projects = ContentType.genericFolder(id: "projects", displayName: "Projects", path: .absolute(lib.path))
        let job = BackupJob(name: "Projects", libraries: [projects], target: .localVolume(id: "d", name: "Dest", dir: dest),
                            format: .sealedZip, frequency: .manual, createdAt: Date(timeIntervalSince1970: 0))
        let marked = root.appendingPathComponent("\(job.id)/\(ScratchLayout.markName)")
        final class Seen: @unchecked Sendable { var mark = false, build = false, markFirst = true }
        let seen = Seen()
        let watcher = Task.detached {
            while !Task.isCancelled {
                let m = exists(marked), b = exists(root.appendingPathComponent("\(job.id)/build"))
                if b && !m { seen.markFirst = false }
                if m { seen.mark = true }
                if b { seen.build = true }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        let exec = JobExecutor(helper: FakePrivilegedHelper(), detector: FakeProcessDetector(), scratchBase: root)
        let outcome = try await exec.run(job, ownerUID: getuid(), now: Date(), control: RunControl(quietLimit: 20))
        watcher.cancel()
        guard case .finished(let results, _) = outcome, case .completed? = results.first else {
            Issue.record("expected a completed library, got \(outcome)"); return
        }
        #expect(seen.mark && seen.build, "the run's scratch folder was never seen (mark \(seen.mark), build \(seen.build))")
        #expect(seen.markFirst, "something was built in the job's folder before it was marked")
        #expect(!exists(root.appendingPathComponent(job.id)), "the job's scratch folder was left")
        #expect(exists(legacy))
    }

    // A run's start-of-run removal of its own leftover copies, and deleting a job,
    // both leave a job folder without a mark (a 1.5 build) alone.
    @Test func aJobsOwnCleanupLeavesAnUnmarkedFolderAlone() throws {
        let base = folder("own")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("scratch")
        let id = UUID().uuidString
        let copy = root.appendingPathComponent("\(id)/build/lib/\(FilteredCopy.folderName)/Lib/a.txt")
        try write("x", copy)
        FilteredCopy.removeLeftovers(jobID: id, under: [root])
        #expect(exists(copy))

        let job = BackupJob(id: id, name: "Old", libraries: [], target: .localVolume(id: "d", name: "D", dir: base.appendingPathComponent("dest")),
                            format: .sealedZip, frequency: .manual, createdAt: Date(timeIntervalSince1970: 0))
        let store = JobStore(url: base.appendingPathComponent("jobs.json"))
        store.update { $0.jobs = [job] }
        let pending = PendingTransferStore(url: base.appendingPathComponent("pending.json"))
        let plan = JobRemoval.plan(for: job, pending: pending, scratchBase: root, volumes: FixedVolumeTable([]))
        #expect(plan.staged == nil, "an unmarked folder was offered for deletion")
        try JobRemoval.delete(job, expected: plan, store: store, pending: pending, scratchBase: root,
                              locks: RunLocks(directory: base.appendingPathComponent("locks")), volumes: FixedVolumeTable([]))
        #expect(exists(copy), "deleting the job removed an unmarked folder")
    }

    // The temp folder's sweep takes only folders named as the reader names them
    // (`cf-open-<UUID>`, `cf-mirror-<UUID>`), and never a link.
    @Test func theOpenArchiveSweepTakesOnlyCryoframesWorkFolders() throws {
        let base = folder("opens")
        defer { try? FileManager.default.removeItem(at: base) }
        let old = Date().addingTimeInterval(-3 * 24 * 3600)
        func work(_ name: String) throws -> URL {
            let w = base.appendingPathComponent(name)
            try write("x", w.appendingPathComponent("extract/file"))
            try FileManager.default.setAttributes([.creationDate: old], ofItemAtPath: w.path)
            return w
        }
        let ours = try work(OpenedArchive.workPrefix + UUID().uuidString)
        let mirror = try work(MirrorMounts.prefix + UUID().uuidString)
        let notOurs = try work("cf-open-notes")
        let alike = try work("cf-mirror-" + UUID().uuidString + "-backup")
        let target = try work("someone-elses")
        let link = base.appendingPathComponent(OpenedArchive.workPrefix + UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        ArchiveReader.sweepStaleOpens(in: base)
        #expect(!exists(ours) && !exists(mirror))
        #expect(exists(notOurs.appendingPathComponent("extract/file")) && exists(alike.appendingPathComponent("extract/file")))
        #expect(exists(link) && exists(target.appendingPathComponent("extract/file")), "the sweep followed a link")
    }
}
