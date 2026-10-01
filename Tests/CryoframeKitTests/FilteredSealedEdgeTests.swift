//
//  FilteredSealedEdgeTests.swift
//  CryoframeKitTests
//
//  The edges of a sealed build made from a filtered copy (a library holding named
//  pipes or sockets), and of Stop on a check of a job's archives:
//
//    - the copy is a plaintext copy of the library, even for an encrypted job, so it
//      must be gone however the build ends, a failed hdiutil included;
//    - the room check, which counted the library's bytes on disk (an APFS-compressed
//      file can make them far smaller than its copy);
//    - a file with an "everyone deny delete" access list, which stops hdiutil and is
//      now refused before any copy is made;
//    - what a filtered disk image keeps that a direct one does (creation dates and
//      sub-second modification dates), and what the mirror's copier keeps of flags
//      and folder dates as the library's locks come and go;
//    - what the launch sweep of scratch takes from a folder chosen in Settings;
//    - a folder date a sealed zip loses when it is unpacked;
//    - Stop in the middle of a zip drill's unpack, a rehearsal's attach, or a hash.
//
//  NEVER let a folder with an unreadable or foreign item reach a real hdiutil
//  create here: it puts a password dialog on the screen (see DMGSourceCheckTests).
//

import Testing
import Foundation
@testable import CryoframeKit

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-fsedge-\(tag)-\(UUID().uuidString)")
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

/// a disk image of `size` and `fs` made at `image` and mounted at `mnt`
private func mountedImage(_ image: URL, at mnt: URL, size: String, fs: String) throws {
    try FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)
    let made = try ProcessCommandRunner().run("/usr/bin/hdiutil", ["create", "-size", size, "-fs", fs, "-type", "SPARSE",
                                                                   "-volname", "Wes", image.path])
    try #require(made.ok, "\(made.stderr)")
    let attached = try DiskImageGate.serialized {
        try ProcessCommandRunner().runRetryingBusy("/usr/bin/hdiutil", ["attach", image.path + ".sparseimage",
                                                                        "-mountpoint", mnt.path, "-nobrowse", "-owners", "on"])
    }
    try #require(attached.ok && MountPoint.isMounted(mnt), "\(attached.stderr)")
}

private func freeBytes(_ url: URL) -> UInt64 {
    var fs = statfs()
    guard statfs(url.path, &fs) == 0 else { return 0 }
    return UInt64(fs.f_bavail) * UInt64(fs.f_bsize)
}

/// every item under `root` whose path holds "filtered", the copy's folder
private func filteredLeftovers(_ root: URL) -> [String] {
    (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []).filter { $0.contains(FilteredCopy.folderName) }
}

private func openOnceFree(_ result: ArchiveResult, passphrase: String? = nil) throws -> OpenedArchive {
    let until = Date().addingTimeInterval(60)
    while true {
        do { return try ArchiveReader(runner: ProcessCommandRunner()).open(result, passphrase: passphrase) }
        catch let e as DiskImageInUse where e.attachedWithoutMount && Date() < until { Thread.sleep(forTimeInterval: 1) }
    }
}

/// Stop pressed a moment after a chosen command starts
private struct StopDuring: CommandRunner {
    let inner: ProcessCommandRunner
    let during: @Sendable (String, [String]) -> Bool
    init(_ control: RunControl, during: @escaping @Sendable (String, [String]) -> Bool) {
        inner = ProcessCommandRunner(control: control); self.during = during
    }
    var control: RunControl? { inner.control }
    var forTeardown: CommandRunner { inner.forTeardown }
    func run(_ launchPath: String, _ args: [String], stdin: Data?) throws -> CommandResult {
        if during(launchPath, args) {
            let control = inner.control
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { control?.cancel() }
        }
        return try inner.run(launchPath, args, stdin: stdin)
    }
}

