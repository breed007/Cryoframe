//
//  FilteredCopyTests.swift
//  CryoframeKitTests
//
//  Sealed formats on a folder holding named pipes and sockets: the build reads a
//  copy without them (FilteredCopy), and the archive must be the one a direct build
//  of the folder would have made, layout, hard links, flags, attributes and all.
//
//  NEVER let a folder with an unreadable or foreign item reach a real hdiutil
//  create here: it puts a password dialog on the screen (see DMGSourceCheckTests).
//

import Testing
import Foundation
@testable import CryoframeKit

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-filtered-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

/// everything under `dir` made removable: flags, access lists, modes
private func unlock(_ dir: URL) {
    _ = try? ProcessCommandRunner().run("/usr/bin/chflags", ["-R", "0", dir.path])
    _ = try? ProcessCommandRunner().run("/bin/chmod", ["-R", "-N", dir.path])
    _ = try? ProcessCommandRunner().run("/bin/chmod", ["-R", "u+rwx", dir.path])
}

private func sh(_ cmd: String, in dir: URL) throws {
    let r = try ProcessCommandRunner().run("/bin/sh", ["-c", "cd '\(dir.path)' && \(cmd)"])
    try #require(r.ok, "\(cmd): \(r.stderr)")
}

/// a socket file `name` in `dir`, bound from inside it (a socket's path may be only 104 bytes)
private func makeSocket(_ name: String, in dir: URL) throws {
    try sh("/usr/bin/python3 -c \"import socket; socket.socket(socket.AF_UNIX).bind('\(name)')\"", in: dir)
}

/// A library with what a direct disk image keeps and rsync alone doesn't (hard links,
/// a hidden and a locked file, a hidden and a locked folder), and what the mirror's
/// copier already carries (read-only files and folders, attributes, an access list,
/// links, an empty folder).
private func makeLibrary(_ lib: URL) throws {
    try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
    try sh("""
        mkdir -p sub/deeper Empty ReadOnly Hidden Locked && \
        echo one > a.txt && echo two > sub/b.txt && ln sub/b.txt link-to-b.txt && ln sub/b.txt sub/deeper/b-again.txt && \
        echo hidden > hidden.txt && chflags hidden hidden.txt && \
        echo locked > locked.txt && chflags uchg locked.txt && \
        echo in > Hidden/in.txt && chflags hidden Hidden && \
        echo kept > Locked/kept.txt && \
        echo ro > ReadOnly/ro.txt && chmod 444 ReadOnly/ro.txt && ln ReadOnly/ro.txt ro-link.txt && chmod 555 ReadOnly && \
        echo tagged > tagged.txt && xattr -w com.example.note 'kept' tagged.txt && \
        ln -s a.txt link-to-a && chmod +a 'everyone deny delete' sub && \
        chflags uchg Locked
        """, in: lib)
}

/// An archive opened the way restore opens it. macOS attaches a fresh disk image by
/// itself for a moment to scan it, and the reader refuses an encrypted image someone
/// else holds, as it should; the test waits that out.
private func openOnceFree(_ result: ArchiveResult, passphrase: String?) throws -> OpenedArchive {
    let until = Date().addingTimeInterval(60)
    while true {
        do { return try ArchiveReader(runner: ProcessCommandRunner()).open(result, passphrase: passphrase) }
        catch let e as DiskImageInUse where e.attachedWithoutMount && Date() < until { Thread.sleep(forTimeInterval: 1) }
    }
}

/// A restore, waiting out a disk-image system kept busy (EAGAIN) by macOS's own scan
/// of a fresh image or by other tests attaching at the same time. The restore's own
/// one retry wasn't always enough under a full suite.
func restoreOnceFree(_ archive: RestorableArchive, to dir: URL, passphrase: String? = nil) throws -> URL {
    let until = Date().addingTimeInterval(60)
    while true {
        do { return try RestoreEngine().restore(archive, to: dir, passphrase: passphrase) }
        catch let ArchiveError.toolFailed(_, _, stderr) where ProcessCommandRunner.isTransient(stderr) && Date() < until {
            Thread.sleep(forTimeInterval: 2)
        } catch let e as DiskImageInUse where e.attachedWithoutMount && Date() < until {
            Thread.sleep(forTimeInterval: 2)        // an encrypted image the scan holds is refused
        }
    }
}

