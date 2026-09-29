//
//  MirrorFitEdgeTests.swift
//  CryoframeKitTests
//
//  The second round of mirror edges: the band list a seal records against the
//  compact that follows every run, an image from before 1.6 that claims more than
//  its drive can back, read-only files changing between runs and carrying names
//  rsync's filter syntax could misread, and an image left attached with nothing
//  mounted.
//

import Testing
import Foundation
@testable import CryoframeKit

private let hdiutil = "/usr/bin/hdiutil"

/// a fresh folder, named by its real path (see MirrorEdgeTests' edgeDir)
private func fitDir(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-mfit-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

private func randomData(_ n: Int) -> Data {
    var d = Data(count: n)
    d.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, n) }
    return d
}

/// every regular file under `root` by relative path, with its contents.
private func tree(_ root: URL) -> [String: Data] {
    var out: [String: Data] = [:]
    guard let walker = FileManager.default.enumerator(atPath: root.path) else { return out }
    while let rel = walker.nextObject() as? String {
        guard walker.fileAttributes?[.type] as? FileAttributeType == .typeRegular else { continue }
        out[rel] = try? Data(contentsOf: root.appendingPathComponent(rel))
    }
    return out
}

private func mode(_ url: URL) -> mode_t {
    var st = stat()
    return lstat(url.path, &st) == 0 ? st.st_mode & 0o777 : 0
}

private func attach(_ image: URL, at mnt: URL, _ extra: [String] = [], stdin: Data? = nil) throws {
    try FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)
    let r = try DiskImageGate.serialized {
        try ProcessCommandRunner().runRetryingBusy(hdiutil, ["attach", image.path, "-mountpoint", mnt.path, "-nobrowse"] + extra, stdin: stdin)
    }
    try #require(r.ok && MountPoint.isMounted(mnt), "couldn't attach \(image.lastPathComponent): \(r.stderr)")
}

private func lookInside<T>(_ bundle: URL, passphrase: String? = nil, _ body: (URL) throws -> T) throws -> T {
    let mnt = fitDir("look")
    defer { MountPoint.detach(mnt, runner: ProcessCommandRunner()); try? FileManager.default.removeItem(at: mnt) }
    try attach(bundle, at: mnt, ["-readonly"] + (passphrase != nil ? ["-stdinpass"] : []), stdin: passphrase.map { Data($0.utf8) })
    return try body(mnt)
}

private func rootEntries(_ volume: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: volume.path)) ?? []).filter { $0 != ".fseventsd" }.sorted()
}

/// what differs between two trees, by relative path: missing, extra, and changed
private func difference(_ got: [String: Data], _ want: [String: Data]) -> String {
    let missing = Set(want.keys).subtracting(got.keys).sorted(), extra = Set(got.keys).subtracting(want.keys).sorted()
    let changed = Set(got.keys).intersection(want.keys).filter { got[$0] != want[$0] }.sorted()
    return "missing \(missing), extra \(extra), changed \(changed)"
}

/// the devices `hdiutil info` lists for `image`, and whether any has a mount point
private func devices(of image: URL) -> (count: Int, mounted: Bool) {
    guard let r = try? ProcessCommandRunner().run(hdiutil, ["info", "-plist"]), r.ok,
          let data = r.stdout.data(using: .utf8),
          let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let images = root["images"] as? [[String: Any]] else { return (0, false) }
    let target = image.resolvingSymlinksInPath().path
    var count = 0, mounted = false
    for img in images where (img["image-path"] as? String).map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }) == target {
        let entities = img["system-entities"] as? [[String: Any]] ?? []
        count += entities.count
        mounted = mounted || entities.contains { $0["mount-point"] != nil }
    }
    return (count, mounted)
}

/// a scratch drive of `size`, attached the way external drives are (ownership ignored)
private func scratchDrive(_ size: String, in dir: URL) throws -> URL {
    let made = try ProcessCommandRunner().run(hdiutil, ["create", "-size", size, "-fs", "APFS", "-volname", "Drive",
                                                        "-type", "SPARSE", dir.appendingPathComponent("drive").path])
    try #require(made.ok, "\(made.stderr)")
    let mnt = dir.appendingPathComponent("mnt")
    try attach(dir.appendingPathComponent("drive.sparseimage"), at: mnt)
    return mnt
}

