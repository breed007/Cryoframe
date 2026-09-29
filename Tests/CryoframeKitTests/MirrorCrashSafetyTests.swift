//
//  MirrorCrashSafetyTests.swift
//  CryoframeKitTests
//
//  The live mirror is the only copy of a library. A run that stops, fails or
//  crashes part-way must leave the last complete copy exactly as it was, and the
//  next run must finish the job from whatever was left.
//

import Testing
import Foundation
@testable import CryoframeKit

private func tempDir(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-mcs-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private let hdiutil = "/usr/bin/hdiutil"

/// a library of `n` small files, half of them in a subfolder.
private func library(files n: Int) throws -> URL {
    let lib = tempDir("lib").appendingPathComponent("Lib")
    try FileManager.default.createDirectory(at: lib.appendingPathComponent("sub"), withIntermediateDirectories: true)
    for i in 0..<n { try Data("v1 file \(i)".utf8).write(to: lib.appendingPathComponent(i % 2 == 0 ? "f\(i).txt" : "sub/f\(i).txt")) }
    return lib
}

/// every file under `root` by relative path, with its contents.
private func tree(_ root: URL) -> [String: Data] {
    var out: [String: Data] = [:]
    let base = root.resolvingSymlinksInPath().path
    let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
    while let u = walker?.nextObject() as? URL {
        guard (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
        let p = u.resolvingSymlinksInPath().path
        out[String(p.dropFirst(base.count))] = try? Data(contentsOf: u)
    }
    return out
}

/// the mirror's library copy and whatever else is at the image's root, read-only.
private func insideMirror(_ bundle: URL) throws -> (library: [String: Data], root: [String]) {
    let mnt = tempDir("look")
    defer { MountPoint.detach(mnt, runner: ProcessCommandRunner()); try? FileManager.default.removeItem(at: mnt) }
    let r = try DiskImageGate.serialized {
        try ProcessCommandRunner().runRetryingBusy(hdiutil, ["attach", bundle.path, "-mountpoint", mnt.path, "-nobrowse", "-readonly"])
    }
    try #require(r.ok, "couldn't attach the mirror to look inside: \(r.stderr)")
    let root = (try FileManager.default.contentsOfDirectory(atPath: mnt.path)).filter { $0 != ".fseventsd" }.sorted()
    return (tree(mnt.appendingPathComponent("Lib")), root)
}

/// change every file in the library, delete a few, add a few: a run's worth of work.
private func editEverything(_ lib: URL, files n: Int) throws {
    for i in 0..<n where i % 5 != 0 {
        try Data("v2 file \(i)".utf8).write(to: lib.appendingPathComponent(i % 2 == 0 ? "f\(i).txt" : "sub/f\(i).txt"))
    }
    for i in stride(from: 0, to: n, by: 5) {
        try FileManager.default.removeItem(at: lib.appendingPathComponent(i % 2 == 0 ? "f\(i).txt" : "sub/f\(i).txt"))
    }
    for i in 0..<4 { try Data("new \(i)".utf8).write(to: lib.appendingPathComponent("sub/new\(i).txt")) }
}

/// A run that dies part-way through its rsync. The real rsync is run over half the
/// tree (everything but `sub/`, so the other half is left exactly as it was), and
/// the run is then stopped as if Stop had landed mid-transfer.
private struct DiesMidRsync: CommandRunner {
    let inner = ProcessCommandRunner()
    var forTeardown: CommandRunner { inner }
    func run(_ launchPath: String, _ args: [String], stdin: Data?) throws -> CommandResult {
        guard (launchPath as NSString).lastPathComponent == "rsync" else { return try inner.run(launchPath, args, stdin: stdin) }
        let partial = try inner.run(launchPath, ["--exclude", "sub/"] + args, stdin: stdin)
        #expect(partial.ok, "\(partial.stderr)")
        throw CancelledError()
    }
}

@Suite(.serialized) struct MirrorCrashSafety {

    // Before: rsync --delete rewrote the only copy in place, so a run that stopped
    // part-way left a library that was half one day and half the next. The copy a
    // restore reads now stays exactly the previous complete one.
    @Test func aRunThatDiesMidRsyncLeavesThePreviousCopyWhole() throws {
        let src = try library(files: 40)
        let out = tempDir("die"), base = tempDir("base")
        defer { for d in [out, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        let bundle = try SparseBundleMirrorEngine(sizeGB: 1, mountBase: base)
            .archive(ArchiveSource(name: "Lib", root: src), to: out).artifacts[0]
        let before = tree(src)

        try editEverything(src, files: 40)
        #expect(throws: CancelledError.self) {
            try SparseBundleMirrorEngine(sizeGB: 1, runner: DiesMidRsync(), mountBase: base)
                .archive(ArchiveSource(name: "Lib", root: src), to: out)
        }
        let inside = try insideMirror(bundle)
        #expect(inside.library == before, "the copy a restore reads was changed by a run that didn't finish")
    }

    // The next run takes whatever the dead one left in staging and finishes the job:
    // the library matches the source exactly and nothing is left beside it.
    @Test func theRunAfterACrashRepairsWhatWasLeft() throws {
        let src = try library(files: 40)
        let out = tempDir("repair"), base = tempDir("base")
        defer { for d in [out, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        let engine = SparseBundleMirrorEngine(sizeGB: 1, mountBase: base)
        let bundle = try engine.archive(ArchiveSource(name: "Lib", root: src), to: out).artifacts[0]
        try editEverything(src, files: 40)
        _ = try? SparseBundleMirrorEngine(sizeGB: 1, runner: DiesMidRsync(), mountBase: base)
            .archive(ArchiveSource(name: "Lib", root: src), to: out)
        #expect(try insideMirror(bundle).root.contains(MirrorCopy.stagingName), "the dead run should have left its work in staging")

        _ = try engine.archive(ArchiveSource(name: "Lib", root: src), to: out)
        let inside = try insideMirror(bundle)
        #expect(inside.library == tree(src))
        #expect(inside.root == ["Lib"], "left behind at the image's root: \(inside.root)")
    }

    // Stop pressed for real while rsync is copying: the rsync process is terminated.
    @Test func stoppingWhileRsyncIsCopyingLeavesThePreviousCopyWhole() throws {
        let src = try library(files: 40)
        let out = tempDir("stop"), base = tempDir("base")
        defer { for d in [out, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        let bundle = try SparseBundleMirrorEngine(sizeGB: 1, mountBase: base)
            .archive(ArchiveSource(name: "Lib", root: src), to: out).artifacts[0]
        let before = tree(src)
        // enough new data that rsync is still at it when the first new file lands
        try editEverything(src, files: 40)
        let bulk = src.appendingPathComponent("bulk")
        try FileManager.default.createDirectory(at: bulk, withIntermediateDirectories: true)
        for i in 0..<400 { try Data(repeating: UInt8(i % 251), count: 256 * 1024).write(to: bulk.appendingPathComponent("b\(i).bin")) }

        let control = RunControl()
        let stopper = StopOnceCopying(inner: ProcessCommandRunner(control: control), base: base)
        #expect(throws: CancelledError.self) {
            try SparseBundleMirrorEngine(sizeGB: 1, runner: stopper, mountBase: base)
                .archive(ArchiveSource(name: "Lib", root: src), to: out)
        }
        #expect(stopper.stoppedWhileCopying, "Stop didn't land while rsync was running, so this proves nothing")
        #expect(try insideMirror(bundle).library == before)
    }

    // After a completed run, a restore returns the new state, not the old one.
    @Test func aRestoreAfterTheSwapReturnsTheNewCopy() throws {
        let src = try library(files: 20)
        let out = tempDir("restore"), base = tempDir("base"), back = tempDir("back")
        defer { for d in [out, base, back, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        let engine = SparseBundleMirrorEngine(sizeGB: 1, mountBase: base)
        _ = try engine.archive(ArchiveSource(name: "Lib", root: src), to: out)
        try editEverything(src, files: 20)
        let result = try engine.archive(ArchiveSource(name: "Lib", root: src), to: out)
        try ArchiveManifest.write(try ArchiveManifest.build(for: result), toDir: out)

        let archive = try #require(RestoreDiscovery.archive(at: out))
        let restored = try RestoreEngine().restore(archive, to: back)
        #expect(tree(restored) == tree(src))
    }

    // The copy being updated must be a clone: a copy of a large library inside the
    // image would double its size on every run.
    @Test func theStagingCopyIsAClone() throws {
        let src = try library(files: 10)
        try Data(repeating: 0x5A, count: 64 << 20).write(to: src.appendingPathComponent("big.bin"))
        let out = tempDir("clone"), base = tempDir("base")
        defer { for d in [out, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        _ = try SparseBundleMirrorEngine(sizeGB: 1, mountBase: base).archive(ArchiveSource(name: "Lib", root: src), to: out)

        let meter = UsageAtRsync()
        _ = try SparseBundleMirrorEngine(sizeGB: 1, runner: meter, mountBase: base).archive(ArchiveSource(name: "Lib", root: src), to: out)
        let (atAttach, atRsync) = try #require(meter.usage)
        #expect(atRsync >= atAttach)
        #expect(atRsync - atAttach < 8 << 20, "the staging copy took \(atRsync - atAttach) bytes for a 64 MB library")
    }

    // Every standard home folder carries a deny-delete ACL, which rsync -E copies
    // onto the mirror's top folder. A folder with one can't be renamed, so the swap
    // has to lift it, and put it back on the new copy.
    @Test func aLibraryWhoseFolderDeniesDeleteIsStillSwapped() throws {
        let src = try library(files: 6)
        let out = tempDir("acl"), base = tempDir("base")
        defer {
            _ = try? ProcessCommandRunner().run("/bin/chmod", ["-R", "-N", src.path])
            for d in [out, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) }
        }
        for dir in [src, src.appendingPathComponent("sub")] {
            let r = try ProcessCommandRunner().run("/bin/chmod", ["+a", "everyone deny delete", dir.path])
            try #require(r.ok, "\(r.stderr)")
        }
        let engine = SparseBundleMirrorEngine(sizeGB: 1, mountBase: base)
        let bundle = try engine.archive(ArchiveSource(name: "Lib", root: src), to: out).artifacts[0]
        try editEverything(src, files: 6)
        _ = try engine.archive(ArchiveSource(name: "Lib", root: src), to: out)

        let inside = try insideMirror(bundle)
        #expect(inside.library == tree(src))
        #expect(inside.root == ["Lib"], "the previous copy was left behind: \(inside.root)")
        let mnt = tempDir("acl-look")
        defer { MountPoint.detach(mnt, runner: ProcessCommandRunner()); try? FileManager.default.removeItem(at: mnt) }
        let r = try DiskImageGate.serialized { try ProcessCommandRunner().runRetryingBusy(hdiutil, ["attach", bundle.path, "-mountpoint", mnt.path, "-nobrowse", "-readonly"]) }
        try #require(r.ok)
        let ls = try ProcessCommandRunner().run("/bin/ls", ["-led", mnt.appendingPathComponent("Lib").path])
        #expect(ls.stdout.contains("deny delete"), "the new copy lost its folder's ACL:\n\(ls.stdout)")
    }

    // A drill of a mirror checks what a restore would copy, not the whole volume: a
    // copy left in staging by a crash isn't counted as part of the library.
    @Test func aDrillLooksOnlyAtTheLibraryCopy() throws {
        let src = try library(files: 10)
        let out = tempDir("drill"), base = tempDir("base")
        defer { for d in [out, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        let result = try SparseBundleMirrorEngine(sizeGB: 1, mountBase: base).archive(ArchiveSource(name: "Lib", root: src), to: out)
        try editEverything(src, files: 10)
        _ = try? SparseBundleMirrorEngine(sizeGB: 1, runner: DiesMidRsync(), mountBase: base)
            .archive(ArchiveSource(name: "Lib", root: src), to: out)

        let type = ContentType.genericFolder(id: "l", displayName: "Lib", path: .home("Lib"))
        let rep = try StrongVerifier().verify(result, type: type)
        #expect(rep.passed, "\(rep.details)")
        #expect(rep.details.contains("10 file(s)"), "\(rep.details)")
    }
}

/// A mirror's manifest describes the image at rest. A run that stops part-way has
/// already changed the image (new bands, a staging copy), so the checksum no longer
/// matched and the restore, drill and rehearsal all refused the complete previous
/// copy inside it until the job next ran successfully.
@Suite(.serialized) struct InterruptedMirrorRestores {

    /// what JobExecutor writes after a mirror run (the engine does it itself now).
    private func sealLikeTheExecutor(_ result: ArchiveResult, in dir: URL) throws {
        try ArchiveManifest.write(try ArchiveManifest.build(for: result), toDir: dir)
    }

    @Test func aMirrorWhoseRunWasStoppedStillRestoresThePreviousCopy() throws {
        let src = try library(files: 20)
        let out = tempDir("int"), base = tempDir("base"), back = tempDir("back")
        defer { for d in [out, base, back, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        let result = try SparseBundleMirrorEngine(sizeGB: 1, mountBase: base).archive(ArchiveSource(name: "Lib", root: src), to: out)
        try sealLikeTheExecutor(result, in: out)
        let before = tree(src)

        try editEverything(src, files: 20)
        _ = try? SparseBundleMirrorEngine(sizeGB: 1, runner: DiesMidRsync(), mountBase: base)
            .archive(ArchiveSource(name: "Lib", root: src), to: out)

        let archive = try #require(RestoreDiscovery.archive(at: out))
        let restored = try RestoreEngine().restore(archive, to: back, verify: true)
        #expect(tree(restored) == before)
        let check = try ChecksumVerifier().reverify(archiveDir: out)
        #expect(check.passed, "\(check.details)")
    }

    // While a crash mark stands the checksum isn't compared, but a band the mirror had
    // when it was last sealed is still required: losing one is damage, and said so.
    @Test func aBandLostUnderACrashMarkIsReportedByTheChecksAndHealth() throws {
        let src = try library(files: 4)
        for i in 0..<3 { try Data(repeating: UInt8(i + 1), count: 9 << 20).write(to: src.appendingPathComponent("big\(i).bin")) }
        let dest = tempDir("lostband"), base = tempDir("base")
        let out = dest.appendingPathComponent("Lib")
        defer { for d in [dest, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        let bundle = try SparseBundleMirrorEngine(sizeGB: 1, mountBase: base).archive(ArchiveSource(name: "Lib", root: src), to: out).artifacts[0]
        try MirrorSeal.markOpen(out)                      // as a crashed run leaves it
        #expect(try ChecksumVerifier().reverify(archiveDir: out).passed, "an intact mirror under a mark should pass")

        let band = MirrorSeal.bands(of: bundle).filter { $0 != 0 }.last!
        try FileManager.default.removeItem(at: bundle.appendingPathComponent("bands/\(String(band, radix: 16))"))
        let check = try ChecksumVerifier().reverify(archiveDir: out)
        #expect(!check.passed)
        #expect(check.details.contains("missing"), "\(check.details)")
        let job = BackupJob(id: "j", name: "j", libraries: [.genericFolder(id: "l", displayName: "Lib", path: .home("Lib"))],
                            target: .localVolume(id: "t", name: "Disk", dir: dest),
                            format: .liveMirror(sizeGB: 1), frequency: .manual, createdAt: Date())
        let health = HealthChecker().check(job: job)
        #expect(health.checks.first.map { !$0.passed && !$0.skipped } == true, "\(health.checks)")
    }

    // A run killed outright leaves the image attached and nothing re-sealed. The
    // launch sweep detaches it; the restore then opens the previous copy, and the
    // checksum pass says it didn't check rather than calling the mirror corrupt.
    @Test func aMirrorWhoseRunCrashedRestoresAfterTheLaunchSweep() throws {
        let src = try library(files: 12)
        let dest = tempDir("crash"), base = tempDir("base"), back = tempDir("back")
        let out = dest.appendingPathComponent("Lib")           // <destination>/<library>, as a job lays it out
        defer { for d in [dest, base, back, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        let result = try SparseBundleMirrorEngine(sizeGB: 1, mountBase: base).archive(ArchiveSource(name: "Lib", root: src), to: out)
        try sealLikeTheExecutor(result, in: out)
        let before = tree(src)

        // the crashed run: marked open, attached at its own directory, half-written
        try MirrorSeal.markOpen(out)
        let work = base.appendingPathComponent(MirrorMounts.prefix + "crashed")
        let mnt = work.appendingPathComponent("mnt")
        try FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)
        let me = ProcessIdentity.current!
        try JSONEncoder().encode(ProcessIdentity(pid: me.pid, startedAt: me.startedAt - 1))
            .write(to: work.appendingPathComponent(OpenedArchive.ownerFileName))
        let r = try DiskImageGate.serialized {
            try ProcessCommandRunner().runRetryingBusy(hdiutil, ["attach", result.artifacts[0].path, "-mountpoint", mnt.path, "-nobrowse"])
        }
        try #require(r.ok, "\(r.stderr)")
        defer { MountPoint.detach(mnt, runner: ProcessCommandRunner()) }
        let staging = mnt.appendingPathComponent("\(MirrorCopy.stagingName)/Lib")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for i in 0..<200 { try Data(repeating: 1, count: 64 * 1024).write(to: staging.appendingPathComponent("half\(i).bin")) }

        ArchiveReader.sweepStaleOpens(in: base)
        #expect(!MountPoint.isMounted(mnt))

        let archive = try #require(RestoreDiscovery.archive(at: out))
        let restored = try RestoreEngine().restore(archive, to: back, verify: true)
        #expect(tree(restored) == before)

        let job = BackupJob(id: "j", name: "j", libraries: [.genericFolder(id: "l", displayName: "Lib", path: .home("Lib"))],
                            target: .localVolume(id: "t", name: "Disk", dir: dest),
                            format: .liveMirror(sizeGB: 1), frequency: .manual, createdAt: Date())
        let health = HealthChecker().check(job: job)
        #expect(health.checks.first?.skipped == true, "\(health.checks)")
    }
}

@Test func sealedBandsAreRecordedAsRanges() throws {
    #expect(MirrorSeal.bandRanges([]) == "")
    #expect(MirrorSeal.bandRanges([0, 1, 2, 5, 16, 17]) == "0-2,5,10-11")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cf-bands-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("bands"), withIntermediateDirectories: true)
    for n in [0, 1, 2, 5, 16] { try Data().write(to: dir.appendingPathComponent("bands/\(String(n, radix: 16))")) }
    #expect(MirrorSeal.missingBands("0-2,5,10-11", in: dir) == [17])
}

/// presses Stop once rsync has written a new file into the staging copy.
private final class StopOnceCopying: CommandRunner, @unchecked Sendable {
    let inner: ProcessCommandRunner
    let base: URL
    private(set) var stoppedWhileCopying = false
    init(inner: ProcessCommandRunner, base: URL) { self.inner = inner; self.base = base }
    var control: RunControl? { inner.control }
    var forTeardown: CommandRunner { inner.forTeardown }
    func run(_ launchPath: String, _ args: [String], stdin: Data?) throws -> CommandResult {
        guard (launchPath as NSString).lastPathComponent == "rsync", let dest = args.last else {
            return try inner.run(launchPath, args, stdin: stdin)
        }
        let marker = URL(fileURLWithPath: dest).appendingPathComponent("bulk/b0.bin").path
        let control = inner.control
        let watcher = Thread { [weak self] in
            let start = ProcessInfo.processInfo.systemUptime
            while ProcessInfo.processInfo.systemUptime - start < 60 {
                if FileManager.default.fileExists(atPath: marker) {
                    self?.stoppedWhileCopying = true
                    control?.cancel(); return
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        watcher.start()
        return try inner.run(launchPath, args, stdin: stdin)
    }
}

/// the image volume's used bytes when it is attached, and again when rsync starts.
private final class UsageAtRsync: CommandRunner, @unchecked Sendable {
    let inner = ProcessCommandRunner()
    var forTeardown: CommandRunner { inner }
    private var atAttach: UInt64?
    private(set) var usage: (UInt64, UInt64)?
    func run(_ launchPath: String, _ args: [String], stdin: Data?) throws -> CommandResult {
        let tool = (launchPath as NSString).lastPathComponent
        if tool == "rsync", let dest = args.last, let a = atAttach { usage = (a, Self.used(dest)) }
        let r = try inner.run(launchPath, args, stdin: stdin)
        if tool == "hdiutil", args.first == "attach", r.ok, let i = args.firstIndex(of: "-mountpoint") {
            atAttach = Self.used(args[i + 1])
        }
        return r
    }
    static func used(_ path: String) -> UInt64 {
        sync()
        var s = statfs()
        guard statfs(path, &s) == 0 else { return 0 }
        return (UInt64(s.f_blocks) - UInt64(s.f_bfree)) * UInt64(s.f_bsize)
    }
}

/// openrsync's -E gives up on any file its owner can't write, and every git
/// repository keeps its objects that way. Those files now take another path through
/// the run; it has to be as faithful as -E and keep --delete's promise.
@Suite(.serialized) struct ReadOnlyFilesInAMirror {

    @Test func aReadOnlyFileKeepsItsAttributesForkAndACLAndGoesWhenDeleted() throws {
        let src = try library(files: 4)
        let fm = FileManager.default
        let odd = src.appendingPathComponent("objects/a*b [1]?")
        let gone = src.appendingPathComponent("objects/gone")
        try fm.createDirectory(at: odd.deletingLastPathComponent(), withIntermediateDirectories: true)
        for f in [odd, gone] { try Data("blob \(f.lastPathComponent)".utf8).write(to: f) }
        #expect(setxattr(odd.path, "com.example.tag", "v1", 2, 0, 0) == 0)
        #expect(setxattr(odd.path, "com.apple.ResourceFork", "FORK", 4, 0, 0) == 0)
        let acl = try ProcessCommandRunner().run("/bin/chmod", ["+a", "everyone deny write", odd.path])
        try #require(acl.ok, "\(acl.stderr)")
        for f in [odd, gone] { chmod(f.path, 0o444) }
        let out = tempDir("ro"), base = tempDir("base")
        defer {
            _ = try? ProcessCommandRunner().run("/bin/chmod", ["-R", "-N", src.path])
            for d in [out, base, src.deletingLastPathComponent()] { try? fm.removeItem(at: d) }
        }
        let engine = SparseBundleMirrorEngine(sizeGB: 1, mountBase: base)
        let bundle = try engine.archive(ArchiveSource(name: "Lib", root: src), to: out).artifacts[0]
        chmod(gone.path, 0o644); try fm.removeItem(at: gone)
        _ = try engine.archive(ArchiveSource(name: "Lib", root: src), to: out)

        let mnt = tempDir("ro-look")
        defer { MountPoint.detach(mnt, runner: ProcessCommandRunner()); try? fm.removeItem(at: mnt) }
        let r = try DiskImageGate.serialized { try ProcessCommandRunner().runRetryingBusy(hdiutil, ["attach", bundle.path, "-mountpoint", mnt.path, "-nobrowse", "-readonly"]) }
        try #require(r.ok, "\(r.stderr)")
        let copy = mnt.appendingPathComponent("Lib/objects/a*b [1]?")
        #expect(tree(mnt.appendingPathComponent("Lib")) == tree(src))
        #expect(!fm.fileExists(atPath: mnt.appendingPathComponent("Lib/objects/gone").path), "a deleted read-only file stayed in the mirror")
        var st = stat(), orig = stat()
        #expect(lstat(copy.path, &st) == 0 && st.st_mode & 0o777 == 0o444)
        // writing the resource fork moves the date; the library's goes back on
        #expect(lstat(odd.path, &orig) == 0 && st.st_mtimespec.tv_sec == orig.st_mtimespec.tv_sec, "the read-only file's date changed")
        var buf = [UInt8](repeating: 0, count: 16)
        #expect(getxattr(copy.path, "com.example.tag", &buf, 16, 0, 0) == 2)
        #expect(getxattr(copy.path, "com.apple.ResourceFork", &buf, 16, 0, 0) == 4)
        let ls = try ProcessCommandRunner().run("/bin/ls", ["-le", copy.path])
        #expect(ls.stdout.contains("deny write"), "the read-only file lost its ACL:\n\(ls.stdout)")
    }
}

/// A destination reached through a symlink: a folder in the home folder pointing at
/// an external drive, or a destination that is itself a link.
@Suite(.serialized) struct SymlinkedDestinations {

    @Test func aDestinationThatIsItselfASymlinkIsScanned() throws {
        let src = try library(files: 4)
        let real = tempDir("real"), links = tempDir("links"), base = tempDir("base"), back = tempDir("back")
        defer { for d in [real, links, base, back, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        _ = try SparseBundleMirrorEngine(sizeGB: 1, mountBase: base).archive(ArchiveSource(name: "Lib", root: src), to: real.appendingPathComponent("Lib"))
        let dest = links.appendingPathComponent("Backups")
        try FileManager.default.createSymbolicLink(at: dest, withDestinationURL: real)

        // the destination itself is the link, and a folder holding it links to it
        for place in [dest, links] {
            let found = RestoreDiscovery.scan(place)
            #expect(found.map(\.libraryName) == ["Lib"], "scanning \(place.lastPathComponent) found \(found.map(\.libraryName))")
            if let archive = found.first {
                let check = try ChecksumVerifier().reverify(archiveDir: archive.dir)
                #expect(check.passed, "\(check.details)")
            }
        }
        let restored = try RestoreEngine().restore(try #require(RestoreDiscovery.scan(dest).first), to: back, verify: true)
        #expect(tree(restored) == tree(src))
    }

    // A manifest written through a symlink before this fix holds the digest taken
    // with bare file names (the fallback when the spellings differed). It must still
    // check out, or every mirror written that way fails its checksum on upgrade.
    @Test func aManifestWrittenThroughASymlinkBeforeTheFixStillChecksOut() throws {
        let dir = tempDir("legacy")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = dir.appendingPathComponent("Lib.sparsebundle")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("bands"), withIntermediateDirectories: true)
        for (name, size) in [("bands/0", 10), ("bands/1", 20), ("Info.plist", 5)] {
            try Data(count: size).write(to: bundle.appendingPathComponent(name))
        }
        let legacy = Checksum.nameOnlyDigest(of: bundle)
        let manifest = VerificationManifest(format: .liveMirror, artifacts: [
            ArtifactDigest(name: "Lib.sparsebundle", size: Checksum.byteSize(of: bundle), sha256: legacy)])
        #expect(legacy != (try Checksum.digest(of: bundle)))
        #expect(try ChecksumVerifier().verify(manifest, in: dir).passed)
        try Data(count: 1).write(to: bundle.appendingPathComponent("bands/2"))
        #expect(try !ChecksumVerifier().verify(manifest, in: dir).passed, "a changed bundle passed on the legacy digest")
    }
}

/// A rehearsal looks where a recovery looks. For a mirror that is <volume>/<name>,
/// not "anything at the volume's root" (which always holds .fseventsd).
@Suite(.serialized) struct RehearsingAMirror {

    @Test func aMirrorWithoutItsLibraryFailsTheRehearsal() throws {
        let src = try library(files: 4)
        let dest = tempDir("reh"), base = tempDir("base")
        let out = dest.appendingPathComponent("Lib")
        defer { for d in [dest, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        let result = try SparseBundleMirrorEngine(sizeGB: 1, mountBase: base).archive(ArchiveSource(name: "Lib", root: src), to: out)
        #expect(RecoveryRehearsal().rehearse(destination: dest, expecting: ["Lib"]).passed)

        // the library folder goes missing inside an otherwise sound image
        let mnt = tempDir("reh-mnt")
        let r = try DiskImageGate.serialized { try ProcessCommandRunner().runRetryingBusy(hdiutil, ["attach", result.artifacts[0].path, "-mountpoint", mnt.path, "-nobrowse"]) }
        try #require(r.ok, "\(r.stderr)")
        try FileManager.default.moveItem(at: mnt.appendingPathComponent("Lib"), to: mnt.appendingPathComponent("Elsewhere"))
        MountPoint.detach(mnt, runner: ProcessCommandRunner()); try? FileManager.default.removeItem(at: mnt)
        try ArchiveManifest.write(try ArchiveManifest.build(for: result), toDir: out)

        let rehearsal = RecoveryRehearsal().rehearse(destination: dest, expecting: ["Lib"])
        #expect(!rehearsal.passed, "a mirror a restore would find nothing in passed the rehearsal: \(rehearsal.outcomes.map(\.detail))")
    }
}

extension ReadOnlyFilesInAMirror {
    // The path taken when a read-only name holds a backslash (no filters at all) has
    // to be as faithful as the usual one: the library folder's own ACL, a writable
    // file's attributes, the read-only files' modes and attributes, and deletions.
    @Test func theBackslashPathKeepsEverythingTheUsualPathKeeps() throws {
        let src = try library(files: 4)
        let fm = FileManager.default
        let bs = src.appendingPathComponent("sub/back\\slash.txt")
        try Data("bs".utf8).write(to: bs)
        #expect(setxattr(bs.path, "com.example.tag", "v1", 2, 0, 0) == 0)
        chmod(bs.path, 0o444)
        let tagged = src.appendingPathComponent("tagged.txt")
        try Data("t".utf8).write(to: tagged)
        #expect(setxattr(tagged.path, "com.example.tag", "v1", 2, 0, 0) == 0)
        let acl = try ProcessCommandRunner().run("/bin/chmod", ["+a", "everyone deny delete", src.path])
        try #require(acl.ok, "\(acl.stderr)")
        let out = tempDir("bs"), base = tempDir("base")
        defer {
            _ = try? ProcessCommandRunner().run("/bin/chmod", ["-R", "-N", src.path])
            for d in [out, base, src.deletingLastPathComponent()] { try? fm.removeItem(at: d) }
        }
        let engine = SparseBundleMirrorEngine(sizeGB: 1, mountBase: base)
        let bundle = try engine.archive(ArchiveSource(name: "Lib", root: src), to: out).artifacts[0]
        try fm.removeItem(at: src.appendingPathComponent("f0.txt"))
        _ = try engine.archive(ArchiveSource(name: "Lib", root: src), to: out)

        let mnt = tempDir("bs-look")
        defer { MountPoint.detach(mnt, runner: ProcessCommandRunner()); try? fm.removeItem(at: mnt) }
        let r = try DiskImageGate.serialized { try ProcessCommandRunner().runRetryingBusy(hdiutil, ["attach", bundle.path, "-mountpoint", mnt.path, "-nobrowse", "-readonly"]) }
        try #require(r.ok, "\(r.stderr)")
        let lib = mnt.appendingPathComponent("Lib")
        #expect(tree(lib) == tree(src))
        var buf = [UInt8](repeating: 0, count: 8), st = stat()
        #expect(getxattr(lib.appendingPathComponent("sub/back\\slash.txt").path, "com.example.tag", &buf, 8, 0, 0) == 2)
        #expect(lstat(lib.appendingPathComponent("sub/back\\slash.txt").path, &st) == 0 && st.st_mode & 0o777 == 0o444)
        #expect(getxattr(lib.appendingPathComponent("tagged.txt").path, "com.example.tag", &buf, 8, 0, 0) == 2)
        let ls = try ProcessCommandRunner().run("/bin/ls", ["-led", lib.path])
        #expect(ls.stdout.contains("deny delete"), "the library folder lost its ACL:\n\(ls.stdout)")
    }
}

/// Something else filling the drive while a run writes: the image's band writes are
/// lost, silently, whatever the run itself does. A run that saw the drive come close
/// to full must not count as a success, and must not swap in a copy it can't vouch for.
@Suite(.serialized) struct AnotherWriterOnTheDrive {

    /// fills the drive (as another program would) just before the run's rsync starts,
    /// holds it full a moment, and frees it again, so only the watch can tell.
    private final class FillsTheDriveBeforeRsync: CommandRunner, @unchecked Sendable {
        let inner = ProcessCommandRunner()
        let drive: URL
        private(set) var filled = false
        init(drive: URL) { self.drive = drive }
        var forTeardown: CommandRunner { inner }
        func run(_ launchPath: String, _ args: [String], stdin: Data?) throws -> CommandResult {
            if (launchPath as NSString).lastPathComponent == "rsync", !filled {
                filled = true
                let f = drive.appendingPathComponent("other-writer.bin")
                FileManager.default.createFile(atPath: f.path, contents: nil)
                if let h = FileHandle(forWritingAtPath: f.path) {
                    let chunk = Data(repeating: 0xA5, count: 4 << 20)
                    while (try? h.write(contentsOf: chunk)) != nil, (try? h.synchronize()) != nil {}
                    try? h.close()
                }
                Thread.sleep(forTimeInterval: 0.4)
                try? FileManager.default.removeItem(at: f)
            }
            return try inner.run(launchPath, args, stdin: stdin)
        }
    }

    @Test func aDriveFilledBySomethingElseMidRunFailsTheRunAndKeepsThePreviousCopy() throws {
        let scratch = tempDir("other"), base = tempDir("base"), back = tempDir("back")
        let src = try library(files: 10)
        let made = try ProcessCommandRunner().run(hdiutil, ["create", "-size", "300m", "-fs", "APFS", "-volname", "Drive",
                                                            "-type", "SPARSE", scratch.appendingPathComponent("drive").path])
        try #require(made.ok, "\(made.stderr)")
        let drive = scratch.appendingPathComponent("mnt")
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        let a = try DiskImageGate.serialized { try ProcessCommandRunner().runRetryingBusy(hdiutil, ["attach", scratch.appendingPathComponent("drive.sparseimage").path, "-mountpoint", drive.path, "-nobrowse"]) }
        try #require(a.ok, "\(a.stderr)")
        defer {
            MountPoint.detach(drive, runner: ProcessCommandRunner())
            for d in [scratch, base, back, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) }
        }
        let out = drive.appendingPathComponent("Lib")
        _ = try SparseBundleMirrorEngine(mountBase: base).archive(ArchiveSource(name: "Lib", root: src, sizeHint: JobExecutor.directorySize(src)), to: out)
        let before = tree(src)
        try editEverything(src, files: 10)

        let filler = FillsTheDriveBeforeRsync(drive: drive)
        #expect(throws: MirrorCopyError.driveFilledByAnother(swapped: false)) {
            try SparseBundleMirrorEngine(runner: filler, mountBase: base)
                .archive(ArchiveSource(name: "Lib", root: src, sizeHint: JobExecutor.directorySize(src)), to: out)
        }
        #expect(filler.filled)
        let archive = try #require(RestoreDiscovery.archive(at: out))
        let restored = try RestoreEngine().restore(archive, to: back, verify: true)
        #expect(tree(restored) == before, "the previous copy didn't come through a drive filled by something else")
    }

    // Two of our own jobs mirroring to one drive would each size their image to the
    // room the other is about to use. They take turns instead.
    @Test func mirrorRunsToTheSameDriveTakeTurns() throws {
        let dir = tempDir("turns"), base = tempDir("base")
        defer { for d in [dir, base] { try? FileManager.default.removeItem(at: d) } }
        let first = try #require(try VolumeLock.acquire(for: dir, in: base, control: nil))
        let got = NSLock(); var secondHeld = false
        let t = Thread {
            let second = try? VolumeLock.acquire(for: dir, in: base, control: nil)
            got.lock(); secondHeld = second != nil; got.unlock()
            second?.release()
        }
        t.start()
        Thread.sleep(forTimeInterval: 1.2)
        got.lock(); let early = secondHeld; got.unlock()
        #expect(!early, "a second run got the drive while the first held it")
        first.release()
        let start = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - start < 5 { got.lock(); let done = secondHeld; got.unlock(); if done { break }; Thread.sleep(forTimeInterval: 0.1) }
        got.lock(); #expect(secondHeld, "the second run never got its turn"); got.unlock()

        // Stop ends the wait
        let held = try #require(try VolumeLock.acquire(for: dir, in: base, control: nil))
        defer { held.release() }
        let control = RunControl(); control.cancel()
        #expect(throws: CancelledError.self) { _ = try VolumeLock.acquire(for: dir, in: base, control: control) }
    }
}

extension MirrorCrashSafety {
    // A leftover staging copy is never reused. One that can't be removed fails the run
    // plainly, with the previous copy untouched, rather than being trusted.
    @Test func aLeftoverThatWontGoFailsTheRunRatherThanBeingTrusted() throws {
        let src = try library(files: 6)
        let out = tempDir("stuck"), base = tempDir("base")
        defer { for d in [out, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        let engine = SparseBundleMirrorEngine(sizeGB: 1, mountBase: base)
        let bundle = try engine.archive(ArchiveSource(name: "Lib", root: src), to: out).artifacts[0]
        let before = tree(src)

        let mnt = tempDir("stuck-mnt")
        func attachRW() throws {
            let r = try DiskImageGate.serialized { try ProcessCommandRunner().runRetryingBusy(hdiutil, ["attach", bundle.path, "-mountpoint", mnt.path, "-nobrowse"]) }
            try #require(r.ok, "\(r.stderr)")
        }
        try attachRW()
        let locked = mnt.appendingPathComponent("\(MirrorCopy.stagingName)/Lib/locked.txt")
        try FileManager.default.createDirectory(at: locked.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("left".utf8).write(to: locked)
        #expect(chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0)
        MountPoint.detach(mnt, runner: ProcessCommandRunner())
        defer {
            if (try? attachRW()) != nil { _ = chflags(locked.path, 0); MountPoint.detach(mnt, runner: ProcessCommandRunner()) }
            try? FileManager.default.removeItem(at: mnt)
        }

        try editEverything(src, files: 6)
        #expect(throws: MirrorCopyError.self) { try engine.archive(ArchiveSource(name: "Lib", root: src), to: out) }
        #expect(try insideMirror(bundle).library == before)
    }
}