private final class Count: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// a job of `names`, each sealed once at <base>/dest/<name>
private func sealedJob(_ base: URL, _ kind: SealedArchiveEngine.Sealed, names: [String], bytes: Int = 64) throws -> BackupJob {
    var libraries: [ContentType] = []
    for name in names {
        let lib = base.appendingPathComponent("src/\(name)")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, bytes) }
        try data.write(to: lib.appendingPathComponent("a.bin"))
        let dir = base.appendingPathComponent("dest/\(name)")
        let result = try SealedArchiveEngine(kind).archive(ArchiveSource(name: name, root: lib), to: dir)
        try ArchiveManifest.write(try ArchiveManifest.build(for: result, encrypted: false), toDir: dir)
        libraries.append(.genericFolder(id: name.lowercased(), displayName: name, path: .absolute(lib.path)))
    }
    let target = Target.localVolume(id: "d", name: "Backups", dir: base.appendingPathComponent("dest"))
    return BackupJob(name: "Nightly", libraries: libraries, target: target, format: kind == .zip ? .sealedZip : .sealedDMG,
                     frequency: .daily(hour: 2, minute: 0), createdAt: Date(timeIntervalSince1970: 0))
}

@Suite(.serialized) struct FilteredSealedEdgeTests {

    // MARK: the plaintext copy