@Suite(.serialized) struct MirrorFitEdgeTests {

    // MARK: - the sealed band list against compact

    // Every changing run compacts the image before sealing it, and after the swap the
    // previous copy's blocks are free, so compact deletes bands the last seal
    // recorded. A run that dies between the compact and the seal leaves its mark
    // standing over that band list: a healthy mirror, holding the new copy, must not
    // then read as "part of it is missing; it can't be restored".
    @Test func aRunThatDiesAfterCompactingLeavesAHealthyMirrorRestorable() throws {
        let src = fitDir("cmpsrc").appendingPathComponent("Lib")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        // big enough that the previous copy's bands come free whole (measured: a
        // clone, rewrite, swap and remove of 12 x 12 MB, then compact, deleted 14 of
        // the bands the previous seal had)
        for i in 0..<12 { try randomData(12 << 20).write(to: src.appendingPathComponent("p\(i).raw")) }
        let out = fitDir("compact"), base = fitDir("base"), back = fitDir("back")
        defer {
            chmod(out.path, 0o755)
            for d in [out, base, back, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) }
        }
        _ = try SparseBundleMirrorEngine(sizeGB: 1, mountBase: base).archive(ArchiveSource(name: "Lib", root: src), to: out)
        let sealed = try #require(try ArchiveManifest.read(out.appendingPathComponent(ArchiveManifest.sidecarName)).sealedBands)

