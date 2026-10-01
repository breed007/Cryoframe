//
//  LockScratchRecheckTests.swift
//  CryoframeKitTests
//
//  The M6 stage 1 recheck's edges: a direct disk image of locked items on a Mac
//  whose tool takes them (and the append-only file it still refuses), restores of
//  both, a 1.5 user's builds in a scratch location chosen in Settings, marks that
//  aren't what they seem, and a zip's folder dates through a real restore.
//

import Testing
import Foundation
@testable import CryoframeKit

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-lsr-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

private func unlock(_ dir: URL) {
    _ = try? ProcessCommandRunner().run("/usr/bin/chflags", ["-R", "0", dir.path])
    _ = try? ProcessCommandRunner().run("/bin/chmod", ["-R", "-N", dir.path])
    _ = try? ProcessCommandRunner().run("/bin/chmod", ["-R", "u+rwx", dir.path])
}

private func sh(_ cmd: String, in dir: URL) throws {
    let r = try ProcessCommandRunner().run("/bin/sh", ["-c", "cd '\(dir.path)' && \(cmd)"])
    try #require(r.ok, "\(cmd): \(r.stderr)")
}

private func flags(_ url: URL) -> UInt32 {
    var st = stat()
    return lstat(url.path, &st) == 0 ? st.st_flags : 0
}

private func exists(_ url: URL) -> Bool {
    var st = stat()
    return lstat(url.path, &st) == 0
}

private func write(_ text: String, _ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

private func acl(_ url: URL) -> String {
    (try? ProcessCommandRunner().run("/bin/ls", ["-lde", url.path]).stdout) ?? ""
}

private func mtime(_ url: URL) -> Int {
    var st = stat()
    return lstat(url.path, &st) == 0 ? Int(st.st_mtimespec.tv_sec) : -1
}

/// a disk image mounted at `mnt`, read live by a run (the fake helper makes no snapshots)
private func mountedImage(_ image: URL, at mnt: URL) throws {
    try FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)
    let made = try ProcessCommandRunner().run("/usr/bin/hdiutil", ["create", "-size", "40m", "-fs", "HFS+", "-type", "SPARSE",
                                                                   "-volname", "Lib", image.path])
    try #require(made.ok, "\(made.stderr)")
    let attached = try DiskImageGate.serialized {
        try ProcessCommandRunner().runRetryingBusy("/usr/bin/hdiutil", ["attach", image.path + ".sparseimage",
                                                                        "-mountpoint", mnt.path, "-nobrowse", "-owners", "on"])
    }
    try #require(attached.ok && MountPoint.isMounted(mnt), "\(attached.stderr)")
}

/// the one archive a run left under `dest`, found the way restore finds it
private func archiveIn(_ dest: URL) throws -> RestorableArchive {
    let walker = FileManager.default.enumerator(atPath: dest.path)
    while let rel = walker?.nextObject() as? String {
        if rel.hasSuffix(".dmg") || rel.hasSuffix(".zip"),
           let a = RestoreDiscovery.archive(at: dest.appendingPathComponent(rel).deletingLastPathComponent()) { return a }
    }
    throw CocoaError(.fileNoSuchFile)
}

@Suite(.serialized) struct LockScratchRecheckTests {

    // MARK: locks, on a Mac whose disk image tool takes them

