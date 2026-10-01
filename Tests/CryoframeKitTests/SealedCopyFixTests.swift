//
//  SealedCopyFixTests.swift
//  CryoframeKitTests
//
//  The fixes to the filtered sealed build and the mirror's copier:
//
//    - room is counted by what a copy takes written out, so a compressed library
//      can't pass the check and then fill the drive (scratch, and a new mirror);
//    - an encrypted job's plaintext copy is made only in the startup disk's scratch,
//      marked to stay out of backups and search, and removed at a run's start;
//    - an access list hdiutil can't build past is named before the build, and its
//      complaint (on standard output) is read when it isn't;
//    - a mirror carries hidden and locked flags and folder dates, and reads them back.
//
//  NEVER let a folder with an unreadable or foreign item reach a real hdiutil
//  create here: it puts a password dialog on the screen (see DMGSourceCheckTests).
//

import Testing
import Foundation
@testable import CryoframeKit

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-scfix-\(tag)-\(UUID().uuidString)")
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
                                                                   "-volname", "Fix", image.path])
    try #require(made.ok, "\(made.stderr)")
    let attached = try DiskImageGate.serialized {
        try ProcessCommandRunner().runRetryingBusy("/usr/bin/hdiutil", ["attach", image.path + ".sparseimage",
                                                                        "-mountpoint", mnt.path, "-nobrowse", "-owners", "on"])
    }
    try #require(attached.ok && MountPoint.isMounted(mnt), "\(attached.stderr)")
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock(); private var set = false
    func raise() { lock.lock(); set = true; lock.unlock() }
    var raised: Bool { lock.lock(); defer { lock.unlock() }; return set }
}

@Suite(.serialized) struct SealedCopyFixTests {

    // MARK: room

