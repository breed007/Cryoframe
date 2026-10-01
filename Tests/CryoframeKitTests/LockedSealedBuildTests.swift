//
//  LockedSealedBuildTests.swift
//  CryoframeKitTests
//
//  Sealed builds of a folder holding locked items. macOS 15's hdiutil can't build a
//  disk image of one at all, a direct build included ("could not access
//  /Volumes/<library>/locked.txt - Operation not permitted"), and a zip never keeps
//  the lock. This Mac (macOS 26 or later) builds them, so the macOS 15 tool is a
//  fake here that refuses any source holding a locked item as it does; CI's
//  macOS 15 runner is the real one.
//
//  Also: what an encrypted job's full startup disk tells the user, and the zip's
//  folder dates put back after an unpack.
//

import Testing
import Foundation
@testable import CryoframeKit

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-locked-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

private func unlock(_ dir: URL) {
    _ = try? ProcessCommandRunner().run("/usr/bin/chflags", ["-R", "0", dir.path])
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

/// a library holding a locked file, a locked folder and an append-only file
private func lockedLibrary(_ base: URL, name: String = "Projects") throws -> URL {
    let lib = base.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
    try sh("""
        mkdir -p Locked Plain && echo locked > locked.txt && echo kept > Locked/kept.txt && echo p > Plain/p.txt && \
        echo log > log.txt && chflags uchg locked.txt Locked && chflags uappnd log.txt
        """, in: lib)
    return lib
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

/// the scratch layout a run builds in: `<root>/<job>/build/<library>`
private func buildDir(_ root: URL, job: String = UUID().uuidString) -> URL {
    root.appendingPathComponent("\(job)/build/projects", isDirectory: true)
}

private func openOnceFree(_ result: ArchiveResult, passphrase: String? = nil) throws -> OpenedArchive {
    let until = Date().addingTimeInterval(60)
    while true {
        do { return try ArchiveReader(runner: ProcessCommandRunner()).open(result, passphrase: passphrase) }
        catch let e as DiskImageInUse where e.attachedWithoutMount && Date() < until { Thread.sleep(forTimeInterval: 1) }
    }
}

/// macOS 15's hdiutil, as measured on CI: `create -srcfolder` of a folder holding a
/// locked item fails, naming the item on the volume it builds. Everything else runs.
private final class RefusesLocks: CommandRunner, @unchecked Sendable {
    let inner = ProcessCommandRunner()
    private let lock = NSLock()
    private var refusals = 0
    /// refuse every create, locked items or not
    let always: Bool
    init(always: Bool = false) { self.always = always }
    var refused: Int { lock.lock(); defer { lock.unlock() }; return refusals }
    var control: RunControl? { nil }
    var forTeardown: CommandRunner { inner }

    func run(_ launchPath: String, _ args: [String], stdin: Data?) throws -> CommandResult {
        if (launchPath as NSString).lastPathComponent == "hdiutil", args.first == "create",
           let at = args.firstIndex(of: "-srcfolder"), at + 1 < args.count {
            let root = URL(fileURLWithPath: args[at + 1])
            if let item = Self.firstLocked(in: root) ?? (always ? "a.txt" : nil) {
                lock.lock(); refusals += 1; lock.unlock()
                return CommandResult(status: 1, stdout: "could not access /Volumes/\(root.lastPathComponent)/\(item) - Operation not permitted\n",
                                     stderr: "hdiutil: create failed - Operation not permitted\n")
            }
        }
        return try inner.run(launchPath, args, stdin: stdin)
    }

    static func firstLocked(in root: URL) -> String? {
        if flags(root) & MirrorCopy.lockingFlags != 0 { return "." }
        let walker = FileManager.default.enumerator(atPath: root.path)
        while let rel = walker?.nextObject() as? String {
            if flags(root.appendingPathComponent(rel)) & MirrorCopy.lockingFlags != 0 { return rel }
        }
        return nil
    }
}

/// a copy that fills its volume: rsync fails for want of room
private struct FillsScratch: CommandRunner {
    let inner = ProcessCommandRunner()
    var control: RunControl? { nil }
    var forTeardown: CommandRunner { inner }
    func run(_ launchPath: String, _ args: [String], stdin: Data?) throws -> CommandResult {
        if (launchPath as NSString).lastPathComponent.contains("rsync") {
            return CommandResult(status: 11, stdout: "", stderr: "rsync: write failed: No space left on device (28)\n")
        }
        return try inner.run(launchPath, args, stdin: stdin)
    }
}

@Suite(.serialized) struct LockedSealedBuildTests {

    // MARK: the walk and the plan

    // A sealed walk notes locked items (files and folders, uchg and uappnd); they
    // never refuse a build. A mirror keeps locks, so its walk doesn't note them.
    @Test func theSealedWalkFindsLockedItemsAndRefusesNothingForThem() throws {
        let base = folder("walk")
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        let lib = try lockedLibrary(base)
        for (dmg, zip) in [(true, false), (false, true)] {
            let found = JobExecutor.directoryStats(lib, forDMG: dmg, forZip: zip).dmgBlockers
            #expect(found.count(.locked) == 3, "\(found.counts)")
            #expect(Set(found.examples[.locked] ?? []) == ["locked.txt", "Locked", "log.txt"])
            #expect(found.refusing.isEmpty, "\(found.refusing.counts)")
        }
        #expect(JobExecutor.directoryStats(lib, forMirror: true).dmgBlockers.count(.locked) == 0)
    }

    // A copy only where it buys something: named pipes and sockets, or a disk image
    // of locked items on a Mac whose tool can't take them. Where it can, a direct
    // build keeps the locks, so a copy would cost room and lose them.
    @Test func theReadPlanCopiesOnlyWhereItMustAndUnlocksOnlyDiskImages() {
        var locked = DMGBlockers(); locked.note(.locked, "a")
        var special = DMGBlockers(); special.note(.special, "p")
        var both = locked; both.note(.special, "p")
        let copy = SealedReadPlan(fromCopy: true, unlocked: false), unlocked = SealedReadPlan(fromCopy: true, unlocked: true)
        #expect(SealedReadPlan.of(DMGBlockers(), .dmg, diskImageKeepsLocks: false) == .direct)
        #expect(SealedReadPlan.of(locked, .dmg, diskImageKeepsLocks: true) == .direct)
        #expect(SealedReadPlan.of(locked, .dmg, diskImageKeepsLocks: false) == unlocked)
        #expect(SealedReadPlan.of(locked, .zip, diskImageKeepsLocks: false) == .direct)
        #expect(SealedReadPlan.of(special, .dmg, diskImageKeepsLocks: false) == copy)
        #expect(SealedReadPlan.of(special, .zip, diskImageKeepsLocks: true) == copy)
        #expect(SealedReadPlan.of(both, .dmg, diskImageKeepsLocks: true) == copy)
        #expect(SealedReadPlan.of(both, .dmg, diskImageKeepsLocks: false) == unlocked)
        // this Mac's tool takes locks (macOS 26 reports 16 to an older SDK's build)
        #expect(FilteredCopy.diskImageKeepsLocks == (ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 16))
    }

    // MARK: building

    // Where the tool refuses locks, the disk image is built from an unlocked copy, plain
    // or encrypted: everything is in it, unlocked, the run says which items lost their
    // lock, the library keeps its locks, and the copy is gone (an encrypted job's from
    // the startup disk's scratch, folders and all).
    @Test(arguments: [false, true])
    func aDiskImageOfLockedItemsBuildsWhereTheToolRefusesThem(_ encrypted: Bool) throws {
        let base = folder("build")
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        let lib = try lockedLibrary(base)
        let found = JobExecutor.directoryStats(lib, forDMG: true).dmgBlockers
        let job = UUID().uuidString
        let out = buildDir(base.appendingPathComponent("scratch"), job: job)
        let copyDir = encrypted ? buildDir(base.appendingPathComponent("startup"), job: job) : out
        let runner = RefusesLocks()
        let passphrase = encrypted ? "pw" : nil
        // a direct build is refused, as on macOS 15
        #expect(throws: ArchiveError.self) {
            try SealedArchiveEngine(.dmg, runner: runner).archive(ArchiveSource(name: "Projects", root: lib), to: base.appendingPathComponent("direct"))
        }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let built = try FilteredCopy.sealedArchive(SealedArchiveEngine(.dmg, runner: runner, passphrase: passphrase),
                                                   source: ArchiveSource(name: "Projects", root: lib), found: found,
                                                   plan: .of(found, .dmg, diskImageKeepsLocks: false), buildDir: out, copyDir: copyDir,
                                                   library: "Projects", runner: runner)
        #expect(runner.refused == 1, "only the direct try above was refused")
        #expect(built.notes.count == 1, "\(built.notes)")
        let note = built.notes.first ?? ""
        #expect(note.hasPrefix("Projects: left the lock off 3 locked items in the disk image (") && note.contains("locked.txt"), "\(note)")
        #expect(!FileManager.default.fileExists(atPath: copyDir.appendingPathComponent(FilteredCopy.folderName).path))
        if encrypted {
            #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("startup/\(job)").path), "the copy's folders were left")
        }
        #expect(flags(lib.appendingPathComponent("locked.txt")) & UInt32(UF_IMMUTABLE) != 0, "the library's own lock was taken off")

        let opened = try openOnceFree(built.archive, passphrase: passphrase)
        defer { opened.close() }
        #expect(try String(contentsOf: opened.root.appendingPathComponent("locked.txt"), encoding: .utf8) == "locked\n")
        #expect(try String(contentsOf: opened.root.appendingPathComponent("Locked/kept.txt"), encoding: .utf8) == "kept\n")
        #expect(try String(contentsOf: opened.root.appendingPathComponent("log.txt"), encoding: .utf8) == "log\n")
        #expect(flags(opened.root.appendingPathComponent("locked.txt")) & MirrorCopy.lockingFlags == 0)
    }

    // A build planned direct (this Mac's tool should take locks) that the tool refuses
    // all the same is built from an unlocked copy, whatever the macOS.
    @Test func aRefusedDirectBuildOfLockedItemsFallsBackToAnUnlockedCopy() throws {
        let base = folder("fallback")
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        let lib = try lockedLibrary(base)
        let found = JobExecutor.directoryStats(lib, forDMG: true).dmgBlockers
        let out = buildDir(base.appendingPathComponent("scratch"))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let runner = RefusesLocks()
        let built = try FilteredCopy.sealedArchive(SealedArchiveEngine(.dmg, runner: runner), source: ArchiveSource(name: "Projects", root: lib),
                                                   found: found, plan: .of(found, .dmg, diskImageKeepsLocks: true), buildDir: out,
                                                   copyDir: out, library: "Projects", runner: runner)
        #expect(runner.refused == 1)
        #expect(built.notes.first?.contains("left the lock off 3 locked items in the disk image") == true, "\(built.notes)")
        #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent(FilteredCopy.folderName).path))
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("Projects.dmg").path))
    }

    // Refused even unlocked: the run fails in words, naming the item within the
    // library and what to do, never only a path on the tool's temporary volume.
    @Test func aBuildRefusedEvenUnlockedSaysWhatToDo() throws {
        let base = folder("refused")
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        let lib = try lockedLibrary(base)
        let found = JobExecutor.directoryStats(lib, forDMG: true).dmgBlockers
        let out = buildDir(base.appendingPathComponent("scratch"))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let runner = RefusesLocks(always: true)
        do {
            _ = try FilteredCopy.sealedArchive(SealedArchiveEngine(.dmg, runner: runner), source: ArchiveSource(name: "Projects", root: lib),
                                               found: found, plan: .of(found, .dmg, diskImageKeepsLocks: false), buildDir: out,
                                               copyDir: out, library: "Projects", runner: runner)
            Issue.record("the build wasn't refused")
        } catch {
            let said = JobExecutor.failureText(error)
            #expect(said.contains("sealed zip") && said.contains("a.txt") && said.contains("Locked"), "\(said)")
            #expect(!said.contains("/Volumes/"), "\(said)")
        }
        #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent(FilteredCopy.folderName).path))
    }

    // hdiutil's own words for a locked item, on a new line or glued to its next one,
    // for a plain folder and a package: the item is named within the library.
    @Test(arguments: [("could not access /Volumes/Projects/sub/locked.txt - Operation not permitted\nhdiutil: create failed - Operation not permitted", "sub/locked.txt"),
                      ("could not access /Volumes/MyLib/MyLib.photoslibrary/locked.txt - Operation not permittedhdiutil: create failed - Operation not permitted\n", "MyLib.photoslibrary/locked.txt"),
                      ("could not access /Volumes/Projects/Photos - 2020/a b.txt - Operation not permitted\nhdiutil: create failed - Operation not permitted", "Photos - 2020/a b.txt")])
    func hdiutilsLockedRefusalIsExplained(_ stderr: String, _ item: String) {
        let said = ArchiveError.toolFailed(tool: "hdiutil", status: 1, stderr: stderr).localizedDescription
        #expect(said.contains("couldn't copy \(item) into the disk image"), "\(said)")
        #expect(said.contains("Locked") && said.contains("sealed zip"), "\(said)")
        #expect(!said.contains("/Volumes/") && !said.contains("permittedhdiutil"), "\(said)")
        // an attach refused for this reason is not a build, and keeps its own words
        let attach = ArchiveError.toolFailed(tool: "hdiutil", status: 1, stderr: "hdiutil: attach failed - Operation not permitted").localizedDescription
        #expect(!attach.contains("couldn't copy"), "\(attach)")
    }

    // A zip never keeps a lock: the run says so, in the same words.
    @Test func aSealedZipSaysWhichItemsLostTheirLock() throws {
        let base = folder("zip")
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        let lib = try lockedLibrary(base)
        let found = JobExecutor.directoryStats(lib, forZip: true).dmgBlockers
        let out = buildDir(base.appendingPathComponent("scratch"))
        let built = try FilteredCopy.sealedArchive(SealedArchiveEngine(.zip), source: ArchiveSource(name: "Projects", root: lib), found: found,
                                                   plan: .of(found, .zip), buildDir: out, copyDir: out, library: "Projects",
                                                   runner: ProcessCommandRunner())
        #expect(built.notes.count == 1 && built.notes[0].hasPrefix("Projects: left the lock off 3 locked items in the zip ("), "\(built.notes)")
        #expect(built.notes[0].contains("A zip can't keep an item's lock."))
        let opened = try openOnceFree(built.archive)
        defer { opened.close() }
        let unpacked = opened.root.appendingPathComponent("Projects/locked.txt")
        #expect(FileManager.default.fileExists(atPath: unpacked.path))
        #expect(flags(unpacked) & MirrorCopy.lockingFlags == 0, "a zip kept a lock after all; the note is wrong")
    }

    // The run itself, on a Mac whose tool can't take locks: the library is backed up
    // and the run's warning names what lost its lock.
    @Test func aRunWhereTheToolCantTakeLocksBacksUpAndSaysSo() async throws {
        let base = folder("run")
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        let mnt = base.appendingPathComponent("vol")
        try mountedImage(base.appendingPathComponent("src"), at: mnt)
        defer { MountPoint.detach(mnt, runner: ProcessCommandRunner()) }
        let lib = try lockedLibrary(mnt)
        let dest = base.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let projects = ContentType.genericFolder(id: "projects", displayName: "Projects", path: .absolute(lib.path))
        let job = BackupJob(name: "Projects", libraries: [projects], target: .localVolume(id: "d", name: "Dest", dir: dest),
                            format: .sealedDMG, frequency: .manual, createdAt: Date(timeIntervalSince1970: 0))
        let scratch = base.appendingPathComponent("scratch")
        let exec = JobExecutor(helper: FakePrivilegedHelper(), detector: FakeProcessDetector(), scratchBase: scratch,
                               diskImageKeepsLocks: false)
        let outcome = try await exec.run(job, ownerUID: getuid(), now: Date(), control: RunControl(quietLimit: 20))
        guard case .finished(let results, let warning) = outcome, case .completed? = results.first else {
            Issue.record("expected a completed library, got \(outcome)"); return
        }
        #expect(warning?.contains("Projects: left the lock off 3 locked items in the disk image") == true, "\(warning ?? "nil")")
        #expect(!FileManager.default.fileExists(atPath: scratch.appendingPathComponent(job.id).path), "the job's scratch folder was left")
    }

    // MARK: a full startup disk

    // An encrypted job's copy is always made on the startup disk, so when that fills,
    // pointing Settings at another scratch location can't help, and isn't suggested.
    @Test func anEncryptedJobsFullStartupDiskDoesntSendYouToSettings() throws {
        let base = folder("full")
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        let lib = base.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try sh("echo secret > plans.txt", in: lib)
        try #require(mkfifo(lib.appendingPathComponent("build.pipe").path, 0o644) == 0)
        let found = JobExecutor.directoryStats(lib, forDMG: true).dmgBlockers
        let out = buildDir(base.appendingPathComponent("scratch"))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for passphrase in [nil, "pw"] as [String?] {
            do {
                _ = try FilteredCopy.sealedArchive(SealedArchiveEngine(.dmg, runner: FillsScratch(), passphrase: passphrase),
                                                   source: ArchiveSource(name: "Projects", root: lib), found: found,
                                                   plan: .of(found, .dmg), buildDir: out, copyDir: out, library: "Projects",
                                                   runner: FillsScratch())
                Issue.record("the copy didn't fail")
            } catch let error as FilteredCopyError {
                guard case .scratchFilled(_, _, let encrypted) = error else { Issue.record("\(error)"); continue }
                #expect(encrypted == (passphrase != nil))
                let said = error.localizedDescription
                #expect(said.contains("ran out of space") && said.contains("copy was removed"), "\(said)")
                if encrypted {
                    #expect(!said.contains("choose a scratch location"), "\(said)")
                    #expect(said.contains("startup disk") && said.contains("won't help"), "\(said)")
                } else {
                    #expect(said.contains("choose a scratch location with more room in Settings"), "\(said)")
                }
            }
        }
    }
}