    // This Mac's tool builds a disk image straight from a locked file, a locked folder
    // and a locked file with an access list and an attribute: the plan is direct, the
    // run says nothing about locks, and the image and a restore of it keep all three.
    @Test(.enabled(if: FilteredCopy.diskImageKeepsLocks))
    func aDirectDiskImageKeepsLocksAccessListsAndAttributesThroughARestore() throws {
        let base = folder("direct")
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        let lib = base.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try sh("""
            mkdir -p Locked/inner && echo k > Locked/inner/k.txt && echo l > locked.txt && echo c > combo.txt && \
            xattr -w com.example.note kept combo.txt && chmod +a 'everyone allow read' combo.txt && \
            chflags uchg locked.txt Locked combo.txt
            """, in: lib)
        let found = JobExecutor.directoryStats(lib, forDMG: true).dmgBlockers
        #expect(found.count(.locked) == 3 && found.refusing.isEmpty, "\(found.counts)")
        let plan = SealedReadPlan.of(found, .dmg)
        #expect(plan == .direct)
        let out = base.appendingPathComponent("scratch/\(UUID().uuidString)/build/projects")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let built = try FilteredCopy.sealedArchive(SealedArchiveEngine(.dmg), source: ArchiveSource(name: "Projects", root: lib),
                                                   found: found, plan: plan, buildDir: out, copyDir: out, library: "Projects",
                                                   runner: ProcessCommandRunner())
        #expect(built.notes.isEmpty, "a direct build that kept every lock still said: \(built.notes)")
        try ArchiveManifest.write(try ArchiveManifest.build(for: built.archive), toDir: out)
        let archive = try #require(RestoreDiscovery.archive(at: out))
        let restored = try restoreOnceFree(archive, to: base.appendingPathComponent("restored"))
        defer { unlock(restored) }
        for rel in ["locked.txt", "Locked", "combo.txt"] {
            #expect(flags(restored.appendingPathComponent(rel)) & UInt32(UF_IMMUTABLE) != 0, "\(rel) came back unlocked")
        }
        #expect(acl(restored.appendingPathComponent("combo.txt")).contains("everyone allow read"), "\(acl(restored.appendingPathComponent("combo.txt")))")
        #expect(MirrorCopy.attributeValue(restored.appendingPathComponent("combo.txt").path, "com.example.note") == Array("kept".utf8))
        #expect(try String(contentsOf: restored.appendingPathComponent("Locked/inner/k.txt"), encoding: .utf8) == "k\n")
    }

    // An append-only (uappnd) file is the lock this Mac's tool still refuses
    // ("could not access /Volumes/<vol>/app.log - Operation not permitted", measured on
    // macOS 27.0.1). A real run, planned direct, falls back to an unlocked copy: it
    // completes, says which items lost their lock, and the restore holds everything,
    // unlocked; the library keeps its locks.
    @Test(.enabled(if: FilteredCopy.diskImageKeepsLocks))
    func anAppendOnlyFileIsRefusedByThisMacsToolAndTheRunFallsBackToAnUnlockedCopy() async throws {
        let base = folder("uappnd")
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        // the tool itself, so the test says when a macOS starts taking the flag
        let probe = base.appendingPathComponent("probe")
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)
        try sh("echo a > app.log && chflags uappnd app.log", in: probe)
        let direct = try ProcessCommandRunner().run("/usr/bin/hdiutil", ["create", "-srcfolder", probe.path, "-format", "UDZO",
                                                                         base.appendingPathComponent("probe.dmg").path])
        // measured refused on macOS 27.0.1; a macOS that takes it builds direct and keeps every lock
        let refused = !direct.ok && FilteredCopy.refusedOutright(direct.stderr)

        let mnt = base.appendingPathComponent("vol")
        try mountedImage(base.appendingPathComponent("src"), at: mnt)
        defer { unlock(mnt); MountPoint.detach(mnt, runner: ProcessCommandRunner()) }
        let lib = mnt.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try sh("echo l > locked.txt && echo a > app.log && mkdir Locked && echo k > Locked/k.txt && chflags uchg locked.txt Locked && chflags uappnd app.log", in: lib)
        let dest = base.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let projects = ContentType.genericFolder(id: "projects", displayName: "Projects", path: .absolute(lib.path))
        let job = BackupJob(name: "Projects", libraries: [projects], target: .localVolume(id: "d", name: "Dest", dir: dest),
                            format: .sealedDMG, frequency: .manual, createdAt: Date(timeIntervalSince1970: 0))
        let scratch = base.appendingPathComponent("scratch")
        let exec = JobExecutor(helper: FakePrivilegedHelper(), detector: FakeProcessDetector(), scratchBase: scratch)
        let outcome = try await exec.run(job, ownerUID: getuid(), now: Date(), control: RunControl(quietLimit: 20))
        guard case .finished(let results, let warning) = outcome, case .completed? = results.first else {
            Issue.record("expected a completed library, got \(outcome)"); return
        }
        let said = warning?.contains("Projects: left the lock off 3 locked items in the disk image") == true
        // copied unlocked up front on every macOS, refused or not (see SealedReadPlan)
        #expect(said, "tool refused: \(refused), warning: \(warning ?? "nil")")
        #expect(!exists(scratch.appendingPathComponent(job.id)), "the job's scratch folder was left")
        #expect(flags(lib.appendingPathComponent("app.log")) & UInt32(UF_APPEND) != 0, "the library's own flag was taken off")