        for i in 0..<12 { try randomData(12 << 20).write(to: src.appendingPathComponent("p\(i).raw")) }
        let dies = DiesAfterCompact(lockDir: out)
        #expect(throws: (any Error).self) {
            try SparseBundleMirrorEngine(sizeGB: 1, runner: dies, mountBase: base).archive(ArchiveSource(name: "Lib", root: src), to: out)
        }
        chmod(out.path, 0o755)
        try #require(dies.compacted, "the run never compacted, so this proves nothing")
        try #require(MirrorSeal.isOpen(out), "the run's mark didn't stand, so this proves nothing")
        let bundle = out.appendingPathComponent("Lib.sparsebundle")
        try #require(!MirrorSeal.missingBands(sealed, in: bundle).isEmpty, "compact removed no sealed band, so this proves nothing")

        let check = try ChecksumVerifier().reverify(archiveDir: out)
        #expect(check.passed, "a healthy mirror read as damaged: \(check.details)")
        let archive = try #require(RestoreDiscovery.archive(at: out))
        let restored = try? RestoreEngine().restore(archive, to: back, verify: true)
        #expect(restored.map(tree) == tree(src), "the new copy, complete inside the image, couldn't be restored")
    }

    // MARK: - an image bigger than its drive can back

    // Every mirror made before 1.6 is 500 GB unless changed, on drives far smaller or
    // far fuller. The first run from 1.6 must bring it within what the drive can back
    // (plain or encrypted), and leave the library intact and checkable.
    @Test(arguments: [nil, "correct horse"] as [String?])
    func aMirrorFromBeforeThatClaimsMoreThanItsDriveIsShrunk(_ passphrase: String?) throws {
        let scratch = fitDir("oversize"), base = fitDir("base")
        let src = fitDir("oversrc").appendingPathComponent("Lib")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        for i in 0..<3 { try randomData(3 << 20).write(to: src.appendingPathComponent("p\(i).raw")) }
        let drive = try scratchDrive("400m", in: scratch)
        defer {
            MountPoint.detach(drive, runner: ProcessCommandRunner())
            for d in [scratch, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) }
        }
        let stdin = passphrase.map { Data($0.utf8) }
        let enc = passphrase != nil ? ["-stdinpass"] : []

        // what 1.5.6 made: a fixed-size image (1 GB here, bigger than the drive) and a manifest
        let out = drive.appendingPathComponent("Lib")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let bundle = out.appendingPathComponent("Lib.sparsebundle")
        let made = try ProcessCommandRunner().run(hdiutil, ["create", "-type", "SPARSEBUNDLE", "-fs", "APFS", "-size", "1g", "-volname", "Lib",
                                                            "-imagekey", "sparse-band-size=16384"]
                                                  + (passphrase != nil ? ["-encryption", "AES-256", "-stdinpass"] : []) + [bundle.path], stdin: stdin)
        try #require(made.ok, "\(made.stderr)")
        let mnt = fitDir("old")
        try attach(bundle, at: mnt, ["-owners", "on"] + enc, stdin: stdin)
        let copied = try ProcessCommandRunner().run("/usr/bin/rsync", ["-aE", src.path + "/", mnt.appendingPathComponent("Lib").path + "/"])
        MountPoint.detach(mnt, runner: ProcessCommandRunner())
        try #require(copied.ok, "\(copied.stderr)")
        _ = try ArchiveManifest.write(try ArchiveManifest.build(for: ArchiveResult(artifacts: [bundle], format: .liveMirror),
                                                                encrypted: passphrase != nil), toDir: out)

        try Data("changed".utf8).write(to: src.appendingPathComponent("added.txt"))
        _ = try SparseBundleMirrorEngine(passphrase: passphrase, mountBase: base)
            .archive(ArchiveSource(name: "Lib", root: src, sizeHint: JobExecutor.directorySize(src)), to: out)

        let limits = try ProcessCommandRunner().run(hdiutil, ["resize", "-limits"] + enc + [bundle.path], stdin: stdin)
        let size = try #require(SparseBundleMirrorEngine.currentSectors(limits.stdout), "\(limits.stderr)") * 512
        let held = Checksum.byteSize(of: bundle), free = try #require(JobExecutor.freeSpace(for: out))
        #expect(size <= held + free, "the image still claims \(size >> 20) MB; the drive can back \((held + free) >> 20) MB")
        #expect(try lookInside(bundle, passphrase: passphrase) { tree($0.appendingPathComponent("Lib")) } == tree(src))
        #expect(try ChecksumVerifier().reverify(archiveDir: out).passed)
    }

    // MARK: - read-only files

    // Read-only files go by a pass of their own, named in rsync filter files. Names
    // the filter syntax gives meaning to (a leading "-", "+", "#" or ";", brackets
    // and wildcards, a backslash, a trailing space, a newline) must name only
    // themselves, and a file that turns read-only, turns writable, changes or goes
    // away between runs must end up exactly as it is in the library.
    @Test func readOnlyFilesWithAwkwardNamesFollowTheLibraryBetweenRuns() throws {
        let fm = FileManager.default
        let src = fitDir("rosrc").appendingPathComponent("Lib")
        let names = ["plain.txt", "a b.txt", "-dash.txt", "+ plus.txt", "- minus.txt", "#hash.txt", ";semi.txt",
                     "[x]*?.txt", "trailing space ", "Cafe\u{301}.txt", "new\nline.txt", "deep/er/ro.txt"]
        try fm.createDirectory(at: src.appendingPathComponent("deep/er"), withIntermediateDirectories: true)
        for n in names { try Data("v1 \(n)".utf8).write(to: src.appendingPathComponent(n)) }
        #expect(setxattr(src.appendingPathComponent("a b.txt").path, "com.example.tag", "v1", 2, 0, 0) == 0)
        for n in names { chmod(src.appendingPathComponent(n).path, 0o444) }
        // a writable file whose name the read-only pass must not touch
        try Data("writable".utf8).write(to: src.appendingPathComponent("plain.txt.bak"))
        try Data("w".utf8).write(to: src.appendingPathComponent("turns-readonly.txt"))
        let out = fitDir("ro"), base = fitDir("base")
        defer {
            _ = try? ProcessCommandRunner().run("/bin/chmod", ["-R", "u+w", src.deletingLastPathComponent().path])
            for d in [out, base, src.deletingLastPathComponent()] { try? fm.removeItem(at: d) }
        }
        let engine = SparseBundleMirrorEngine(sizeGB: 1, mountBase: base)
        let bundle = try engine.archive(ArchiveSource(name: "Lib", root: src), to: out).artifacts[0]
        try lookInside(bundle) { vol in
            let got = tree(vol.appendingPathComponent("Lib"))
            #expect(got == tree(src), "\(difference(got, tree(src)))")
        }

        // between runs: one goes away, one turns writable and changes, one writable
        // file turns read-only and changes, one read-only file changes and stays so
        try fm.removeItem(at: src.appendingPathComponent("plain.txt"))
        chmod(src.appendingPathComponent("-dash.txt").path, 0o644)
        try Data("v2 now writable, and longer".utf8).write(to: src.appendingPathComponent("-dash.txt"))
        try Data("v2 read-only now".utf8).write(to: src.appendingPathComponent("turns-readonly.txt"))
        chmod(src.appendingPathComponent("turns-readonly.txt").path, 0o444)
        chmod(src.appendingPathComponent("[x]*?.txt").path, 0o644)
        try Data("v2 changed".utf8).write(to: src.appendingPathComponent("[x]*?.txt"))
        chmod(src.appendingPathComponent("[x]*?.txt").path, 0o444)
        _ = try engine.archive(ArchiveSource(name: "Lib", root: src), to: out)

        try lookInside(bundle) { vol in
            let lib = vol.appendingPathComponent("Lib")
            #expect(rootEntries(vol) == ["Lib"], "left at the image's root: \(rootEntries(vol))")
            #expect(tree(lib) == tree(src), "\(difference(tree(lib), tree(src)))")
            #expect(!fm.fileExists(atPath: lib.appendingPathComponent("plain.txt").path))
            #expect(fm.fileExists(atPath: lib.appendingPathComponent("plain.txt.bak").path))
            #expect(mode(lib.appendingPathComponent("turns-readonly.txt")) == 0o444)
            #expect(mode(lib.appendingPathComponent("-dash.txt")) == 0o644)
            var buf = [UInt8](repeating: 0, count: 8)
            #expect(getxattr(lib.appendingPathComponent("a b.txt").path, "com.example.tag", &buf, 8, 0, 0) == 2)
        }
    }

    // The library can change between the walk that lists read-only files and the two
    // rsync passes: a file turns read-only before the -E pass, or a read-only file is
    // deleted before the -a pass. A run may fail over it, but the copy a restore reads
    // must stay whole, and the next run must put things right.
    @Test(arguments: ["turns read-only before the -E pass", "is deleted before the -a pass"])
    func aLibraryChangingBetweenTheRsyncPassesLeavesAWholeCopy(_ change: String) throws {
        let fm = FileManager.default
        let src = fitDir("racesrc").appendingPathComponent("Lib")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("ro".utf8).write(to: src.appendingPathComponent("ro.txt"))
        chmod(src.appendingPathComponent("ro.txt").path, 0o444)
        try Data("w".utf8).write(to: src.appendingPathComponent("w.txt"))
        let out = fitDir("race"), base = fitDir("base")
        defer {
            _ = try? ProcessCommandRunner().run("/bin/chmod", ["-R", "u+w", src.deletingLastPathComponent().path])
            for d in [out, base, src.deletingLastPathComponent()] { try? fm.removeItem(at: d) }
        }
        let bundle = try SparseBundleMirrorEngine(sizeGB: 1, mountBase: base).archive(ArchiveSource(name: "Lib", root: src), to: out).artifacts[0]
        let before = tree(src)
        try Data("w v2".utf8).write(to: src.appendingPathComponent("w.txt"))

        let racing = ChangesBetweenPasses { pass in
            if change.hasPrefix("turns"), pass == 1 { chmod(src.appendingPathComponent("w.txt").path, 0o444) }
            if change.hasPrefix("is deleted"), pass == 2 { try? fm.removeItem(at: src.appendingPathComponent("ro.txt")) }
        }
        _ = try? SparseBundleMirrorEngine(sizeGB: 1, runner: racing, mountBase: base).archive(ArchiveSource(name: "Lib", root: src), to: out)
        // turning read-only fails the -E pass itself, so there is no second pass then
        try #require(racing.passes >= (change.hasPrefix("turns") ? 1 : 2), "the change never landed, so this proves nothing")
        let inside = try lookInside(bundle) { tree($0.appendingPathComponent("Lib")) }
        #expect(inside == before || inside == tree(src), "\(difference(inside, tree(src)))")

        _ = try SparseBundleMirrorEngine(sizeGB: 1, mountBase: base).archive(ArchiveSource(name: "Lib", root: src), to: out)
        let after = try lookInside(bundle) { tree($0.appendingPathComponent("Lib")) }
        #expect(after == tree(src), "\(difference(after, tree(src)))")
    }

    // A backslash is the one name openrsync's filter won't match literally, escaped
    // or not (measured against every other name above), so a read-only file called
    // that is never left out of the -E pass, and the -E pass fails on it every run.
    @Test func aReadOnlyFileWithABackslashInItsNameIsMirrored() throws {
        let src = fitDir("bssrc").appendingPathComponent("Lib")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: src.appendingPathComponent("back\\slash.txt"))
        chmod(src.appendingPathComponent("back\\slash.txt").path, 0o444)
        let out = fitDir("bs"), base = fitDir("base")
        defer { for d in [out, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        let result = try? SparseBundleMirrorEngine(sizeGB: 1, mountBase: base).archive(ArchiveSource(name: "Lib", root: src), to: out)
        let bundle = try #require(result?.artifacts.first, "the run failed")
        #expect(try lookInside(bundle) { tree($0.appendingPathComponent("Lib")) } == tree(src))
    }

    // A read-only folder holding a read-only file: the -a pass has to create the file
    // inside a folder it has already made read-only, and the previous copy has to be
    // removed after the swap.
    @Test func aReadOnlyFileInAReadOnlyFolderIsMirroredAndTheOldCopyRemoved() throws {
        let src = fitDir("rodsrc").appendingPathComponent("Lib")
        let ro = src.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: ro, withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: ro.appendingPathComponent("ro.txt"))
        chmod(ro.appendingPathComponent("ro.txt").path, 0o444)
        try Data("rw".utf8).write(to: ro.appendingPathComponent("rw.txt"))
        try Data("top".utf8).write(to: src.appendingPathComponent("top.txt"))
        chmod(ro.path, 0o555)
        let out = fitDir("rod"), base = fitDir("base")
        defer {
            chmod(ro.path, 0o755)
            for d in [out, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) }
        }
        let engine = SparseBundleMirrorEngine(sizeGB: 1, mountBase: base)
        let bundle = try engine.archive(ArchiveSource(name: "Lib", root: src), to: out).artifacts[0]
        try Data("top v2".utf8).write(to: src.appendingPathComponent("top.txt"))
        _ = try engine.archive(ArchiveSource(name: "Lib", root: src), to: out)

        try lookInside(bundle) { vol in
            #expect(tree(vol.appendingPathComponent("Lib")) == tree(src))
            #expect(rootEntries(vol) == ["Lib"], "the previous copy was left in the image: \(rootEntries(vol))")
        }
    }

    // MARK: - attached with nothing mounted

    // An image can stay attached with no volume mounted: a failed attach leaves one,
    // and so does unmounting the volume without ejecting the image. `hdiutil info`
    // then lists it with no mount point, so nobody "has it open", yet every attach
    // fails "Resource busy". A reader clears such an orphan after a failed attach; a
    // mirror run has to as well, or the job fails every night until a restart.
    @Test func aMirrorAttachedWithNothingMountedDoesNotBlockItsRuns() throws {
        let src = fitDir("orphsrc").appendingPathComponent("Lib")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: src.appendingPathComponent("one.txt"))
        let out = fitDir("orphan"), base = fitDir("base")
        defer { for d in [out, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        let engine = SparseBundleMirrorEngine(sizeGB: 1, mountBase: base)
        let bundle = try engine.archive(ArchiveSource(name: "Lib", root: src), to: out).artifacts[0]

        let mnt = fitDir("orphmnt")
        try attach(bundle, at: mnt, ["-readonly"])
        defer {
            ArchiveReader.detachOrphans(ofImage: bundle, runner: ProcessCommandRunner())
            MountPoint.detach(mnt, runner: ProcessCommandRunner())
            try? FileManager.default.removeItem(at: mnt)
        }
        let unmounted = try ProcessCommandRunner().run("/usr/sbin/diskutil", ["unmount", mnt.path])
        try #require(unmounted.ok && !MountPoint.isMounted(mnt), "\(unmounted.stderr)")
        let left = devices(of: bundle)
        try #require(left.count > 0 && !left.mounted, "the image went with its volume, so this proves nothing")

        try Data("two".utf8).write(to: src.appendingPathComponent("two.txt"))
        #expect(throws: Never.self) { try engine.archive(ArchiveSource(name: "Lib", root: src), to: out) }
    }

    // The same orphan in the way of a restore: the reader's clean-up after a failed
    // attach should take it away and the retry should open the mirror.
    @Test func aRestoreOpensAMirrorAttachedWithNothingMounted() throws {
        let src = fitDir("orphrsrc").appendingPathComponent("Lib")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: src.appendingPathComponent("one.txt"))
        let out = fitDir("orphr"), base = fitDir("base")
        defer { for d in [out, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        let result = try SparseBundleMirrorEngine(sizeGB: 1, mountBase: base).archive(ArchiveSource(name: "Lib", root: src), to: out)
        let bundle = result.artifacts[0]

        let mnt = fitDir("orphrmnt")
        try attach(bundle, at: mnt, ["-readonly"])
        defer {
            ArchiveReader.detachOrphans(ofImage: bundle, runner: ProcessCommandRunner())
            MountPoint.detach(mnt, runner: ProcessCommandRunner())
            try? FileManager.default.removeItem(at: mnt)
        }
        let unmounted = try ProcessCommandRunner().run("/usr/sbin/diskutil", ["unmount", mnt.path])
        try #require(unmounted.ok && !MountPoint.isMounted(mnt), "\(unmounted.stderr)")

        let opened = try? ArchiveReader(workBase: base, transientSettle: 0.1).open(result)
        defer { opened?.close() }
        #expect(opened.map { FileManager.default.fileExists(atPath: $0.root.appendingPathComponent("Lib/one.txt").path) } == true)
    }
}

/// compacts as a run does, then makes the manifest unwritable: as if the run died
/// between the compact and the seal.
private final class DiesAfterCompact: CommandRunner, @unchecked Sendable {
    let inner = ProcessCommandRunner()
    let lockDir: URL
    private(set) var compacted = false
    init(lockDir: URL) { self.lockDir = lockDir }
    var forTeardown: CommandRunner { self }
    func run(_ launchPath: String, _ args: [String], stdin: Data?) throws -> CommandResult {
        let r = try inner.run(launchPath, args, stdin: stdin)
        if (launchPath as NSString).lastPathComponent == "hdiutil", args.first == "compact" {
            compacted = true
            chmod(lockDir.path, 0o555)
        }
        return r
    }
}

/// calls `before(n)` ahead of the n-th rsync a run starts
private final class ChangesBetweenPasses: CommandRunner, @unchecked Sendable {
    let inner = ProcessCommandRunner()
    let before: (Int) -> Void
    private(set) var passes = 0
    init(before: @escaping (Int) -> Void) { self.before = before }
    var forTeardown: CommandRunner { inner }
    func run(_ launchPath: String, _ args: [String], stdin: Data?) throws -> CommandResult {
        if (launchPath as NSString).lastPathComponent == "rsync" { passes += 1; before(passes) }
        return try inner.run(launchPath, args, stdin: stdin)
    }
}