    // An encrypted job's folder holding a pipe and a file carrying "everyone deny
    // delete", which makes hdiutil fail: the walk before the build names it, the run
    // fails pointing at the sealed zip, and no plaintext copy is ever made. (A build
    // that fails after the copy is made: aFailedEncryptedBuildAfterTheCopyLeavesNoPlaintext.)
    @Test func aDenyDeleteFileIsRefusedBeforeAnyPlaintextCopy() async throws {
        let base = folder("fail")
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        let mnt = base.appendingPathComponent("vol")
        try mountedImage(base.appendingPathComponent("src"), at: mnt, size: "40m", fs: "HFS+")
        defer { MountPoint.detach(mnt, runner: ProcessCommandRunner()) }
        let lib = mnt.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try sh("echo secret > plans.txt && echo kept > notes.txt && chmod +a 'everyone deny delete' notes.txt", in: lib)
        try #require(mkfifo(lib.appendingPathComponent("build.pipe").path, 0o644) == 0)

        // the walk sees the deny-delete file as well as the pipe
        let blockers = JobExecutor.directoryStats(lib, forDMG: true).dmgBlockers
        #expect(!blockers.refusing.isEmpty, "the walk before the build missed the deny-delete file")

        let dest = base.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let projects = ContentType.genericFolder(id: "projects", displayName: "Projects", path: .absolute(lib.path))
        let job = BackupJob(name: "Projects", libraries: [projects], target: .localVolume(id: "d", name: "Dest", dir: dest),
                            format: .sealedDMG, frequency: .manual, encrypted: true, createdAt: Date(timeIntervalSince1970: 0))
        let scratch = base.appendingPathComponent("scratch")
        let exec = JobExecutor(helper: FakePrivilegedHelper(), detector: FakeProcessDetector(), scratchBase: scratch,
                               passphraseProvider: { _ in "pw" })
        // the copy is watched for while it exists: it is the library, in plaintext
        let sawCopy = Count()
        let copy = scratch.appendingPathComponent("\(job.id)/build/projects/filtered/Projects/plans.txt")
        let watcher = Task.detached {
            while !Task.isCancelled {
                if FileManager.default.fileExists(atPath: copy.path) { _ = sawCopy.next(); return }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        let outcome = try await exec.run(job, ownerUID: getuid(), now: Date(), control: RunControl(quietLimit: 10))
        watcher.cancel()
        guard case .finished(let results, _) = outcome, case .failed(_, _, let error)? = results.first else {
            Issue.record("expected a failed library, got \(outcome)"); return
        }
        #expect(error.contains("sealed zip"), "\(error)")
        #expect(sawCopy.value == 0, "a plaintext copy was made for a build the walk refuses")
        #expect(filteredLeftovers(scratch).isEmpty, "the plaintext copy was left in scratch: \(filteredLeftovers(scratch))")
        // and no image was left half-written beside it
        let images = (FileManager.default.enumerator(atPath: scratch.path)?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".dmg") }
        #expect(images.isEmpty, "\(images)")
    }

    // The copy's folder carries "don't back up" and "don't index" marks of its own,
    // so it stays out of Time Machine and Spotlight wherever scratch is.
    @Test func theCopyIsMarkedToBeLeftOutOfBackupsOrSearch() throws {
        let base = folder("mark")
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        let lib = base.appendingPathComponent("Lib")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try sh("echo secret > plans.txt", in: lib)
        try #require(mkfifo(lib.appendingPathComponent("build.pipe").path, 0o644) == 0)
        let buildDir = base.appendingPathComponent("build")
        let made = try FilteredCopy.make(of: lib, name: "Lib", in: buildDir, runner: ProcessCommandRunner())
        defer { FilteredCopy.remove(in: buildDir, runner: ProcessCommandRunner()) }
        let folderURL = buildDir.appendingPathComponent(FilteredCopy.folderName)
        let excluded = (try? folderURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) ?? false
        let neverIndexed = FileManager.default.fileExists(atPath: folderURL.appendingPathComponent(".metadata_never_index").path)
            || FileManager.default.fileExists(atPath: made.copy.appendingPathComponent(".metadata_never_index").path)
        #expect(excluded, "the copy isn't excluded from Time Machine")
        #expect(neverIndexed, "the copy isn't kept out of Spotlight")
    }

    // An encrypted filtered build whose hdiutil fails after the plaintext copy is
    // made. The scratch volume, where the image is written, has room for what the
    // check asks (about the library's few kilobytes) but not for the image (an
    // encrypted image of a tiny folder is ~140 KB, measured); the copy goes to the
    // startup disk's scratch, which has room. The run fails, and no plaintext is left
    // in either place, nor a half-written image.
    @Test func aFailedEncryptedBuildAfterTheCopyLeavesNoPlaintext() async throws {
        let base = folder("failbuild")
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        let mnt = base.appendingPathComponent("vol")
        try mountedImage(base.appendingPathComponent("src"), at: mnt, size: "40m", fs: "HFS+")
        defer { MountPoint.detach(mnt, runner: ProcessCommandRunner()) }
        let lib = mnt.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try sh("echo secret > plans.txt", in: lib)
        try #require(mkfifo(lib.appendingPathComponent("build.pipe").path, 0o644) == 0)
        #expect(JobExecutor.directoryStats(lib, forDMG: true).dmgBlockers.refusing.isEmpty)

        let scratchVol = base.appendingPathComponent("scratchvol")
        try mountedImage(base.appendingPathComponent("scr"), at: scratchVol, size: "10m", fs: "HFS+")
        defer { MountPoint.detach(scratchVol, runner: ProcessCommandRunner()) }
        let scratch = scratchVol.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try sh("/usr/sbin/mkfile \(freeBytes(scratchVol) - (48 << 10)) fill", in: scratchVol)
        let left = freeBytes(scratchVol)
        try #require(left > 16 << 10 && left < 100 << 10, "\(left) bytes free on the scratch volume")

        let startup = base.appendingPathComponent("startup")
        let dest = base.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let projects = ContentType.genericFolder(id: "projects", displayName: "Projects", path: .absolute(lib.path))
        let job = BackupJob(name: "Projects", libraries: [projects], target: .localVolume(id: "d", name: "Dest", dir: dest),
                            format: .sealedDMG, frequency: .manual, encrypted: true, createdAt: Date(timeIntervalSince1970: 0))
        let exec = JobExecutor(helper: FakePrivilegedHelper(), detector: FakeProcessDetector(), scratchBase: scratch,
                               plaintextScratch: startup, passphraseProvider: { _ in "pw" })
        let sawCopy = Count()
        let copy = startup.appendingPathComponent("\(job.id)/build/projects/filtered/Projects/plans.txt")
        let watcher = Task.detached {
            while !Task.isCancelled {
                if FileManager.default.fileExists(atPath: copy.path) { _ = sawCopy.next(); return }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        let outcome = try await exec.run(job, ownerUID: getuid(), now: Date(), control: RunControl(quietLimit: 20))
        watcher.cancel()
        guard case .finished(let results, _) = outcome, case .failed(_, _, let error)? = results.first else {
            Issue.record("expected a failed library, got \(outcome)"); return
        }
        #expect(sawCopy.value > 0, "the copy was never made, so no build failed after it: \(error)")
        #expect(!error.contains("not enough space on the scratch volume"), "refused up front, not a failed build: \(error)")
        #expect(filteredLeftovers(startup).isEmpty, "the plaintext copy was left: \(filteredLeftovers(startup))")
        #expect(filteredLeftovers(scratch).isEmpty, "\(filteredLeftovers(scratch))")
        #expect(!FileManager.default.fileExists(atPath: startup.appendingPathComponent(job.id).path), "the copy's folders were left")
        let images = (FileManager.default.enumerator(atPath: scratch.path)?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".dmg") }
        #expect(images.isEmpty, "a half-written image was left: \(images)")
    }

    // MARK: the launch sweep

    // The sweep at launch empties every `<scratch>/<anything>/build/<anything>` no
    // pending transfer names, and a scratch location chosen in Settings is the chosen
    // folder itself, not a folder of Cryoframe's inside it. Choose ~/Developer, and a
    // project's build output there (MyApp/build/Release) is gone at the next launch.
    @Test func theLaunchSweepLeavesWhatIsntCryoframesAlone() throws {
        let base = folder("sweep")
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        let chosen = base.appendingPathComponent("Developer")
        for rel in ["MyApp/build/Release", "Site/build/filtered"] {
            try FileManager.default.createDirectory(at: chosen.appendingPathComponent(rel), withIntermediateDirectories: true)
        }
        try sh("echo src > MyApp/main.c && echo app > MyApp/build/Release/MyApp.txt && echo page > Site/build/filtered/index.html",
               in: chosen)
        let store = PendingTransferStore(url: base.appendingPathComponent("pending.json"))
        JobExecutor.sweepOrphanedScratch(scratchBase: chosen, pendingStore: store,
                                         locks: RunLocks(directory: base.appendingPathComponent("locks")))
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: chosen.appendingPathComponent("MyApp/main.c").path))
        #expect(fm.fileExists(atPath: chosen.appendingPathComponent("MyApp/build/Release/MyApp.txt").path), "a project's build output was deleted")
        #expect(fm.fileExists(atPath: chosen.appendingPathComponent("Site/build/filtered/index.html").path), "a folder named filtered was deleted")
    }