// MARK: - folder dates from a zip

@Suite(.serialized) struct ZipFolderDateTests {

    // Every folder comes back with the date the zip holds, nested ones and the
    // library's own included, however many entries the zip's end record says it
    // has (ditto writes that count modulo 65,536).
    @Test func everyFolderGetsItsDateBackEvenWhenTheEntryCountIsWrong() throws {
        let base = folder("zipdates")
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        let lib = base.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try sh("mkdir -p A/B/C D && echo f > A/f.txt && echo f > A/B/f.txt && echo f > A/B/C/f.txt && echo f > D/f.txt", in: lib)
        var when: [String: Int] = [:]
        for (i, rel) in ["A/B/C", "A/B", "A", "D", ""].enumerated() {
            let t = 1_500_000_000 + i * 1000
            var times = [timespec(tv_sec: t, tv_nsec: 0), timespec(tv_sec: t, tv_nsec: 0)]
            try #require(utimensat(AT_FDCWD, rel.isEmpty ? lib.path : lib.appendingPathComponent(rel).path, &times, 0) == 0)
            when[rel.isEmpty ? "Projects" : "Projects/" + rel] = t
        }
        let zip = base.appendingPathComponent("p.zip")
        let made = try ProcessCommandRunner().run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", lib.path, zip.path])
        try #require(made.ok, "\(made.stderr)")
        // the end record's entry counts, wrong as ditto writes them past 65,535
        var bytes = try Data(contentsOf: zip)
        let end = try #require(bytes.range(of: Data([0x50, 0x4b, 0x05, 0x06]), options: .backwards)).lowerBound
        bytes[end + 8] = 1; bytes[end + 9] = 0; bytes[end + 10] = 1; bytes[end + 11] = 0
        try bytes.write(to: zip)

        let read = try #require(ZipFolderDates.read(zip))
        let byPath = Dictionary(read.map { ($0.path.hasSuffix("/") ? String($0.path.dropLast()) : $0.path, Int($0.seconds)) },
                                uniquingKeysWith: { a, _ in a })
        #expect(byPath == when, "\(byPath)")

        let ex = base.appendingPathComponent("ex")
        try FileManager.default.createDirectory(at: ex, withIntermediateDirectories: true)
        let unpacked = try ProcessCommandRunner().run("/usr/bin/ditto", ["-x", "-k", zip.path, ex.path])
        try #require(unpacked.ok, "\(unpacked.stderr)")
        ZipFolderDates.restore(from: zip, into: ex)
        for (rel, t) in when {
            var st = stat()
            #expect(lstat(ex.appendingPathComponent(rel).path, &st) == 0 && st.st_mtimespec.tv_sec == t, "\(rel): \(st.st_mtimespec.tv_sec)")
        }
    }

    // Not a zip, or a truncated one: nothing is read, nothing is changed.
    @Test func whatIsntAZipIsLeftAlone() throws {
        let base = folder("notzip")
        defer { try? FileManager.default.removeItem(at: base) }
        let junk = base.appendingPathComponent("j.zip")
        try Data("not a zip at all".utf8).write(to: junk)
        #expect(ZipFolderDates.read(junk) == nil)
        try Data().write(to: junk)
        #expect(ZipFolderDates.read(junk) == nil)
    }
}