/// `src` copied into `copy` the way the run copies it, before relinking
private func copyLikeTheRun(_ src: URL, _ copy: URL) throws {
    try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
    let runner = ProcessCommandRunner()
    try MirrorCopy.sync(src, into: copy, runner: runner) { c in
        let r = try runner.run(c.tool, c.args)
        try #require(r.ok, "\(c.tool): \(r.stderr)")
    }
}

/// a named pipe in the library and a socket in its "sub" folder, with both folders'
/// dates as they were
private func addSpecialsKeepingDates(_ lib: URL) throws {
    let folders = [lib.path, lib.appendingPathComponent("sub").path]
    var before: [[timespec]] = []
    for f in folders {
        var st = stat()
        try #require(lstat(f, &st) == 0)
        before.append([st.st_atimespec, st.st_mtimespec])
    }
    try #require(mkfifo(lib.appendingPathComponent("build.pipe").path, 0o644) == 0)
    try makeSocket("editor.sock", in: lib.appendingPathComponent("sub"))
    for (i, f) in folders.enumerated() {
        try #require(utimensat(AT_FDCWD, f, &before[i], AT_SYMLINK_NOFOLLOW) == 0)
    }
}

/// what a tree holds, item by item: everything a direct build and a filtered one
/// must agree on. Hard links are named by the first path of their file.
private func describe(_ root: URL, skippingRootDates: Bool = true) -> [String: String] {
    let system: Set<String> = [".fseventsd", ".Trashes", ".Spotlight-V100", ".TemporaryItems", ".DocumentRevisions-V100", ".journal", ".journal_info_block"]
    var rels = [""]
    if let walker = FileManager.default.enumerator(atPath: root.path) {
        while let rel = walker.nextObject() as? String {
            if system.contains(rel.split(separator: "/").first.map(String.init) ?? "") || rel.hasPrefix(".HFS+ Private") { continue }
            rels.append(rel)
        }
    }
    var firstOfInode: [ino_t: String] = [:]
    for rel in rels.sorted() {
        var st = stat()
        if lstat(rel.isEmpty ? root.path : root.appendingPathComponent(rel).path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_nlink > 1,
           firstOfInode[st.st_ino] == nil { firstOfInode[st.st_ino] = rel }
    }
    var out: [String: String] = [:]
    for rel in rels {
        let path = rel.isEmpty ? root.path : root.appendingPathComponent(rel).path
        var st = stat()
        guard lstat(path, &st) == 0 else { out[rel] = "unreadable"; continue }
        let type = st.st_mode & S_IFMT
        var d = "type \(type) mode \(String(st.st_mode & 0o7777, radix: 8)) flags \(st.st_flags & FilteredCopy.copiedFlags)"
        if type == S_IFREG {
            d += " size \(st.st_size) links \(st.st_nlink)"
            if st.st_nlink > 1 { d += " same-as \(firstOfInode[st.st_ino] ?? "?")" }
            d += " data \((try? Data(contentsOf: URL(fileURLWithPath: path))).map { String(decoding: $0, as: UTF8.self) } ?? "?")"
        }
        if type == S_IFLNK { d += " -> \((try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? "?")" }
        if !(rel.isEmpty && skippingRootDates), type != S_IFLNK { d += " mtime \(st.st_mtimespec.tv_sec)" }
        if type != S_IFLNK {
            d += " xattrs \((MirrorCopy.attributeNames(path) ?? []).map { "\($0)=\(MirrorCopy.attributeValue(path, $0) ?? [])" })"
            d += " acl \(MirrorCopy.accessList(path) ?? "-")"
        }
        out[rel] = d
    }
    return out
}

private func differences(_ a: [String: String], _ b: [String: String]) -> [String] {
    Set(a.keys).union(b.keys).sorted().compactMap { k in a[k] == b[k] ? nil : "\(k):\n  direct   \(a[k] ?? "missing")\n  filtered \(b[k] ?? "missing")" }
}

@Suite(.serialized) struct FilteredCopyTests {

    // The archive of a folder holding a named pipe and a socket, built from the
    // filtered copy, against a direct build of the same folder made before they were
    // put in: the same tree, read through the same reader restore uses, for a plain
    // folder (spread over a disk image's root) and a package (one item on it), as a
    // plain disk image, an encrypted one, and a zip.
    @Test(arguments: [("Projects", SealedArchiveEngine.Sealed.dmg, false),
                      ("MyLib.photoslibrary", .dmg, false),
                      ("Projects", .dmg, true),
                      ("MyLib.photoslibrary", .dmg, true),
                      ("Projects", .zip, false),
                      ("MyLib.photoslibrary", .zip, false)])
    func aFilteredBuildMatchesADirectOne(_ name: String, _ kind: SealedArchiveEngine.Sealed, _ encrypted: Bool) throws {
        let base = folder("match")
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        let lib = base.appendingPathComponent(name)
        try makeLibrary(lib)
        let passphrase = encrypted ? "pw" : nil
        let direct = try SealedArchiveEngine(kind, passphrase: passphrase)
            .archive(ArchiveSource(name: name, root: lib), to: base.appendingPathComponent("direct"))

        // the pipe and the socket go in after the direct build; their folders' dates
        // are put back, so the library is what the direct build read, plus them
        try addSpecialsKeepingDates(lib)
        let buildDir = base.appendingPathComponent("build")
        let made = try FilteredCopy.make(of: lib, name: name, in: buildDir, runner: ProcessCommandRunner())
        #expect(Set(made.leftOut) == ["build.pipe", "sub/editor.sock"], "\(made.leftOut)")
        #expect(made.copy.lastPathComponent == name)
        // as the run builds it (see FilteredCopy.build)
        let filtered = try FilteredCopy.build(SealedArchiveEngine(kind, passphrase: passphrase),
                                              from: ArchiveSource(name: name, root: made.copy), to: buildDir, library: name).archive
        FilteredCopy.remove(in: buildDir, runner: ProcessCommandRunner())
        #expect(!FileManager.default.fileExists(atPath: buildDir.appendingPathComponent("filtered").path), "the copy wasn't removed")

        let a = try openOnceFree(direct, passphrase: passphrase)
        defer { a.close() }
        let b = try openOnceFree(filtered, passphrase: passphrase)
        defer { b.close() }
        let left = describe(a.root), right = describe(b.root)
        let diff = differences(left, right)
        #expect(diff.isEmpty, "\(diff.joined(separator: "\n"))")
        #expect(!right.keys.contains { $0.hasSuffix("build.pipe") || $0.hasSuffix("editor.sock") })
        if kind == .dmg {
            // the hard links are one file in the image, as in a direct build
            #expect(right.values.contains { $0.contains("links 3") }, "\(right)")
        }
    }

    // Restored through RestoreEngine's own rule (a package is one item on a disk
    // image's root, a plain folder is spread over it), a filtered build comes back as
    // the library, not nested one level down.
    @Test(arguments: ["Projects", "MyLib.photoslibrary"])
    func aFilteredDiskImageRestoresAsTheLibrary(_ name: String) throws {
        let base = folder("restore")
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        let lib = base.appendingPathComponent(name)
        try makeLibrary(lib)
        try #require(mkfifo(lib.appendingPathComponent("build.pipe").path, 0o644) == 0)
        let buildDir = base.appendingPathComponent("build")
        let made = try FilteredCopy.make(of: lib, name: name, in: buildDir, runner: ProcessCommandRunner())
        let out = base.appendingPathComponent("out")
        let result = try FilteredCopy.build(SealedArchiveEngine(.dmg), from: ArchiveSource(name: name, root: made.copy),
                                            to: out, library: name).archive
        FilteredCopy.remove(in: buildDir, runner: ProcessCommandRunner())
        try ArchiveManifest.write(try ArchiveManifest.build(for: result), toDir: out)
        let archive = try #require(RestoreDiscovery.archive(at: out))
        let restored = try restoreOnceFree(archive, to: base.appendingPathComponent("restored"))
        #expect(restored.lastPathComponent == name)
        #expect(try String(contentsOf: restored.appendingPathComponent("a.txt"), encoding: .utf8) == "one\n")
        #expect(try String(contentsOf: restored.appendingPathComponent("sub/deeper/b-again.txt"), encoding: .utf8) == "two\n")
        #expect(!FileManager.default.fileExists(atPath: restored.appendingPathComponent(name).path), "the library came back nested")
        #expect(!FileManager.default.fileExists(atPath: restored.appendingPathComponent("build.pipe").path))
    }

    // MARK: hard links

    @Test func relinkMakesLaterPathsLinksToTheFirst() throws {
        let base = folder("relink")
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        let src = base.appendingPathComponent("src"), copy = base.appendingPathComponent("copy")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("ro"), withIntermediateDirectories: true)
        try sh("echo x > ro/a && ln ro/a b && chmod 555 ro", in: src)
        let groups = FilteredCopy.hardLinks(in: src)
        #expect(groups == [["b", "ro/a"]], "\(groups)")
        try copyLikeTheRun(src, copy)
        // the read-only folder's mode and date are put back after its link is made
        var before = stat()
        try #require(lstat(copy.appendingPathComponent("ro").path, &before) == 0)
        #expect(FilteredCopy.relink(groups, source: src, copy: copy) == 1)
        var a = stat(), b = stat(), after = stat()
        #expect(lstat(copy.appendingPathComponent("b").path, &a) == 0 && lstat(copy.appendingPathComponent("ro/a").path, &b) == 0)
        #expect(a.st_ino == b.st_ino && a.st_nlink == 2)
        #expect(lstat(copy.appendingPathComponent("ro").path, &after) == 0)
        #expect(after.st_mode == before.st_mode)
        #expect(after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec && after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec)
        #expect(try FileManager.default.contentsOfDirectory(atPath: copy.appendingPathComponent("ro").path) == ["a"], "a temporary link was left")
    }

    // A folder on the way swapped for a link to somewhere else: nothing is linked
    // there, or anywhere.
    @Test func relinkRefusesAFolderSwappedForALink() throws {
        let base = folder("swap")
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        let src = base.appendingPathComponent("src"), copy = base.appendingPathComponent("copy"), elsewhere = base.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("d"), withIntermediateDirectories: true)
        try sh("echo x > a && ln a d/b", in: src)
        let groups = FilteredCopy.hardLinks(in: src)
        try copyLikeTheRun(src, copy)
        // the copy's folder replaced by a link to a look-alike elsewhere
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: copy.appendingPathComponent("d/b"), to: elsewhere.appendingPathComponent("b"))
        try FileManager.default.removeItem(at: copy.appendingPathComponent("d"))
        try FileManager.default.createSymbolicLink(at: copy.appendingPathComponent("d"), withDestinationURL: elsewhere)
        #expect(FilteredCopy.relink(groups, source: src, copy: copy) == 0)
        var x = stat(), y = stat()
        #expect(lstat(copy.appendingPathComponent("a").path, &x) == 0 && lstat(elsewhere.appendingPathComponent("b").path, &y) == 0)
        #expect(x.st_ino != y.st_ino && x.st_nlink == 1, "a link was made through the swapped folder")
        // and in the library: a folder there that is now a link
        let copy2 = base.appendingPathComponent("copy2")
        try copyLikeTheRun(src, copy2)
        try FileManager.default.removeItem(at: src.appendingPathComponent("d"))
        try FileManager.default.createSymbolicLink(at: src.appendingPathComponent("d"), withDestinationURL: elsewhere)
        #expect(FilteredCopy.relink(groups, source: src, copy: copy2) == 0)
    }

    // The library changed under the run (one read live, off a drive that can't be
    // frozen): the two paths are no longer one file there, or the copy's files aren't
    // the library file's size and date. Each stays the copy rsync made.
    @Test func relinkRefusesWhatNoLongerMatches() throws {
        let base = folder("drift")
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        let src = base.appendingPathComponent("src"), copy = base.appendingPathComponent("copy")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try sh("echo x > a && ln a b && echo y > c && ln c d", in: src)
        let groups = FilteredCopy.hardLinks(in: src)
        #expect(groups == [["a", "b"], ["c", "d"]], "\(groups)")
        try copyLikeTheRun(src, copy)
        try sh("rm b && echo x > b", in: src)                     // no longer one file
        try sh("echo longer > d", in: copy)                       // the copy isn't the library's file
        #expect(FilteredCopy.relink(groups, source: src, copy: copy) == 0)
        var a = stat(), b = stat(), c = stat(), d = stat()
        _ = lstat(copy.appendingPathComponent("a").path, &a); _ = lstat(copy.appendingPathComponent("b").path, &b)
        _ = lstat(copy.appendingPathComponent("c").path, &c); _ = lstat(copy.appendingPathComponent("d").path, &d)
        #expect(a.st_ino != b.st_ino && c.st_ino != d.st_ino)
    }

    // A link that can't be made (a locked folder) leaves the copy as it was, with no
    // temporary name in it; a file system whose links a disk image doesn't keep isn't
    // relinked at all.
    @Test func aFailedRelinkLeavesTheCopyAsItWas() throws {
        let base = folder("fail")
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        let src = base.appendingPathComponent("src"), copy = base.appendingPathComponent("copy")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("d"), withIntermediateDirectories: true)
        try sh("echo x > a && ln a d/b", in: src)
        let groups = FilteredCopy.hardLinks(in: src)
        try copyLikeTheRun(src, copy)
        try #require(chflags(copy.appendingPathComponent("d").path, UInt32(UF_IMMUTABLE)) == 0)
        #expect(FilteredCopy.relink(groups, source: src, copy: copy) == 0)
        _ = chflags(copy.appendingPathComponent("d").path, 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: copy.appendingPathComponent("d").path) == ["b"])
        #expect(try String(contentsOf: copy.appendingPathComponent("d/b"), encoding: .utf8) == "x\n")
        #expect(!FilteredCopy.keepsHardLinks(URL(fileURLWithPath: "/dev")))
        #expect(FilteredCopy.keepsHardLinks(base))
    }

    // MARK: flags, removal, room

    // Hidden and locked, on files and folders, as a direct disk image keeps them; and
    // the copy, locked items and a deny-delete list included, is removed whole.
    @Test func flagsAreCopiedAndTheCopyIsRemoved() throws {
        let base = folder("flags")
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        let lib = base.appendingPathComponent("Lib")
        try makeLibrary(lib)
        let buildDir = base.appendingPathComponent("build")
        let made = try FilteredCopy.make(of: lib, name: "Lib", in: buildDir, runner: ProcessCommandRunner())
        func flags(_ root: URL, _ rel: String) -> UInt32 {
            var st = stat(); _ = lstat(root.appendingPathComponent(rel).path, &st); return st.st_flags & FilteredCopy.copiedFlags
        }
        for rel in ["hidden.txt", "locked.txt", "Hidden", "Locked", "a.txt"] {
            #expect(flags(made.copy, rel) == flags(lib, rel), "\(rel)")
        }
        #expect(flags(made.copy, "locked.txt") == UInt32(UF_IMMUTABLE) && flags(made.copy, "Hidden") == UInt32(UF_HIDDEN))
        FilteredCopy.remove(in: buildDir, runner: ProcessCommandRunner())
        #expect(!FileManager.default.fileExists(atPath: buildDir.appendingPathComponent("filtered").path))
    }

    @Test func aFilteredBuildNeedsRoomForTheCopyAsWell() {
        #expect(JobExecutor.scratchRoom(1000, filtered: false) == (1050, 1000))
        #expect(JobExecutor.scratchRoom(1000, filtered: true) == (2050, 2000))
    }

    // A crash mid-build leaves the copy in scratch; the sweep removes it, locked
    // files and all, even beside an archive a transfer still needs.
    @Test func theSweepRemovesACopyACrashLeft() throws {
        let base = folder("sweep")
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        let scratch = base.appendingPathComponent("scratch")
        let libDir = scratch.appendingPathComponent("job/build/lib")
        let copy = libDir.appendingPathComponent("filtered/Lib")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        try sh("echo x > locked && chflags uchg locked && chmod 555 .", in: copy)
        let artifact = libDir.appendingPathComponent("Lib.dmg")
        try Data("dmg".utf8).write(to: artifact)
        let store = PendingTransferStore(url: base.appendingPathComponent("pending.json"))
        store.save(PendingTransfer(jobID: "job:d:lib", sourceFile: artifact.path, baseName: "Lib.dmg", totalBytes: 3,
                                   chunkSize: 1, targetDir: base.path, format: .sealedDMG))
        JobExecutor.sweepOrphanedScratch(scratchBase: scratch, pendingStore: store)
        #expect(!FileManager.default.fileExists(atPath: libDir.appendingPathComponent("filtered").path))
        #expect(FileManager.default.fileExists(atPath: artifact.path), "the archive a transfer needs went too")
    }
}