    // MARK: room

    // A file APFS (or HFS+) keeps compressed takes a fraction of its size on disk,
    // and the copy is written out whole. The room check counted the bytes on disk, so
    // it passed and the copy filled the scratch volume; it now counts the copy
    // written out, so the run is refused up front, and nothing is left in scratch.
    @Test func aCompressedLibrarysCopyIsRefusedUpFront() async throws {
        let base = folder("room")
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        // 150 MB of text, compressed onto an HFS+ source (read live, as the fake
        // helper can't snapshot)
        let plain = base.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try sh("yes 'cryoframe compressible line of text' | head -c 157286400 > big.txt", in: plain)
        let mnt = base.appendingPathComponent("vol")
        try mountedImage(base.appendingPathComponent("src"), at: mnt, size: "400m", fs: "HFS+")
        defer { MountPoint.detach(mnt, runner: ProcessCommandRunner()) }
        let lib = mnt.appendingPathComponent("Projects")
        let dittoed = try ProcessCommandRunner().run("/usr/bin/ditto", ["--hfsCompression", plain.path, lib.path])
        try #require(dittoed.ok, "\(dittoed.stderr)")
        try? FileManager.default.removeItem(at: plain)
        try #require(mkfifo(lib.appendingPathComponent("build.pipe").path, 0o644) == 0)
        let onDisk = JobExecutor.directoryStats(lib).bytes
        try #require(onDisk < 20 << 20, "the source file wasn't stored compressed (\(onDisk) bytes on disk)")

        // scratch: a 100 MB APFS volume, room for twice the bytes on disk many times over
        let scratchVol = base.appendingPathComponent("scratchvol")
        try mountedImage(base.appendingPathComponent("scr"), at: scratchVol, size: "100m", fs: "APFS")
        defer { MountPoint.detach(scratchVol, runner: ProcessCommandRunner()) }
        let scratch = scratchVol.appendingPathComponent("scratch")
        let freeBefore = freeBytes(scratchVol)
        #expect(JobExecutor.scratchRoom(onDisk, filtered: true).needed < freeBefore)

        let dest = base.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let projects = ContentType.genericFolder(id: "projects", displayName: "Projects", path: .absolute(lib.path))
        let job = BackupJob(name: "Projects", libraries: [projects], target: .localVolume(id: "d", name: "Dest", dir: dest),
                            format: .sealedDMG, frequency: .manual, createdAt: Date(timeIntervalSince1970: 0))
        let exec = JobExecutor(helper: FakePrivilegedHelper(), detector: FakeProcessDetector(), scratchBase: scratch)
        final class Low: @unchecked Sendable { var v = UInt64.max; let l = NSLock()
            func see(_ x: UInt64) { l.lock(); v = min(v, x); l.unlock() } }
        let low = Low()
        let sampler = Task.detached {
            while !Task.isCancelled { low.see(freeBytes(scratchVol)); try? await Task.sleep(nanoseconds: 10_000_000) }
        }
        let outcome = try await exec.run(job, ownerUID: getuid(), now: Date(), control: RunControl(quietLimit: 20))
        sampler.cancel()
        guard case .finished(let results, _) = outcome, case .failed(_, _, let error)? = results.first else {
            Issue.record("expected a failed library, got \(outcome)"); return
        }
        #expect(filteredLeftovers(scratch).isEmpty, "the copy was left in scratch")
        #expect(freeBytes(scratchVol) + (8 << 20) >= freeBefore, "scratch wasn't given back")
        #expect(low.v > 8 << 20, "the scratch volume was filled to \(low.v) bytes free before the run failed")
        #expect(error.contains("not enough space"), "it wasn't refused up front: \(error)")
    }

