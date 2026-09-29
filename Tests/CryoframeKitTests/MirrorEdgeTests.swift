//
//  MirrorEdgeTests.swift
//  CryoframeKitTests
//
//  The live mirror at its edges: runs that fail before they touch the image after
//  one that crashed, readers and runs opening the same image at once, a drive that
//  fills in the middle of a run, and libraries whose contents or names are unusual.
//

import Testing
import Foundation
@testable import CryoframeKit

private let hdiutil = "/usr/bin/hdiutil"

/// a fresh folder, named by its real path. The temp folder is under /var, a symlink,
/// and a mirror found by RestoreDiscovery.scan through one fails its checksum (see
/// aMirrorReachedThroughASymlinkChecksOutWhereverItIsFound); these tests are about
/// other things. (resolvingSymlinksInPath would strip /private again.)
private func edgeDir(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-medge-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

/// a library folder called `name` with `n` small files, half in a subfolder.
private func library(_ name: String = "Lib", files n: Int) throws -> URL {
    let lib = edgeDir("lib").appendingPathComponent(name)
    try FileManager.default.createDirectory(at: lib.appendingPathComponent("sub"), withIntermediateDirectories: true)
    for i in 0..<n { try Data("v1 file \(i)".utf8).write(to: lib.appendingPathComponent(i % 2 == 0 ? "f\(i).txt" : "sub/f\(i).txt")) }
    return lib
}

private func randomData(_ n: Int) -> Data {
    var d = Data(count: n)
    d.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, n) }
    return d
}

/// every regular file under `root` by relative path, with its contents.
private func tree(_ root: URL) -> [String: Data] {
    var out: [String: Data] = [:]
    let base = root.resolvingSymlinksInPath().path
    let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
    while let u = walker?.nextObject() as? URL {
        guard (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
        out[String(u.resolvingSymlinksInPath().path.dropFirst(base.count))] = try? Data(contentsOf: u)
    }
    return out
}

private func attach(_ image: URL, at mnt: URL, _ extra: [String] = [], stdin: Data? = nil) throws {
    try FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)
    let r = try DiskImageGate.serialized {
        try ProcessCommandRunner().runRetryingBusy(hdiutil, ["attach", image.path, "-mountpoint", mnt.path, "-nobrowse"] + extra, stdin: stdin)
    }
    try #require(r.ok && MountPoint.isMounted(mnt), "couldn't attach \(image.lastPathComponent): \(r.stderr)")
}

/// look inside a mirror read-only: `body` gets the volume root.
private func lookInside<T>(_ bundle: URL, _ body: (URL) throws -> T) throws -> T {
    let mnt = edgeDir("look")
    defer { MountPoint.detach(mnt, runner: ProcessCommandRunner()); try? FileManager.default.removeItem(at: mnt) }
    try attach(bundle, at: mnt, ["-readonly"])
    return try body(mnt)
}

private func rootEntries(_ volume: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: volume.path)) ?? []).filter { $0 != ".fseventsd" }.sorted()
}

/// what a run that crashed mid-update leaves: the mirror marked open, and the image
/// changed since its manifest was written (a half-written staging copy).
private func leaveAsACrashedRunWould(_ out: URL, bundle: URL) throws {
    try MirrorSeal.markOpen(out)
    let mnt = edgeDir("crashed")
    defer { MountPoint.detach(mnt, runner: ProcessCommandRunner()); try? FileManager.default.removeItem(at: mnt) }
    try attach(bundle, at: mnt)
    let staging = mnt.appendingPathComponent("\(MirrorCopy.stagingName)/Lib")
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    for i in 0..<40 { try randomData(64 * 1024).write(to: staging.appendingPathComponent("half\(i).bin")) }
}

private var deadOwner: ProcessIdentity {
    let me = ProcessIdentity.current!
    return ProcessIdentity(pid: me.pid, startedAt: me.startedAt - 1)      // same pid, earlier life
}

@Suite(.serialized) struct MirrorEdgeTests {

    // MARK: - the open marker