        let restored = try restoreOnceFree(try archiveIn(dest), to: base.appendingPathComponent("restored"))
        defer { unlock(restored) }
        for rel in ["locked.txt", "Locked", "app.log"] {
            let locked = flags(restored.appendingPathComponent(rel)) & MirrorCopy.lockingFlags != 0
            #expect(locked != said, "\(rel): locked \(locked) after a run whose note said the lock was left off: \(said)")
        }
        #expect(try String(contentsOf: restored.appendingPathComponent("app.log"), encoding: .utf8) == "a\n")
        #expect(try String(contentsOf: restored.appendingPathComponent("Locked/k.txt"), encoding: .utf8) == "k\n")
    }

    // MARK: a 1.5 user's scratch location

    // 1.5 built in the chosen folder itself (`<chosen>/<job>/build/<lib>`); 1.6 builds
    // in `<chosen>/Cryoframe Scratch`. The first launch's sweeps (Cryoframe's folder
    // and the system cache's) delete nothing of 1.5's or the user's, known job or not,
    // referenced by a resumable transfer or not.
    @Test func theFirstLaunchAfterAnUpgradeDeletesNothingInTheChosenFolder() throws {
        let base = folder("upgrade")
        defer { try? FileManager.default.removeItem(at: base) }
        let chosen = base.appendingPathComponent("Developer")
        let cache = base.appendingPathComponent("cache/app.cryoframe/scratch")
        let known = UUID().uuidString, crashed = UUID().uuidString
        let pendingBuild = chosen.appendingPathComponent("\(known)/build/photos/Photos.dmg")
        let leftover = chosen.appendingPathComponent("\(crashed)/build/notes/Notes.zip")
        let cacheLeftover = cache.appendingPathComponent("\(crashed)/build/notes/Notes.zip")
        let project = chosen.appendingPathComponent("MyApp/build/Release/MyApp")
        for f in [pendingBuild, leftover, cacheLeftover, project] { try write("x", f) }
        let pending = PendingTransferStore(url: base.appendingPathComponent("pending.json"))
        pending.save(PendingTransfer(jobID: "\(known):nas:photos", sourceFile: pendingBuild.path, baseName: "Photos.dmg",
                                     totalBytes: 1, chunkSize: 1, targetDir: base.appendingPathComponent("nas").path, format: .sealedDMG))
        for scratchBase in [ScratchLayout.root(inChosen: chosen), cache] {
            JobExecutor.sweepOrphanedScratch(scratchBase: scratchBase, pendingStore: pending,
                                             locks: RunLocks(directory: base.appendingPathComponent("locks")),
                                             knownJobIDs: [known, crashed])
        }
        FilteredCopy.removeLeftovers(jobID: crashed, under: [ScratchLayout.root(inChosen: chosen), cache])
        for f in [pendingBuild, leftover, cacheLeftover, project] { #expect(exists(f), "\(f.path) was deleted") }
        #expect(!exists(ScratchLayout.root(inChosen: chosen)), "a sweep made Cryoframe Scratch")
    }

    // Deleting a job whose resumable transfer was staged by 1.5 in the chosen folder:
    // the transfer's record goes, and so should the archive it named, which is
    // provably Cryoframe's (the record says so). It is neither offered nor removed,
    // and no sweep will ever take it: a whole archive left for good, unseen.
    @Test func deletingAJobLeavesItsOneFiveStagedArchiveForGood() throws {
        let base = folder("delete15")
        defer { try? FileManager.default.removeItem(at: base) }
        let chosen = base.appendingPathComponent("Developer")
        let root = ScratchLayout.root(inChosen: chosen)
        let job = BackupJob(name: "Photos", libraries: [], target: .localVolume(id: "d", name: "D", dir: base.appendingPathComponent("dest")),
                            format: .sealedDMG, frequency: .manual, createdAt: Date(timeIntervalSince1970: 0))
        let staged = chosen.appendingPathComponent("\(job.id)/build/photos/Photos.dmg")
        try write("a whole archive", staged)
        let store = JobStore(url: base.appendingPathComponent("jobs.json"))
        store.update { $0.jobs = [job] }
        let pending = PendingTransferStore(url: base.appendingPathComponent("pending.json"))
        pending.save(PendingTransfer(jobID: "\(job.id):nas:photos", sourceFile: staged.path, baseName: "Photos.dmg",
                                     totalBytes: 15, chunkSize: 5, targetDir: base.appendingPathComponent("nas/2026").path,
                                     format: .sealedDMG))
        let plan = JobRemoval.plan(for: job, pending: pending, scratchBase: root, volumes: FixedVolumeTable([]))
        #expect(plan.unfinished.count == 1)
        try JobRemoval.delete(job, expected: plan, store: store, pending: pending, scratchBase: root,
                              locks: RunLocks(directory: base.appendingPathComponent("locks")), volumes: FixedVolumeTable([]))
        #expect(pending.all().isEmpty)
        // the sweep can't reach it either: not in Cryoframe Scratch, and unmarked
        JobExecutor.sweepOrphanedScratch(scratchBase: root, pendingStore: pending, knownJobIDs: [job.id])
        #expect(plan.stagedArchives == [staged], "the confirmation doesn't mention the staged archive")
        #expect(!exists(staged), "the staged archive outlived its job and its transfer record")
    }

    // MARK: marks that aren't what they seem

    // Only a regular file with the exact words counts. A link to a good mark, a FIFO
    // (read without hanging), a folder, a mark with more after it, and a mark for the
    // folder's name in another case all don't. A marked job folder copied anywhere
    // but into Cryoframe Scratch (here, a home folder chosen as the scratch location)
    // is never looked into.
    @Test func marksThatArentRegularFilesWithTheExactWordsDontCount() throws {
        let base = folder("marks")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("home/Cryoframe Scratch")
        func job(_ make: (URL, String) throws -> Void) throws -> (URL, URL) {
            let id = UUID().uuidString
            let dir = root.appendingPathComponent(id)
            let data = dir.appendingPathComponent("build/lib/mine.txt")
            try write("user data", data)
            try make(dir.appendingPathComponent(ScratchLayout.markName), id)
            return (dir, data)
        }
        let good = base.appendingPathComponent("good-mark")
        let link = try job { m, id in
            try Data(ScratchLayout.markText(id).utf8).write(to: good)
            try FileManager.default.createSymbolicLink(at: m, withDestinationURL: good)
        }
        let fifo = try job { m, _ in try #require(mkfifo(m.path, 0o644) == 0) }
        let dirMark = try job { m, _ in try FileManager.default.createDirectory(at: m, withIntermediateDirectories: true) }
        let longer = try job { m, id in try Data((ScratchLayout.markText(id) + "and more\n").utf8).write(to: m) }
        let otherCase = try job { m, id in try Data(ScratchLayout.markText(id.lowercased()).utf8).write(to: m) }
        let cases = [("link", link.0, link.1), ("fifo", fifo.0, fifo.1), ("folder", dirMark.0, dirMark.1),
                 ("longer", longer.0, longer.1), ("other case", otherCase.0, otherCase.1)]
        // a job folder copied out of Cryoframe Scratch into the home folder itself
        let copied = base.appendingPathComponent("home/\(UUID().uuidString)")
        try write(ScratchLayout.markText(copied.lastPathComponent), copied.appendingPathComponent(ScratchLayout.markName))
        try write("user data", copied.appendingPathComponent("build/lib/mine.txt"))

        let started = Date()
        let pending = PendingTransferStore(url: base.appendingPathComponent("pending.json"))
        JobExecutor.sweepOrphanedScratch(scratchBase: root, pendingStore: pending)
        #expect(Date().timeIntervalSince(started) < 10, "the sweep hung on a FIFO mark")
        for (what, dir, data) in cases {
            #expect(!ScratchLayout.isOurs(dir, jobID: dir.lastPathComponent), "\(what) counted as a mark")
            #expect(exists(data), "\(what): the sweep deleted what the folder held")
        }
        #expect(exists(copied.appendingPathComponent("build/lib/mine.txt")), "the sweep reached outside Cryoframe Scratch")
    }

    // MARK: a zip's folder dates, through a real restore

    // Folders with odd names (spaces, accents in both Unicode forms, an emoji, `#`, `%`,
    // a backslash, a colon), a package, and the library itself, each holding a folder
    // and a file (the case ditto dates at the unpack), come back with their dates,
    // restored into the original place and alongside the library.
    @Test func aZipsFolderDatesComeBackThroughARestoreInPlaceAndAlongside() throws {
        let base = folder("zipdates")
        defer { try? FileManager.default.removeItem(at: base) }
        let home = base.appendingPathComponent("home")
        let lib = home.appendingPathComponent("Projects")
        let names = ["a b", "Caf\u{E9}", "Cafe\u{301}", "box \u{1F4C1}", "#tag", "100%", "back\\slash", "colon:name",
                     "Tool.app", "Tool.app/Contents", "a b/inner c"]
        for n in names {
            try write("f", lib.appendingPathComponent(n).appendingPathComponent("file.txt"))
            try FileManager.default.createDirectory(at: lib.appendingPathComponent(n).appendingPathComponent("sub"), withIntermediateDirectories: true)
        }
        try write("<plist/>", lib.appendingPathComponent("Tool.app/Contents/Info.plist"))
        var when: [String: Int] = [:]
        // deepest first, so a parent's own date is set after its children change
        for (i, rel) in (names.sorted { $0.split(separator: "/").count > $1.split(separator: "/").count } + [""]).enumerated() {
            let t = 1_400_000_000 + i * 86_400
            var times = [timespec(tv_sec: t, tv_nsec: 0), timespec(tv_sec: t, tv_nsec: 0)]
            let path = rel.isEmpty ? lib.path : lib.appendingPathComponent(rel).path
            try #require(utimensat(AT_FDCWD, path, &times, 0) == 0, "\(rel)")
            when[rel] = t
        }
        #expect((try? lib.appendingPathComponent("Tool.app").resourceValues(forKeys: [.isPackageKey]))?.isPackage == true)
        let out = base.appendingPathComponent("dest/Projects/2026-10-01-120000")
        let result = try SealedArchiveEngine(.zip).archive(ArchiveSource(name: "Projects", root: lib), to: out)
        try ArchiveManifest.write(try ArchiveManifest.build(for: result), toDir: out)
        let archive = try #require(RestoreDiscovery.archive(at: out))

        let alongside = try RestoreEngine().restore(archive, to: home, onClash: .alongside)
        #expect(alongside.lastPathComponent != "Projects")
        try FileManager.default.removeItem(at: lib)
        let inPlace = try RestoreEngine().restore(archive, to: home, inPlace: true)
        #expect(inPlace.path == lib.path)
        for (label, restored) in [("alongside", alongside), ("in place", inPlace)] {
            for (rel, t) in when {
                let got = mtime(rel.isEmpty ? restored : restored.appendingPathComponent(rel))
                #expect(got == t, "\(label): \(rel.isEmpty ? "the library" : rel) is dated \(got), not \(t)")
            }
        }
    }

    // A sealed zip larger than 4 GiB. ditto writes no Zip64 end record, so the end
    // record's offsets wrap; `zipinfo -t` then reports "4294967296 extra bytes" and
    // exits 1, and the reader's room check (ArchiveReader.unpackedSize) refuses to
    // open it: restore, browse, a rehearsal and a mount-and-open verify all fail on
    // any library whose zip passes 4 GiB. 1.5.6 had no such check and opened it.
    // ZipFolderDates reads it correctly. Slow (about 2 minutes, 18 GB of scratch), so
    // only with TEST_RUNNER_CF_BIG_ZIP=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CF_BIG_ZIP"] != nil))
    func aSealedZipOverFourGigabytesOpensForARestore() throws {
        let base = folder("bigzip")
        defer { try? FileManager.default.removeItem(at: base) }
        let lib = base.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        // what doesn't compress, so the zip itself passes 4 GiB
        try sh("mkdir -p A/B && head -c 4400000000 /dev/zero | openssl enc -aes-128-ctr -nosalt -pass pass:x 2>/dev/null > A/big.bin && echo f > A/B/f.txt && mkdir A/B/C && touch -t 201401010000 A",
               in: lib)
        let t = mtime(lib.appendingPathComponent("A"))
        let out = base.appendingPathComponent("dest/Photos/2026-10-01-120000")
        let result = try SealedArchiveEngine(.zip).archive(ArchiveSource(name: "Photos", root: lib), to: out)
        let zip = try #require(result.artifacts.first)
        #expect(Checksum.byteSize(of: zip) > 1 << 32, "the zip didn't pass 4 GiB")
        let dates = try #require(ZipFolderDates.read(zip))
        #expect(dates.contains { $0.path == "Photos/A/" && $0.seconds == Int64(t) }, "\(dates)")
        #expect(ArchiveReader.unpackedSize(of: zip) != nil)
        try ArchiveManifest.write(try ArchiveManifest.build(for: result), toDir: out)
        let archive = try #require(RestoreDiscovery.archive(at: out))
        let restored = try RestoreEngine().restore(archive, to: base.appendingPathComponent("restored"))
        #expect(Checksum.byteSize(of: restored.appendingPathComponent("A/big.bin")) == 4_400_000_000)
        #expect(mtime(restored.appendingPathComponent("A")) == t)
    }
}