    // MARK: what a filtered disk image keeps

    // A direct build of the library against a filtered one: creation dates and the
    // sub-second part of modification dates, on files and folders, which the parity
    // test doesn't compare.
    @Test(arguments: [false, true])
    func creationAndSubsecondDatesMatchADirectBuild(_ encrypted: Bool) throws {
        let base = folder("dates")
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        let lib = base.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try sh("mkdir -p Old/Inner && echo a > Old/a.txt && echo b > Old/Inner/b.txt && echo c > c.txt && chmod 444 c.txt", in: lib)
        // born long ago, changed since: creation date before modification date
        for rel in ["Old/a.txt", "Old/Inner/b.txt", "c.txt", "Old/Inner", "Old"] {
            let p = lib.appendingPathComponent(rel).path
            var born = [timespec(tv_sec: 1_500_000_000, tv_nsec: 0), timespec(tv_sec: 1_500_000_000, tv_nsec: 0)]
            try #require(utimensat(AT_FDCWD, p, &born, 0) == 0)          // sets birth too, as it's earlier
            var later = [timespec(tv_sec: 1_700_000_000, tv_nsec: 123_456_789), timespec(tv_sec: 1_700_000_000, tv_nsec: 123_456_789)]
            try #require(utimensat(AT_FDCWD, p, &later, 0) == 0)
        }
        let passphrase = encrypted ? "pw" : nil
        let direct = try SealedArchiveEngine(.dmg, passphrase: passphrase).archive(ArchiveSource(name: "Projects", root: lib),
                                                                                   to: base.appendingPathComponent("direct"))
        var before = [stat(), stat()]
        _ = lstat(lib.path, &before[0])
        try #require(mkfifo(lib.appendingPathComponent("build.pipe").path, 0o644) == 0)
        var keep = [before[0].st_atimespec, before[0].st_mtimespec]
        _ = utimensat(AT_FDCWD, lib.path, &keep, 0)
        let buildDir = base.appendingPathComponent("build")
        let made = try FilteredCopy.make(of: lib, name: "Projects", in: buildDir, runner: ProcessCommandRunner())
        let filtered = try SealedArchiveEngine(.dmg, passphrase: passphrase).archive(ArchiveSource(name: "Projects", root: made.copy),
                                                                                     to: buildDir)
        FilteredCopy.remove(in: buildDir, runner: ProcessCommandRunner())
        let a = try openOnceFree(direct, passphrase: passphrase)
        defer { a.close() }
        let b = try openOnceFree(filtered, passphrase: passphrase)
        defer { b.close() }
        var births: [String] = [], nsecs: [String] = []
        for rel in ["Old/a.txt", "Old/Inner/b.txt", "c.txt", "Old/Inner", "Old"] {
            var x = stat(), y = stat()
            try #require(lstat(a.root.appendingPathComponent(rel).path, &x) == 0 && lstat(b.root.appendingPathComponent(rel).path, &y) == 0)
            if x.st_birthtimespec.tv_sec != y.st_birthtimespec.tv_sec {
                births.append("\(rel): direct \(x.st_birthtimespec.tv_sec) filtered \(y.st_birthtimespec.tv_sec)")
            }
            if x.st_mtimespec.tv_sec != y.st_mtimespec.tv_sec || x.st_mtimespec.tv_nsec != y.st_mtimespec.tv_nsec {
                nsecs.append("\(rel): direct \(x.st_mtimespec.tv_sec).\(x.st_mtimespec.tv_nsec) filtered \(y.st_mtimespec.tv_sec).\(y.st_mtimespec.tv_nsec)")
            }
        }
        #expect(births.isEmpty, "creation dates differ:\n\(births.joined(separator: "\n"))")
        #expect(nsecs.isEmpty, "modification dates differ:\n\(nsecs.joined(separator: "\n"))")
    }