    // A crashed run leaves the mirror marked open over a manifest that no longer
    // matches. If the next run is refused before it touches the image (here: the
    // drive can't hold the library), it must not clear a mark it didn't make, or the
    // intact previous copy is refused again as "checksum mismatch".
    @Test func aRunRefusedAfterACrashKeepsTheMirrorMarkedOpen() throws {
        let src = try library(files: 10)
        let out = edgeDir("refused"), base = edgeDir("base"), back = edgeDir("back")
        defer { for d in [out, base, back, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        let bundle = try SparseBundleMirrorEngine(sizeGB: 1, mountBase: base)
            .archive(ArchiveSource(name: "Lib", root: src), to: out).artifacts[0]
        let before = tree(src)
        try leaveAsACrashedRunWould(out, bundle: bundle)
        try #require(try ChecksumVerifier().reverify(archiveDir: out).passed, "the crashed mirror should read as not compared")

        #expect(throws: MirrorSpaceError.self) {
            try SparseBundleMirrorEngine(sizeGB: 1, mountBase: base)
                .archive(ArchiveSource(name: "Lib", root: src, sizeHint: 1 << 50), to: out)
        }
        #expect(MirrorSeal.isOpen(out), "a run that never touched the image cleared the crashed run's mark")
        let check = try ChecksumVerifier().reverify(archiveDir: out)
        #expect(check.passed, "\(check.details)")
        let archive = try #require(RestoreDiscovery.archive(at: out))
        let restored = try? RestoreEngine().restore(archive, to: back, verify: true)
        #expect(restored.map(tree) == before, "the intact previous copy could not be restored")
    }

    // The likeliest way in: after a crash the user opens the mirror in the restore
    // window to see what survived, and the scheduled run fires while it's open.
    @Test func aRunThatFindsTheMirrorOpenAfterACrashKeepsItMarkedOpen() throws {
        let src = try library(files: 10)
        let out = edgeDir("browsing"), base = edgeDir("base"), back = edgeDir("back")
        defer { for d in [out, base, back, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        let result = try SparseBundleMirrorEngine(sizeGB: 1, mountBase: base).archive(ArchiveSource(name: "Lib", root: src), to: out)
        let before = tree(src)
        try leaveAsACrashedRunWould(out, bundle: result.artifacts[0])

        let browsing = try ArchiveReader(workBase: base).open(result)
        #expect(throws: (any Error).self) {
            try SparseBundleMirrorEngine(sizeGB: 1, mountBase: base).archive(ArchiveSource(name: "Lib", root: src), to: out)
        }
        browsing.close()
        #expect(MirrorSeal.isOpen(out), "a run that couldn't attach cleared the crashed run's mark")
        let archive = try #require(RestoreDiscovery.archive(at: out))
        let restored = try? RestoreEngine().restore(archive, to: back, verify: true)
        #expect(restored.map(tree) == before, "the intact previous copy could not be restored")
    }

    // Two runs on one image (two jobs mirroring the same library to the same folder,
    // set up before that was refused, or from two Macs sharing a drive). The one that
    // can't attach must not clear the mark of the one still writing.
    @Test func aSecondRunOnTheSameImageLeavesTheFirstMarkedOpen() throws {
        let src = try library(files: 10)
        let out = edgeDir("two"), base = edgeDir("base")
        defer { for d in [out, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        _ = try SparseBundleMirrorEngine(sizeGB: 1, mountBase: base).archive(ArchiveSource(name: "Lib", root: src), to: out)
        try Data("changed".utf8).write(to: src.appendingPathComponent("f0.txt"))

        let second = SecondRunDuringRsync(out: out, source: ArchiveSource(name: "Lib", root: src), base: base)
        _ = try SparseBundleMirrorEngine(sizeGB: 1, runner: second, mountBase: base)
            .archive(ArchiveSource(name: "Lib", root: src), to: out)
        #expect(second.secondFailed == true)
        #expect(second.markedOpenWhileFirstWrote == true, "the mirror read as sealed while a run was rewriting it")
    }

    // A mark left forever hides real damage: while it stands, nothing compares the
    // checksum. A band lost from the image after a crash must not restore quietly as
    // a library with holes in it.
    @Test func aDamagedMirrorUnderACrashMarkIsNotRestoredQuietly() throws {
        let src = edgeDir("dmgsrc").appendingPathComponent("Lib")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        for i in 0..<4 { try randomData(6 << 20).write(to: src.appendingPathComponent("photo\(i).raw")) }
        let out = edgeDir("damaged"), base = edgeDir("base"), back = edgeDir("back")
        defer { for d in [out, base, back, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        let bundle = try SparseBundleMirrorEngine(sizeGB: 1, mountBase: base)
            .archive(ArchiveSource(name: "Lib", root: src), to: out).artifacts[0]
        let before = tree(src)
        try leaveAsACrashedRunWould(out, bundle: bundle)

        // the largest band holds library data; lose it, as a failing drive would
        // (not band 0: that holds the partition map, and losing it fails loudly anyway)
        let bands = try FileManager.default.contentsOfDirectory(at: bundle.appendingPathComponent("bands"),
                                                                 includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.lastPathComponent != "0" }
        let size = { (u: URL) in (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0 }
        let biggest = try #require(bands.max { size($0) < size($1) })
        try FileManager.default.removeItem(at: biggest)

        let archive = try #require(RestoreDiscovery.archive(at: out))
        if let restored = try? RestoreEngine().restore(archive, to: back, verify: true) {
            #expect(tree(restored) == before, "a damaged mirror restored without complaint, and the restored library is not the one backed up")
        }
    }

    // MARK: - readers and runs sharing an image

    // A second attach of an image already attached fails "Resource busy" (measured on
    // macOS 26). A failed open then force-detaches every device of that image, and
    // the first reader's mount is one of them.
    @Test func aFailedOpenLeavesAnotherReadersMountAlone() throws {
        let src = try library(files: 6)
        let out = edgeDir("readers"), base = edgeDir("base")
        defer { for d in [out, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        let result = try SparseBundleMirrorEngine(sizeGB: 1, mountBase: base).archive(ArchiveSource(name: "Lib", root: src), to: out)

        let first = try ArchiveReader(workBase: base).open(result)
        defer { first.close() }
        let second = try? ArchiveReader(workBase: base, transientSettle: 0.1).open(result)
        defer { second?.close() }
        #expect(MountPoint.isMounted(first.root), "opening the mirror again detached the first reader's mount")
        #expect(FileManager.default.fileExists(atPath: first.root.appendingPathComponent("Lib/f0.txt").path))
    }

    // The same, against a run: a drill or restore that opens the mirror while its job
    // is copying into it detaches the run's image in the middle of rsync. The copy a
    // restore reads must survive either way.
    @Test func aDrillDuringAMirrorRunLeavesTheRunsImageAttached() throws {
        let src = try library(files: 10)
        let out = edgeDir("drillrun"), base = edgeDir("base")
        defer { for d in [out, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        let result = try SparseBundleMirrorEngine(sizeGB: 1, mountBase: base).archive(ArchiveSource(name: "Lib", root: src), to: out)
        let before = tree(src)
        try Data("changed".utf8).write(to: src.appendingPathComponent("f0.txt"))

        let drill = DrillDuringRsync(mirror: result, base: base)
        _ = try? SparseBundleMirrorEngine(sizeGB: 1, runner: drill, mountBase: base)
            .archive(ArchiveSource(name: "Lib", root: src), to: out)
        #expect(drill.runStillMounted == true, "a drill detached the image a mirror run was copying into")
        let inside = try lookInside(result.artifacts[0]) { tree($0.appendingPathComponent("Lib")) }
        #expect(inside == before || inside == tree(src), "the copy a restore reads is neither the old nor the new library")
    }

    // A reader that died with the mirror open (the agent killed during a drill) left
    // it attached at a cf-open- folder. Only the app's launch sweep releases those;
    // the scheduled agent never sweeps, so the job fails every night until the app
    // is opened.
    @Test func aMirrorADeadReaderLeftAttachedDoesNotBlockTheRun() throws {
        let src = try library(files: 6)
        let out = edgeDir("deadreader"), base = edgeDir("base")
        defer { for d in [out, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        let engine = SparseBundleMirrorEngine(sizeGB: 1, mountBase: base)
        let bundle = try engine.archive(ArchiveSource(name: "Lib", root: src), to: out).artifacts[0]

        let work = base.appendingPathComponent("cf-open-\(UUID().uuidString)")
        let mnt = work.appendingPathComponent("mnt")
        try FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)
        try JSONEncoder().encode(deadOwner).write(to: work.appendingPathComponent(OpenedArchive.ownerFileName))
        try attach(bundle, at: mnt, ["-readonly"])
        defer { MountPoint.detach(mnt, runner: ProcessCommandRunner()) }

        try Data("added".utf8).write(to: src.appendingPathComponent("added.txt"))
        #expect(throws: Never.self) { try engine.archive(ArchiveSource(name: "Lib", root: src), to: out) }
    }

    // Before 1.6 a run attached inside the destination. One that crashed there left
    // the image attached; the first 1.6 run detaches it and carries on.
    @Test func aLegacyMountInsideTheDestinationIsClearedAndTheRunCarriesOn() throws {
        let src = try library(files: 6)
        let out = edgeDir("legacy"), base = edgeDir("base")
        defer { for d in [out, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        let engine = SparseBundleMirrorEngine(sizeGB: 1, mountBase: base)
        let bundle = try engine.archive(ArchiveSource(name: "Lib", root: src), to: out).artifacts[0]
        let legacy = out.appendingPathComponent(".Lib.mirror-mnt")
        try attach(bundle, at: legacy)
        defer { MountPoint.detach(legacy, runner: ProcessCommandRunner()) }

        try Data("added".utf8).write(to: src.appendingPathComponent("added.txt"))
        _ = try engine.archive(ArchiveSource(name: "Lib", root: src), to: out)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(try lookInside(bundle) { tree($0.appendingPathComponent("Lib")) } == tree(src))
    }

    // MARK: - what staging has to cope with

    // Whatever a crash left in staging: files half-written or since deleted from the
    // library, a folder carrying the deny-delete ACL rsync -E copies from home folders
    // with a stray file inside it, and a stray folder beside the library copy.
    @Test func aLeftoverStagingFullOfJunkIsReplacedByAnExactCopy() throws {
        let src = try library(files: 10)
        let out = edgeDir("junk"), base = edgeDir("base")
        defer { for d in [out, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        let engine = SparseBundleMirrorEngine(sizeGB: 1, mountBase: base)
        let bundle = try engine.archive(ArchiveSource(name: "Lib", root: src), to: out).artifacts[0]

        let mnt = edgeDir("junkmnt")
        try attach(bundle, at: mnt)
        let staging = mnt.appendingPathComponent(MirrorCopy.stagingName)
        let next = staging.appendingPathComponent("Lib")
        try FileManager.default.createDirectory(at: next.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("stray"), withIntermediateDirectories: true)
        try Data("junk".utf8).write(to: next.appendingPathComponent("junk.txt"))
        try Data("junk".utf8).write(to: next.appendingPathComponent("sub/stray.txt"))
        try Data("wrong".utf8).write(to: next.appendingPathComponent("sub/f1.txt"))
        try Data("v1 fi".utf8).write(to: next.appendingPathComponent("f2.txt"))          // cut short
        _ = try ProcessCommandRunner().run("/bin/chmod", ["+a", "everyone deny delete", next.appendingPathComponent("sub").path])
        MountPoint.detach(mnt, runner: ProcessCommandRunner())
        try? FileManager.default.removeItem(at: mnt)

        _ = try engine.archive(ArchiveSource(name: "Lib", root: src), to: out)
        let (library, root) = try lookInside(bundle) { (tree($0.appendingPathComponent("Lib")), rootEntries($0)) }
        #expect(library == tree(src))
        #expect(root == ["Lib"], "left at the image's root: \(root)")
    }

    // Read-only files are everywhere: every git repository keeps its objects 0444.
    // openrsync with -E (since 1.5.1) fails on each one, "openat: Permission denied",
    // so a mirror of any folder holding one never completes. The old copy has to be
    // removed after the swap too, or the image keeps two copies from then on.
    @Test func aLibraryHoldingReadOnlyFilesIsMirrored() throws {
        let src = try library(files: 6)
        let objects = src.appendingPathComponent("project/.git/objects/ab")
        try FileManager.default.createDirectory(at: objects, withIntermediateDirectories: true)
        try Data("blob".utf8).write(to: objects.appendingPathComponent("cdef0123"))
        chmod(objects.appendingPathComponent("cdef0123").path, 0o444)
        let out = edgeDir("ro"), base = edgeDir("base")
        defer { for d in [out, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        let engine = SparseBundleMirrorEngine(sizeGB: 1, mountBase: base)
        let bundle = try engine.archive(ArchiveSource(name: "Lib", root: src), to: out).artifacts[0]
        try Data("changed".utf8).write(to: src.appendingPathComponent("f0.txt"))
        _ = try engine.archive(ArchiveSource(name: "Lib", root: src), to: out)

        let (library, root) = try lookInside(bundle) { (tree($0.appendingPathComponent("Lib")), rootEntries($0)) }
        #expect(library == tree(src))
        #expect(root == ["Lib"], "the previous copy was left in the image: \(root)")
    }

    // Symlinks (relative, absolute, dangling), a resource fork, an extended attribute,
    // a nested folder that denies delete and a locked file, through a run that goes
    // the whole way: clone, rsync, swap, remove the old copy.
    @Test func linksAttributesAndForksComeThroughTheCloneAndSwap() throws {
        let src = try library(files: 4)
        let fm = FileManager.default
        try Data("body".utf8).write(to: src.appendingPathComponent("tagged.txt"))
        #expect(setxattr(src.appendingPathComponent("tagged.txt").path, "com.example.tag", "v1", 2, 0, 0) == 0)
        #expect(setxattr(src.appendingPathComponent("tagged.txt").path, "com.apple.ResourceFork", "FORKDATA", 8, 0, 0) == 0)
        try fm.createSymbolicLink(atPath: src.appendingPathComponent("rel").path, withDestinationPath: "tagged.txt")
        try fm.createSymbolicLink(atPath: src.appendingPathComponent("abs").path, withDestinationPath: "/etc/hosts")
        try fm.createSymbolicLink(atPath: src.appendingPathComponent("dangling").path, withDestinationPath: "nowhere/at/all")
        let deny = src.appendingPathComponent("deny")
        try fm.createDirectory(at: deny, withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: deny.appendingPathComponent("k.txt"))
        _ = try ProcessCommandRunner().run("/bin/chmod", ["+a", "everyone deny delete", deny.path])
        try Data("locked".utf8).write(to: src.appendingPathComponent("locked.txt"))
        #expect(chflags(src.appendingPathComponent("locked.txt").path, UInt32(UF_IMMUTABLE)) == 0)
        let out = edgeDir("attrs"), base = edgeDir("base")
        defer {
            _ = chflags(src.appendingPathComponent("locked.txt").path, 0)
            _ = try? ProcessCommandRunner().run("/bin/chmod", ["-R", "-N", src.path])
            for d in [out, base, src.deletingLastPathComponent()] { try? fm.removeItem(at: d) }
        }
        let engine = SparseBundleMirrorEngine(sizeGB: 1, mountBase: base)
        let bundle = try engine.archive(ArchiveSource(name: "Lib", root: src), to: out).artifacts[0]
        try Data("changed".utf8).write(to: src.appendingPathComponent("f0.txt"))
        _ = try engine.archive(ArchiveSource(name: "Lib", root: src), to: out)

        try lookInside(bundle) { vol in
            let lib = vol.appendingPathComponent("Lib")
            #expect(rootEntries(vol) == ["Lib"], "left at the image's root: \(rootEntries(vol))")
            #expect(tree(lib) == tree(src))
            #expect((try? fm.destinationOfSymbolicLink(atPath: lib.appendingPathComponent("rel").path)) == "tagged.txt")
            #expect((try? fm.destinationOfSymbolicLink(atPath: lib.appendingPathComponent("abs").path)) == "/etc/hosts")
            #expect((try? fm.destinationOfSymbolicLink(atPath: lib.appendingPathComponent("dangling").path)) == "nowhere/at/all")
            var buf = [UInt8](repeating: 0, count: 64)
            let tag = getxattr(lib.appendingPathComponent("tagged.txt").path, "com.example.tag", &buf, 64, 0, 0)
            #expect(tag == 2 && String(decoding: buf.prefix(2), as: UTF8.self) == "v1")
            let fork = getxattr(lib.appendingPathComponent("tagged.txt").path, "com.apple.ResourceFork", &buf, 64, 0, 0)
            #expect(fork == 8 && String(decoding: buf.prefix(8), as: UTF8.self) == "FORKDATA")
            let ls = try ProcessCommandRunner().run("/bin/ls", ["-led", lib.appendingPathComponent("deny").path])
            #expect(ls.stdout.contains("deny delete"), "the nested folder lost its ACL:\n\(ls.stdout)")
        }
    }

    // MARK: - names

    // What a restore looks for is <volume>/<bundle name>, and a drill looks at
    // <volume>/<artifact name less .sparsebundle>. The two have to agree for any name.
    @Test(arguments: ["Mom’s Photos — 2024 (copy)", "Cafe\u{301} Ünïcödé", "-rf", "a:b", "Thesis.part.2", "My.Stuff"])
    func aLibraryWithAnOddNameMirrorsAndRestores(_ name: String) throws {
        let src = try library(name, files: 6)
        let out = edgeDir("name").appendingPathComponent(name), base = edgeDir("base"), back = edgeDir("back")
        defer { for d in [out.deletingLastPathComponent(), base, back, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        let engine = SparseBundleMirrorEngine(sizeGB: 1, mountBase: base)
        _ = try engine.archive(ArchiveSource(name: name, root: src), to: out)
        try Data("changed".utf8).write(to: src.appendingPathComponent("f0.txt"))
        let result = try engine.archive(ArchiveSource(name: name, root: src), to: out)

        let type = ContentType.genericFolder(id: "l", displayName: name, path: .home(name))
        let drill = try StrongVerifier().verify(result, type: type)
        #expect(drill.passed && drill.details.contains("6 file(s)"), "\(drill.details)")
        let rehearsal = RecoveryRehearsal().rehearse(destination: out.deletingLastPathComponent(), expecting: [name])
        #expect(rehearsal.passed, "\(rehearsal.outcomes.map(\.detail))")
        let archive = try #require(RestoreDiscovery.archive(at: out))
        let restored = try? RestoreEngine().restore(archive, to: back, verify: true)
        #expect(restored.map(tree) == tree(src), "\(name) mirrored, and a drill and a rehearsal passed, but it didn't restore")
    }

    // A job's destination reached through a symlink (a folder in the home folder
    // pointing at an external drive, say). The run writes the manifest using that
    // path; the restore window, recovery wizard, health check, drill and rehearsal
    // all find the mirror with RestoreDiscovery.scan, which hands back the resolved
    // path. The directory checksum takes each file's path relative to the one it
    // was given, and when the spellings differ it falls back to bare file names, so
    // the same bundle hashes two ways.
    @Test func aMirrorReachedThroughASymlinkChecksOutWhereverItIsFound() throws {
        let src = try library(files: 6)
        let real = edgeDir("real"), links = edgeDir("links"), base = edgeDir("base"), back = edgeDir("back")
        defer { for d in [real, links, base, back, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        let drive = links.appendingPathComponent("Drive")
        try FileManager.default.createSymbolicLink(at: drive, withDestinationURL: real)
        let dest = drive.appendingPathComponent("Backups")
        _ = try SparseBundleMirrorEngine(sizeGB: 1, mountBase: base).archive(ArchiveSource(name: "Lib", root: src), to: dest.appendingPathComponent("Lib"))

        let found = RestoreDiscovery.scan(dest)
        let archive = try #require(found.first)
        let manifest = try ArchiveManifest.read(archive.dir.appendingPathComponent(ArchiveManifest.sidecarName))
        let check = try ChecksumVerifier().verify(manifest, in: archive.dir)
        #expect(check.passed, "a good mirror, found where the restore window finds it: \(check.details)")
        let restored = try? RestoreEngine().restore(archive, to: back, verify: true)
        #expect(restored.map(tree) == tree(src))
    }

    // MARK: - space and size

    // The margin is 5% of the library, at most 1 GiB, and a fixed image smaller than
    // library plus margin is refused.
    @Test func theSpaceCheckAddsFivePercentAtMostAGibibyte() throws {
        let image = edgeDir("img"), dest = edgeDir("dest")
        defer { for d in [image, dest] { try? FileManager.default.removeItem(at: d) } }
        let small: UInt64 = 100 << 20, big: UInt64 = 40 << 30
        #expect(throws: Never.self) {
            try SparseBundleMirrorEngine.checkRoom(for: small, image: image, imageBytes: small + small / 20, destination: dest)
        }
        #expect(throws: MirrorSpaceError.imageTooSmall(size: small + small / 20 - 1, needed: small + small / 20)) {
            try SparseBundleMirrorEngine.checkRoom(for: small, image: image, imageBytes: small + small / 20 - 1, destination: dest)
        }
        #expect(throws: MirrorSpaceError.imageTooSmall(size: big, needed: big + (1 << 30))) {
            try SparseBundleMirrorEngine.checkRoom(for: big, image: image, imageBytes: big, destination: dest)
        }
        // The boot volume's free space moves while other tests run (438 KB between two
        // reads was seen), so what is reported as free is only compared roughly. What is
        // needed follows from the library alone and is exact.
        let free = try #require(JobExecutor.freeSpace(for: dest))
        #expect {
            try SparseBundleMirrorEngine.checkRoom(for: free + 1, image: image, imageBytes: .max, destination: dest)
        } throws: { error in
            guard case .notEnoughRoom(let needed, let reported)? = error as? MirrorSpaceError else { return false }
            return needed == free + 1 + (1 << 30) && max(reported, free) - min(reported, free) < 1 << 30
        }
    }

    // Files rewritten in place need room the space check can't see: the old copy
    // holds its blocks until the swap, so a run needs the library plus everything
    // changed. (The same rewrite on the same drive, rsynced in place as before 1.6,
    // fits with room to spare: measured 233 of 399 MB used.) A drive that fills in the
    // middle of a run must fail it and leave a whole library to restore, and once the
    // library is smaller again the next run must finish, not trip over the staging
    // copy the failed run left filling the drive.
    @Test func aDriveThatFillsMidRunLeavesThePreviousCopyRestorable() throws {
        let scratch = edgeDir("fill"), base = edgeDir("base"), back = edgeDir("back")
        let src = edgeDir("fillsrc").appendingPathComponent("Lib")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        for i in 0..<16 { try randomData(12 << 20).write(to: src.appendingPathComponent("p\(i).raw")) }
        let made = try ProcessCommandRunner().run(hdiutil, ["create", "-size", "400m", "-fs", "APFS", "-volname", "Small",
                                                            "-type", "SPARSE", scratch.appendingPathComponent("drive").path])
        try #require(made.ok, "\(made.stderr)")
        let drive = scratch.appendingPathComponent("mnt")
        try attach(scratch.appendingPathComponent("drive.sparseimage"), at: drive)
        defer {
            MountPoint.detach(drive, runner: ProcessCommandRunner())
            for d in [scratch, base, back, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) }
        }
        let out = drive.appendingPathComponent("Lib")
        let engine = SparseBundleMirrorEngine(mountBase: base)
        _ = try engine.archive(ArchiveSource(name: "Lib", root: src, sizeHint: JobExecutor.directorySize(src)), to: out)
        let before = tree(src)

        for i in 0..<16 { try randomData(12 << 20).write(to: src.appendingPathComponent("p\(i).raw")) }
        var failure: Error?
        do {
            _ = try engine.archive(ArchiveSource(name: "Lib", root: src, sizeHint: JobExecutor.directorySize(src)), to: out)
        } catch { failure = error }
        try #require(failure != nil, "the rewrite fit after all, so this proves nothing")
        #expect(!(failure is MirrorSpaceError), "refused up front, so this proves nothing about a drive filling mid-run")

        let archive = try #require(RestoreDiscovery.archive(at: out))
        var restored: URL?, why = ""
        do { restored = try RestoreEngine().restore(archive, to: back, verify: true) } catch { why = "\(error)" }
        let got = restored.map(tree)
        let differing = got.map { g in Set(g.keys).union(tree(src).keys).filter { g[$0] != tree(src)[$0] }.sorted() } ?? []
        #expect(got == before || got == tree(src),
                "restored a library that is neither the old copy nor the new one (differs from the new in \(differing)). After the drive filled (\(String(describing: failure))), the previous copy didn't restore: \(why); still marked open: \(MirrorSeal.isOpen(out)); attached at \(MirrorMounts.mountPoints(of: archive.archiveResult().artifacts[0], runner: ProcessCommandRunner()))")

        for i in 8..<16 { try FileManager.default.removeItem(at: src.appendingPathComponent("p\(i).raw")) }
        #expect(throws: Never.self) {
            try engine.archive(ArchiveSource(name: "Lib", root: src, sizeHint: JobExecutor.directorySize(src)), to: out)
        }
    }

    // An encrypted mirror: `resize -limits` and `resize` both need the passphrase.
    @Test func anEncryptedMirrorIsGrownAndChecked() throws {
        let src = try library(files: 4)
        let out = edgeDir("enc"), base = edgeDir("base")
        defer { for d in [out, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        let pass = "correct horse"
        let bundle = try SparseBundleMirrorEngine(sizeGB: 1, passphrase: pass, mountBase: base)
            .archive(ArchiveSource(name: "Lib", root: src), to: out).artifacts[0]

        #expect(throws: MirrorSpaceError.self) {
            try SparseBundleMirrorEngine(sizeGB: 2, passphrase: pass, mountBase: base)
                .archive(ArchiveSource(name: "Lib", root: src, sizeHint: 1 << 50), to: out)
        }
        #expect(!MirrorSeal.isOpen(out))
        _ = try SparseBundleMirrorEngine(sizeGB: 2, passphrase: pass, mountBase: base)
            .archive(ArchiveSource(name: "Lib", root: src, sizeHint: JobExecutor.directorySize(src)), to: out)
        let limits = try ProcessCommandRunner().run(hdiutil, ["resize", "-limits", "-stdinpass", bundle.path], stdin: Data(pass.utf8))
        let sectors = try #require(SparseBundleMirrorEngine.currentSectors(limits.stdout), "\(limits.stderr)")
        #expect(sectors * 512 >= UInt64(2 << 30) * 99 / 100, "the encrypted mirror wasn't grown: \(sectors) sectors")
        #expect(try ChecksumVerifier().reverify(archiveDir: out).passed)

        // the wrong passphrase: refused, and the mirror still checks out
        #expect(throws: (any Error).self) {
            try SparseBundleMirrorEngine(sizeGB: 2, passphrase: "wrong", mountBase: base).archive(ArchiveSource(name: "Lib", root: src), to: out)
        }
        #expect(try ChecksumVerifier().reverify(archiveDir: out).passed)
    }
}

// MARK: - runners

/// runs a second mirror run of the same image while the first is in its rsync.
private final class SecondRunDuringRsync: CommandRunner, @unchecked Sendable {
    let inner = ProcessCommandRunner()
    let out: URL, source: ArchiveSource, base: URL
    private(set) var secondFailed: Bool?
    private(set) var markedOpenWhileFirstWrote: Bool?
    init(out: URL, source: ArchiveSource, base: URL) { self.out = out; self.source = source; self.base = base }
    var forTeardown: CommandRunner { inner }
    func run(_ launchPath: String, _ args: [String], stdin: Data?) throws -> CommandResult {
        if (launchPath as NSString).lastPathComponent == "rsync", secondFailed == nil {
            secondFailed = (try? SparseBundleMirrorEngine(sizeGB: 1, mountBase: base).archive(source, to: out)) == nil
            markedOpenWhileFirstWrote = MirrorSeal.isOpen(out)
        }
        return try inner.run(launchPath, args, stdin: stdin)
    }
}

/// opens the mirror the way a drill does while the run's rsync is about to start,
/// and notes whether the run's own attach survived it.
private final class DrillDuringRsync: CommandRunner, @unchecked Sendable {
    let inner = ProcessCommandRunner()
    let mirror: ArchiveResult, base: URL
    private(set) var runStillMounted: Bool?
    init(mirror: ArchiveResult, base: URL) { self.mirror = mirror; self.base = base }
    var forTeardown: CommandRunner { inner }
    func run(_ launchPath: String, _ args: [String], stdin: Data?) throws -> CommandResult {
        if (launchPath as NSString).lastPathComponent == "rsync", runStillMounted == nil, let dest = args.last {
            // dest is <mount>/.cryoframe-staging/<name>/
            let volume = URL(fileURLWithPath: dest).deletingLastPathComponent().deletingLastPathComponent()
            let opened = try? ArchiveReader(runner: inner, workBase: base, transientSettle: 0.1).open(mirror)
            runStillMounted = MountPoint.isMounted(volume)
            opened?.close()
        }
        return try inner.run(launchPath, args, stdin: stdin)
    }
}