    // A file stored compressed takes a fraction of its length on disk; the copy of it
    // the mirror's copier writes takes all of it. The walk counts both, and a new
    // mirror is refused up front by the second rather than filling its drive.
    @Test func aCompressedLibrarysCopyIsCountedWholeAndANewMirrorIsRefused() async throws {
        let base = folder("cmp")
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        let plain = base.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try sh("yes 'cryoframe compressible line of text' | head -c 125829120 > big.txt", in: plain)
        let mnt = base.appendingPathComponent("vol")
        try mountedImage(base.appendingPathComponent("src"), at: mnt, size: "300m", fs: "HFS+")
        defer { MountPoint.detach(mnt, runner: ProcessCommandRunner()) }
        let lib = mnt.appendingPathComponent("Projects")
        let dittoed = try ProcessCommandRunner().run("/usr/bin/ditto", ["--hfsCompression", plain.path, lib.path])
        try #require(dittoed.ok, "\(dittoed.stderr)")
        try? FileManager.default.removeItem(at: plain)
        let stats = JobExecutor.directoryStats(lib)
        try #require(stats.bytes < 20 << 20, "not stored compressed: \(stats.bytes)")
        #expect(stats.copyBytes >= 125829120, "the copy was counted at \(stats.copyBytes)")

        // a 100 MB drive: room for the bytes on disk many times over, not for the copy
        let destVol = base.appendingPathComponent("destvol")
        try mountedImage(base.appendingPathComponent("dst"), at: destVol, size: "100m", fs: "APFS")
        defer { MountPoint.detach(destVol, runner: ProcessCommandRunner()) }
        let dest = destVol.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let projects = ContentType.genericFolder(id: "projects", displayName: "Projects", path: .absolute(lib.path))
        let job = BackupJob(name: "Projects", libraries: [projects], target: .localVolume(id: "d", name: "Dest", dir: dest),
                            format: .liveMirror(sizeGB: 1), frequency: .manual, createdAt: Date(timeIntervalSince1970: 0))
        let exec = JobExecutor(helper: FakePrivilegedHelper(), detector: FakeProcessDetector(),
                               scratchBase: base.appendingPathComponent("scratch"))
        let outcome = try await exec.run(job, ownerUID: getuid(), now: Date(), control: RunControl(quietLimit: 20))
        guard case .finished(let results, _) = outcome, case .failed(_, _, let error)? = results.first else {
            Issue.record("expected a failed library, got \(outcome)"); return
        }
        #expect(error.contains("not enough space"), "\(error)")
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("Projects/Projects.sparsebundle").path))
    }

    // A copy that fills its volume says so, whatever rsync's last words were.
    @Test func aCopyThatRanOutOfSpaceIsToldApart() throws {
        let roomy = folder("roomy")
        defer { try? FileManager.default.removeItem(at: roomy) }
        #expect(FilteredCopy.ranOutOfSpace(ArchiveError.toolFailed(tool: "rsync", status: 11, stderr: "write: No space left on device"), at: roomy))
        #expect(FilteredCopy.ranOutOfSpace(ArchiveError.toolFailed(tool: "copy", status: ENOSPC, stderr: "x"), at: roomy))
        #expect(!FilteredCopy.ranOutOfSpace(ArchiveError.toolFailed(tool: "rsync", status: 12, stderr: "unexpected end of file"), at: roomy))
        #expect(!FilteredCopy.ranOutOfSpace(CancelledError(), at: roomy))
        let said = FilteredCopyError.scratchFilled(volume: "Macintosh HD", library: "Projects").localizedDescription
        #expect(said.contains("ran out of space") && said.contains("Projects") && said.contains("copy was removed"), "\(said)")
    }

    // MARK: the plaintext copy

    // An encrypted job with a scratch location on another drive: the copy is made in
    // the startup disk's scratch and nowhere else, marked to stay out of Time Machine
    // and Spotlight while it is there, and gone after.
    @Test func anEncryptedJobsCopyIsMadeOnlyInTheStartupDisksScratch() async throws {
        let base = folder("enc")
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        let mnt = base.appendingPathComponent("vol")
        try mountedImage(base.appendingPathComponent("src"), at: mnt, size: "40m", fs: "HFS+")
        defer { MountPoint.detach(mnt, runner: ProcessCommandRunner()) }
        let lib = mnt.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try sh("echo secret > plans.txt", in: lib)
        try #require(mkfifo(lib.appendingPathComponent("build.pipe").path, 0o644) == 0)
        // "another drive": the scratch Settings names is on the library's volume here
        let picked = mnt.appendingPathComponent("scratch")
        let startup = base.appendingPathComponent("caches-scratch")
        let dest = base.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let projects = ContentType.genericFolder(id: "projects", displayName: "Projects", path: .absolute(lib.path))
        let job = BackupJob(name: "Projects", libraries: [projects], target: .localVolume(id: "d", name: "Dest", dir: dest),
                            format: .sealedDMG, frequency: .manual, encrypted: true, createdAt: Date(timeIntervalSince1970: 0))
        let exec = JobExecutor(helper: FakePrivilegedHelper(), detector: FakeProcessDetector(), scratchBase: picked,
                               plaintextScratch: startup, passphraseProvider: { _ in "pw" })
        let inStartup = startup.appendingPathComponent("\(job.id)/build/projects/filtered")
        let inPicked = picked.appendingPathComponent("\(job.id)/build/projects/filtered")
        let sawStartup = Flag(), sawPicked = Flag(), marked = Flag()
        let watcher = Task.detached {
            while !Task.isCancelled {
                if FileManager.default.fileExists(atPath: inPicked.path) { sawPicked.raise() }
                if FileManager.default.fileExists(atPath: inStartup.appendingPathComponent("Projects/plans.txt").path) {
                    sawStartup.raise()
                    let excluded = (try? inStartup.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) ?? false
                    if excluded, FileManager.default.fileExists(atPath: inStartup.appendingPathComponent(".metadata_never_index").path) {
                        marked.raise()
                    }
                }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        let outcome = try await exec.run(job, ownerUID: getuid(), now: Date(), control: RunControl(quietLimit: 20))
        watcher.cancel()
        guard case .finished(let results, _) = outcome, case .completed? = results.first else {
            Issue.record("expected a completed library, got \(outcome)"); return
        }
        #expect(sawStartup.raised, "the copy was never seen in the startup disk's scratch")
        #expect(marked.raised, "the copy wasn't marked to stay out of Time Machine and Spotlight")
        #expect(!sawPicked.raised, "the plaintext copy was made in the scratch location Settings named")
        #expect(!FileManager.default.fileExists(atPath: inStartup.path) && !FileManager.default.fileExists(atPath: inPicked.path))
        #expect(!FileManager.default.fileExists(atPath: startup.appendingPathComponent(job.id).path), "empty folders were left")
    }

    // With the copy on another volume than the archive, each is held to its own room.
    @Test func eachScratchIsHeldToItsOwnPart() throws {
        let base = folder("split")
        defer { try? FileManager.default.removeItem(at: base) }
        let mnt = base.appendingPathComponent("vol")
        try mountedImage(base.appendingPathComponent("small"), at: mnt, size: "20m", fs: "HFS+")
        defer { MountPoint.detach(mnt, runner: ProcessCommandRunner()) }
        let here = base.appendingPathComponent("scratch")
        #expect(!JobExecutor.sameVolume(here, mnt))
        #expect(JobExecutor.sameVolume(here, base.appendingPathComponent("other/not/made")))
        let copyShort = JobExecutor.scratchRefusal(archive: 1 << 20, copy: 100 << 20, scratch: here, copyScratch: mnt)
        #expect(copyShort?.contains("startup disk") == true, "\(copyShort ?? "nil")")
        #expect(JobExecutor.scratchRefusal(archive: 100 << 20, copy: 1 << 20, scratch: mnt, copyScratch: here)?
            .contains("scratch volume") == true)
        #expect(JobExecutor.scratchRefusal(archive: 1 << 20, copy: 1 << 20, scratch: mnt, copyScratch: here) == nil)
    }

    // A crash mid-build leaves the copy; the job's next run removes it before
    // anything else, from both scratch locations, and leaves another job's alone.
    @Test func aRunRemovesItsJobsLeftoverCopyAtTheStart() async throws {
        let base = folder("sweep")
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        let picked = base.appendingPathComponent("picked"), startup = base.appendingPathComponent("startup")
        let dest = base.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let gone = ContentType.genericFolder(id: "projects", displayName: "Projects", path: .absolute(base.appendingPathComponent("missing").path))
        let job = BackupJob(name: "Projects", libraries: [gone], target: .localVolume(id: "d", name: "Dest", dir: dest),
                            format: .sealedDMG, frequency: .manual, createdAt: Date(timeIntervalSince1970: 0))
        var left: [URL] = []
        for root in [picked, startup] {
            let copy = root.appendingPathComponent("\(job.id)/build/projects/filtered/Projects")
            try ScratchLayout.claim(libraryDir: copy.deletingLastPathComponent().deletingLastPathComponent())
            try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
            try sh("echo secret > plans.txt && chflags uchg plans.txt", in: copy)
            left.append(copy.deletingLastPathComponent())
        }
        let other = picked.appendingPathComponent("other-job/build/lib/filtered/Lib")
        try ScratchLayout.claim(libraryDir: other.deletingLastPathComponent().deletingLastPathComponent())
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let exec = JobExecutor(helper: FakePrivilegedHelper(), detector: FakeProcessDetector(), scratchBase: picked,
                               plaintextScratch: startup)
        _ = try? await exec.run(job, ownerUID: getuid(), now: Date())
        for l in left { #expect(!FileManager.default.fileExists(atPath: l.path), "\(l.path) was left") }
        #expect(FileManager.default.fileExists(atPath: other.path), "another job's copy was removed")
    }

    // MARK: access lists hdiutil can't build past

    // Measured on macOS 27 (see DMGBlockers.accessListStopsDiskImage): which entries
    // the walk names, and which it lets through.
    @Test func theWalkNamesTheAccessListsThatStopADiskImage() throws {
        let lib = folder("acl")
        defer { unlock(lib); try? FileManager.default.removeItem(at: lib) }
        let me = NSUserName()
        try sh("""
            mkdir -p Home Attr Later && for f in a b c d e f g; do echo x > $f.txt; done && \
            chmod +a 'everyone deny delete' a.txt && chmod +a 'user:\(me) deny readextattr' b.txt && \
            chmod +a 'group:staff deny delete' c.txt && chmod +a 'user:nobody deny delete' d.txt && \
            chmod +a 'everyone allow delete' e.txt && chmod +a 'everyone deny writeattr' f.txt && \
            chmod +a 'everyone deny delete' Home && chmod +a 'everyone deny readattr' Attr && \
            chmod +a 'everyone deny delete,file_inherit,only_inherit' Later
            """, in: lib)
        let found = JobExecutor.directoryStats(lib, forDMG: true).dmgBlockers
        let staff = (getgrnam("staff")?.pointee.gr_gid).map { gid in
            var n: Int32 = 64; var list = [Int32](repeating: 0, count: 64)
            getgrouplist(me, Int32(bitPattern: getgid()), &list, &n)
            return list.prefix(Int(n)).contains(Int32(bitPattern: gid))
        } ?? false
        let expected: Set<String> = staff ? ["a.txt", "b.txt", "c.txt"] : ["a.txt", "b.txt"]
        #expect(Set(found.examples[.accessList] ?? []) == expected, "\(found.counts) \(found.examples)")
        #expect(found.refusing.counts[.accessList] == expected.count)
        // a folder whose attributes may not be read can't be listed either: unreadable
        #expect(found.examples[.unreadable] == ["Attr"], "\(found.examples)")
        let said = found.refusing.explanation(library: "Projects")
        #expect(said.contains("access list") && said.contains("sealed zip") && said.contains("a.txt"), "\(said)")
        // a zip is stopped by none of them
        #expect(JobExecutor.directoryStats(lib, forZip: true).dmgBlockers.isEmpty)
    }

    // hdiutil names the file it couldn't copy on standard output; a direct build's
    // failure now carries it, and the explanation that points at the sealed zip.
    @Test func aDirectBuildBlockedByAnAccessListSaysWhichFileAndWhatToDo() throws {
        let base = folder("direct")
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        let lib = base.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try sh("echo kept > notes.txt && chmod +a 'everyone deny delete' notes.txt", in: lib)
        #expect(throws: ArchiveError.self) {
            do { _ = try SealedArchiveEngine(.dmg).archive(ArchiveSource(name: "Projects", root: lib), to: base.appendingPathComponent("out")) }
            catch {
                let said = error.localizedDescription
                #expect(said.contains("sealed zip") && said.contains("notes.txt"), "\(said)")
                throw error
            }
        }
        let merged = SealedArchiveEngine.failureText(CommandResult(status: 1, stdout: "could not access /Volumes/P/x.txt - Permission denied\n",
                                                                   stderr: "hdiutil: create failed - Permission denied\n"))
        #expect(merged.hasPrefix("could not access /Volumes/P/x.txt"), "\(merged)")
        #expect(SealedArchiveEngine.failureText(CommandResult(status: 1, stdout: "created: x\n", stderr: "boom\n")) == "boom\n")
    }

    // MARK: mirror fidelity

    // A live mirror keeps hidden and locked flags and the date of a folder holding a
    // read-only file, reads them back, runs again over its own locked copy after the
    // library changed, and a restore brings them back.
    @Test func aMirrorKeepsFlagsAndFolderDatesRunAfterRun() throws {
        let base = folder("mflags")
        let src = base.appendingPathComponent("src/Lib"), out = base.appendingPathComponent("out"), mounts = base.appendingPathComponent("m")
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try sh("""
            mkdir -p Plain RO Locked && echo h > hidden.txt && chflags hidden hidden.txt && echo l > locked.txt && \
            chflags uchg locked.txt && echo p > Plain/p.txt && echo r > RO/r.txt && chmod 444 RO/r.txt && \
            echo k > Locked/k.txt && chflags uchg Locked
            """, in: src)
        func dateFolders() throws {
            for rel in ["Plain", "RO"] {
                var t = [timespec(tv_sec: 1_600_000_000, tv_nsec: 0), timespec(tv_sec: 1_600_000_000, tv_nsec: 0)]
                try #require(utimensat(AT_FDCWD, src.appendingPathComponent(rel).path, &t, 0) == 0)
            }
        }
        try dateFolders()
        func mirror() throws {
            _ = try SparseBundleMirrorEngine(sizeGB: 1, mountBase: mounts).archive(ArchiveSource(name: "Lib", root: src), to: out)
        }
        func probe() throws -> [String] {
            let image = try #require(LibraryFolders.mirrorImage(in: out))
            let opened = try ArchiveReader(runner: ProcessCommandRunner())
                .open(ArchiveResult(artifacts: [out.appendingPathComponent(image)], format: .liveMirror), passphrase: nil)
            defer { opened.close() }
            let copy = opened.root.appendingPathComponent("Lib")
            var said: [String] = []
            for rel in ["hidden.txt", "locked.txt", "Locked", "RO", "Plain"] {
                var a = stat(), b = stat()
                _ = lstat(src.appendingPathComponent(rel).path, &a); _ = lstat(copy.appendingPathComponent(rel).path, &b)
                if a.st_flags & MirrorCopy.copiedFlags != b.st_flags & MirrorCopy.copiedFlags { said.append("\(rel) flags") }
                if a.st_mode & S_IFMT == S_IFDIR, a.st_mtimespec.tv_sec != b.st_mtimespec.tv_sec { said.append("\(rel) date") }
            }
            return said
        }
        try mirror()
        let first = try probe()
        #expect(first.isEmpty, "first run: \(first)")
        // the library changes under its locks: the next run has to replace a locked
        // file and add to a locked folder in its own copy
        try sh("chflags nouchg locked.txt Locked && echo changed > locked.txt && echo n > Locked/new.txt && chflags uchg locked.txt Locked", in: src)
        try dateFolders()
        try mirror()
        let second = try probe()
        #expect(second.isEmpty, "second run: \(second)")
    }

    // The read-back names a copy whose flags or folder dates aren't the library's.
    @Test func theReadBackNamesFlagsAndFolderDates() throws {
        let base = folder("rb")
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        let lib = base.appendingPathComponent("Lib"), copy = base.appendingPathComponent("Copy")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try sh("mkdir Sub && echo h > Sub/h.txt && chflags hidden Sub/h.txt", in: lib)
        let runner = ProcessCommandRunner()
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        try MirrorCopy.sync(lib, into: copy, runner: runner) { c in
            let r = try runner.run(c.tool, c.args)
            try #require(r.ok, "\(c.tool): \(r.stderr)")
        }
        #expect(try MirrorCopy.structure(of: copy, against: lib, previous: nil, control: nil).count == 0)
        try sh("chflags nohidden Sub/h.txt && touch -t 202001010000 Sub", in: copy)
        let found = try MirrorCopy.structure(of: copy, against: lib, previous: nil, control: nil)
        #expect(found.examples.contains { $0.contains("Sub/h.txt") && $0.contains("flags") }, "\(found.examples)")
        #expect(found.examples.contains { $0.hasPrefix("Sub ") && $0.contains("date") }, "\(found.examples)")
    }
}