    // The mirror's copier, as a live mirror runs it, on hidden and locked items and a
    // read-only file: what it keeps of flags and folder dates. Measured, so the
    // report can say what a 1.6 mirror drops; 1.5.6's mirror ran plain `rsync -aE`.
    @Test func whatTheMirrorCopierKeepsOfFlagsAndFolderDates() throws {
        let base = folder("mirror")
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        let lib = base.appendingPathComponent("Lib")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try sh("""
            mkdir -p Plain RO && echo h > hidden.txt && chflags hidden hidden.txt && echo l > locked.txt && chflags uchg locked.txt && \
            echo p > Plain/p.txt && echo r > RO/r.txt && chmod 444 RO/r.txt
            """, in: lib)
        for rel in ["Plain", "RO"] {
            var t = [timespec(tv_sec: 1_600_000_000, tv_nsec: 0), timespec(tv_sec: 1_600_000_000, tv_nsec: 0)]
            try #require(utimensat(AT_FDCWD, lib.appendingPathComponent(rel).path, &t, 0) == 0)
        }
        func probe(_ copy: URL) -> [String] {
            var said: [String] = []
            for rel in ["hidden.txt", "locked.txt"] {
                var a = stat(), b = stat()
                _ = lstat(lib.appendingPathComponent(rel).path, &a); _ = lstat(copy.appendingPathComponent(rel).path, &b)
                if a.st_flags & FilteredCopy.copiedFlags != b.st_flags & FilteredCopy.copiedFlags { said.append("\(rel) flags dropped") }
            }
            for rel in ["Plain", "RO"] {
                var a = stat(), b = stat()
                _ = lstat(lib.appendingPathComponent(rel).path, &a); _ = lstat(copy.appendingPathComponent(rel).path, &b)
                if a.st_mtimespec.tv_sec != b.st_mtimespec.tv_sec { said.append("\(rel) date changed") }
            }
            return said
        }
        let mirror = base.appendingPathComponent("mirror")
        try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
        let runner = ProcessCommandRunner()
        try MirrorCopy.sync(lib, into: mirror, runner: runner) { c in
            let r = try runner.run(c.tool, c.args)
            try #require(r.ok, "\(c.tool): \(r.stderr)")
        }
        let now = probe(mirror)
        // 1.5.6: ArchivePlan.rsync was `rsync -aE --delete --partial`, run on the
        // library less its read-only file (which -E can't copy at all)
        try sh("chmod 644 RO/r.txt && rm RO/r.txt", in: lib)
        var t = [timespec(tv_sec: 1_600_000_000, tv_nsec: 0), timespec(tv_sec: 1_600_000_000, tv_nsec: 0)]
        _ = utimensat(AT_FDCWD, lib.appendingPathComponent("RO").path, &t, 0)
        let old = base.appendingPathComponent("old")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let r = try runner.run("/usr/bin/rsync", ["-aE", "--delete", "--partial", lib.path + "/", old.path + "/"])
        try #require(r.ok, "\(r.stderr)")
        let then = probe(old)
        #expect(now.isEmpty, "\(now)")
        #expect(then.contains("hidden.txt flags dropped") && then.contains("locked.txt flags dropped"), "\(then)")
    }

    // The mirror's copier run again on its own copy (as the next run updates a clone
    // of the previous one) after the library takes locks off, deletes locked items,
    // and rewrites an append-only file shorter: the copy follows, and the read-back
    // finds nothing to name.
    @Test func theMirrorCopierFollowsLocksTakenOffAndLockedItemsDeleted() throws {
        let base = folder("unlocks")
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        let lib = base.appendingPathComponent("Lib")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try sh("""
            mkdir -p Gone && echo a > was-locked.txt && chflags uchg was-locked.txt && echo h > was-hidden.txt && \
            chflags hidden was-hidden.txt && echo g > gone.txt && chflags uchg gone.txt && echo x > Gone/x.txt && \
            chflags uchg Gone/x.txt Gone && echo long-long-long > log.txt && chflags uappnd log.txt
            """, in: lib)
        let copy = base.appendingPathComponent("copy")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        let runner = ProcessCommandRunner()
        func sync() throws {
            try MirrorCopy.sync(lib, into: copy, runner: runner) { c in
                let r = try runner.run(c.tool, c.args)
                try #require(r.ok, "\(c.tool): \(r.stderr)")
            }
        }
        func flags(_ rel: String) -> UInt32 {
            var st = stat()
            return lstat(copy.appendingPathComponent(rel).path, &st) == 0 ? st.st_flags & MirrorCopy.copiedFlags : .max
        }
        try sync()
        try #require(flags("was-locked.txt") & UInt32(UF_IMMUTABLE) != 0 && flags("Gone") & UInt32(UF_IMMUTABLE) != 0
                     && flags("log.txt") & UInt32(UF_APPEND) != 0, "the first copy wasn't locked as the library is")

        try sh("""
            chflags nouchg was-locked.txt gone.txt Gone/x.txt Gone && chflags nohidden was-hidden.txt && rm -r gone.txt Gone && \
            chflags nouappnd log.txt && echo s > log.txt && chflags uappnd log.txt
            """, in: lib)
        try sync()
        #expect(flags("was-locked.txt") == 0, "a lock taken off in the library stayed on in the copy")
        #expect(flags("was-hidden.txt") == 0, "a hidden flag taken off stayed on")
        #expect(!FileManager.default.fileExists(atPath: copy.appendingPathComponent("gone.txt").path), "a deleted locked file stayed")
        #expect(!FileManager.default.fileExists(atPath: copy.appendingPathComponent("Gone").path), "a deleted locked folder stayed")
        #expect((try? String(contentsOf: copy.appendingPathComponent("log.txt"), encoding: .utf8)) == "s\n")
        #expect(flags("log.txt") == UInt32(UF_APPEND))
        let found = try MirrorCopy.structure(of: copy, against: lib, previous: nil, control: nil)
        #expect(found.count == 0, "\(found.examples)")
    }

    // MARK: a sealed zip's folder dates

    // A sealed zip unpacked (by a drill, a check, or a restore: ArchiveReader runs
    // ditto -x) dates a folder holding both a folder and a file at the moment it was
    // unpacked, not as the library has it. A folder holding only files, or only
    // folders, keeps its date. Measured on macOS 27; ditto's own doing, and a restore
    // copies the unpacked date. It is also why FilteredCopyTests' zip parity arms
    // fail now and then by 1 s on "sub": both sides are an unpack time, and two
    // unpacks sometimes straddle a second.
    @Test func aSealedZipKeepsTheDateOfAFolderHoldingAFolderAndAFile() throws {
        let base = folder("zipdate")
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        let lib = base.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try sh("mkdir -p Both/Inner OnlyFiles && echo f > Both/f.txt && echo f > OnlyFiles/f.txt", in: lib)
        for rel in ["Both/Inner", "Both", "OnlyFiles"] {
            var t = [timespec(tv_sec: 1_600_000_000, tv_nsec: 0), timespec(tv_sec: 1_600_000_000, tv_nsec: 0)]
            try #require(utimensat(AT_FDCWD, lib.appendingPathComponent(rel).path, &t, 0) == 0)
        }
        let result = try SealedArchiveEngine(.zip).archive(ArchiveSource(name: "Projects", root: lib), to: base.appendingPathComponent("out"))
        Thread.sleep(forTimeInterval: 1.1)          // an unpack date can't pass for the library's
        let opened = try openOnceFree(result)
        defer { opened.close() }
        func date(_ rel: String) -> Int {
            var st = stat()
            // a zip is unpacked with its top folder (ditto --keepParent)
            return lstat(opened.root.appendingPathComponent("Projects/" + rel).path, &st) == 0 ? st.st_mtimespec.tv_sec : -1
        }
        #expect(date("OnlyFiles") == 1_600_000_000, "\(date("OnlyFiles"))")
        #expect(date("Both/Inner") == 1_600_000_000, "\(date("Both/Inner"))")
        #expect(date("Both") == 1_600_000_000, "unpacked dated \(date("Both"))")
    }

    // MARK: Stop on a check

    // Stop while a zip drill unpacks: the unpack is ended, nothing of it is left in
    // the temporary folder, the archive isn't counted, and the job's lock is free.
    @Test func stopDuringAZipDrillsUnpackLeavesNothing() throws {
        let base = folder("unpack")
        defer { try? FileManager.default.removeItem(at: base) }
        let job = try sealedJob(base, .zip, names: ["Alpha", "Bravo"], bytes: 300 << 20)
        let before = Set(CancelableCheckTests.openWorkDirs())
        let control = RunControl(), unpacks = Count()
        let runner = StopDuring(control) { tool, args in tool.hasSuffix("ditto") && args.first == "-x" && unpacks.next() == 1 }
        let locks = RunLocks(directory: base.appendingPathComponent("locks"))
        let start = ProcessInfo.processInfo.systemUptime
        let checked = locks.whileChecking(jobID: job.id, control: control) {
            RestoreDriller(runner: runner, freeSpace: { _ in 1 << 40 }).drill(job: job)
        }
        let took = ProcessInfo.processInfo.systemUptime - start
        guard case .done(let report) = checked else { Issue.record("\(checked)"); return }
        #expect(report.canceled && report.checks.isEmpty && report.planned == 2, "\(report.checks)")
        #expect(took < 30, "Stop took \(took) s")
        #expect(Set(CancelableCheckTests.openWorkDirs()).subtracting(before).isEmpty, "an unpack folder was left")
        let lease = try locks.acquire(jobID: job.id, trigger: .check)
        lease.release()
    }

    // Stop while a rehearsal attaches a disk image: the attach is let finish, the
    // image is closed, and nothing is counted.
    @Test func stopDuringARehearsalsAttachClosesTheImage() throws {
        let base = folder("rattach")
        defer { try? FileManager.default.removeItem(at: base) }
        _ = try sealedJob(base, .dmg, names: ["Alpha", "Bravo"])
        let before = Set(CancelableCheckTests.openWorkDirs())
        let control = RunControl(), attaches = Count()
        let runner = StopDuring(control) { tool, args in tool.hasSuffix("hdiutil") && args.first == "attach" && attaches.next() == 1 }
        let report = RecoveryRehearsal(runner: runner, freeSpace: { _ in 1 << 40 })
            .rehearse(destination: base.appendingPathComponent("dest"), expecting: ["Alpha", "Bravo"])
        #expect(report.canceled && report.outcomes.isEmpty, "\(report.outcomes)")
        let opened = base.appendingPathComponent("dest/Alpha/Alpha.dmg").path
        let until = Date().addingTimeInterval(30)
        var info = ""
        repeat {
            info = try ProcessCommandRunner().run("/usr/bin/hdiutil", ["info"]).stdout
            if !info.contains(opened) { break }
            Thread.sleep(forTimeInterval: 1)
        } while Date() < until
        #expect(!info.contains(opened), "the rehearsal's image was left attached")
        #expect(Set(CancelableCheckTests.openWorkDirs()).subtracting(before).isEmpty, "a work folder was left")
    }

    // Stop pressed while a large file is being hashed (not before): the hash ends
    // within its 64 MB step, not at the end of the file.
    @Test func stopInTheMiddleOfAHashEndsIt() throws {
        let base = folder("midhash")
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("big")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        try #require(truncate(file.path, 4 << 30) == 0)
        let control = RunControl()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { control.cancel() }
        let start = ProcessInfo.processInfo.systemUptime
        #expect(throws: CancelledError.self) { _ = try Checksum.sha256(of: file, control: control) }
        let took = ProcessInfo.processInfo.systemUptime - start
        #expect(took < 1.5, "Stop took \(took) s to end the hash")
    }
}
