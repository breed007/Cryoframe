//
//  MirrorAttributeReadBackTests.swift
//  CryoframeKitTests
//
//  The read-back before a mirror's swap compares extended attributes and access
//  lists as well as data: rsync -E writes them through the image on every run, and
//  they are lost the same way data is when the drive fills for an instant.
//

import Testing
import Foundation
@testable import CryoframeKit

private func attrDir(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-mat-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

private func setTag(_ path: String, _ value: String) -> Int32 {
    let bytes = Array(value.utf8)
    return setxattr(path, "com.apple.metadata:_kMDItemUserTags", bytes, bytes.count, 0, XATTR_NOFOLLOW)
}

private func tag(_ path: String) -> String? {
    MirrorCopy.attributeValue(path, "com.apple.metadata:_kMDItemUserTags").map { String(decoding: $0, as: UTF8.self) }
}

/// the mirror's copy of `rel`, read from the image
private func inMirror<T>(_ bundle: URL, _ rel: String, _ body: (String) -> T) throws -> T {
    let mnt = attrDir("look")
    defer { MountPoint.detach(mnt, runner: ProcessCommandRunner()); try? FileManager.default.removeItem(at: mnt) }
    let r = try DiskImageGate.serialized {
        try ProcessCommandRunner().runRetryingBusy("/usr/bin/hdiutil", ["attach", bundle.path, "-mountpoint", mnt.path, "-nobrowse", "-readonly"])
    }
    try #require(r.ok && MountPoint.isMounted(mnt), "\(r.stderr)")
    return body(mnt.appendingPathComponent(rel).path)
}

@Suite(.serialized) struct MirrorAttributeReadBackTests {

    // A Finder tag changes, the file's data and date don't. rsync -E writes the new
    // tag; the write is lost. The read-back used to look only at files whose size or
    // date changed, so the copy went in place carrying the old tag as a success.
    @Test func aFinderTagLostOnTheWayToTheDriveIsCaught() throws {
        let src = attrDir("tagsrc").appendingPathComponent("Lib")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let doc = src.appendingPathComponent("doc.txt")
        try Data("body".utf8).write(to: doc)
        #expect(setTag(doc.path, "Red") == 0)
        let out = attrDir("tag"), base = attrDir("base")
        defer { for d in [out, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        let bundle = try SparseBundleMirrorEngine(sizeGB: 1, mountBase: base).archive(ArchiveSource(name: "Lib", root: src), to: out).artifacts[0]

        #expect(setTag(doc.path, "Blue") == 0)
        let loses = LosesAfterRsync { staging in
            let path = staging.appendingPathComponent("doc.txt").path
            return tag(path) == "Blue" && setTag(path, "Red") == 0      // the write never landed
        }
        var failure: Error?
        do { _ = try SparseBundleMirrorEngine(sizeGB: 1, runner: loses, mountBase: base).archive(ArchiveSource(name: "Lib", root: src), to: out) }
        catch { failure = error }
        try #require(loses.lost, "no tag was lost, so this proves nothing")
        guard case .readBackMismatch? = failure as? MirrorCopyError else {
            Issue.record("a run that lost a tag wasn't failed by the read-back: \(String(describing: failure))"); return
        }
        // nothing was put in place, and the next run carries the new tag
        _ = try SparseBundleMirrorEngine(sizeGB: 1, mountBase: base).archive(ArchiveSource(name: "Lib", root: src), to: out)
        #expect(try inMirror(bundle, "Lib/doc.txt", tag) == "Blue")
    }

    // An access list rsync -E wrote, lost on its way to the drive.
    @Test func anAccessListLostOnTheWayToTheDriveIsCaught() throws {
        let src = attrDir("aclsrc").appendingPathComponent("Lib")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let doc = src.appendingPathComponent("doc.txt")
        try Data("body".utf8).write(to: doc)
        let out = attrDir("acl"), base = attrDir("base")
        defer { for d in [out, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        _ = try SparseBundleMirrorEngine(sizeGB: 1, mountBase: base).archive(ArchiveSource(name: "Lib", root: src), to: out)

        let chmod = try ProcessCommandRunner().run("/bin/chmod", ["+a", "everyone deny delete", doc.path])
        try #require(chmod.ok, "\(chmod.stderr)")
        let loses = LosesAfterRsync { staging in
            let path = staging.appendingPathComponent("doc.txt").path
            guard MirrorCopy.accessList(path) != nil else { return false }
            return (try? ProcessCommandRunner().run("/bin/chmod", ["-N", path]))?.ok == true
        }
        var failure: Error?
        do { _ = try SparseBundleMirrorEngine(sizeGB: 1, runner: loses, mountBase: base).archive(ArchiveSource(name: "Lib", root: src), to: out) }
        catch { failure = error }
        try #require(loses.lost, "no access list was lost, so this proves nothing")
        guard case .readBackMismatch(_, let examples)? = failure as? MirrorCopyError else {
            Issue.record("a run that lost an access list wasn't failed by the read-back: \(String(describing: failure))"); return
        }
        #expect(examples.contains { $0.contains("access list") }, "\(examples)")
    }

    // What the comparison itself calls a difference: names and values, both ways,
    // and access lists; attributes macOS manages itself are left out.
    @Test func attributesAreComparedByNameValueAndAccessList() throws {
        let dir = attrDir("cmp")
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a").path, b = dir.appendingPathComponent("b").path
        for p in [a, b] { FileManager.default.createFile(atPath: p, contents: Data("x".utf8)) }
        #expect(MirrorCopy.differentAttributes(a, b) == nil)
        #expect(setTag(a, "Red") == 0)
        #expect(MirrorCopy.differentAttributes(a, b) == "is missing extended attribute com.apple.metadata:_kMDItemUserTags")
        #expect(setTag(b, "Blue") == 0)
        #expect(MirrorCopy.differentAttributes(a, b) == "has a different value for extended attribute com.apple.metadata:_kMDItemUserTags")
        #expect(setTag(b, "Red") == 0)
        #expect(MirrorCopy.differentAttributes(a, b) == nil)
        #expect(setxattr(b, "com.example.extra", "1", 1, 0, 0) == 0)
        #expect(MirrorCopy.differentAttributes(a, b) == "has extended attribute com.example.extra the library doesn't")
        #expect(removexattr(b, "com.example.extra", 0) == 0)

        let fork = [UInt8](repeating: 7, count: 300)
        #expect(setxattr(a, "com.apple.ResourceFork", fork, fork.count, 0, 0) == 0)
        #expect(setxattr(b, "com.apple.ResourceFork", fork.map { $0 ^ 1 }, fork.count, 0, 0) == 0)
        #expect(MirrorCopy.differentAttributes(a, b) == "has a different resource fork")
        #expect(setxattr(b, "com.apple.ResourceFork", fork, fork.count, 0, 0) == 0)
        #expect(MirrorCopy.differentAttributes(a, b) == nil)

        #expect(try ProcessCommandRunner().run("/bin/chmod", ["+a", "everyone deny delete", a]).ok)
        #expect(MirrorCopy.differentAttributes(a, b) == "is missing its access list")
        #expect(MirrorCopy.differentAttributes(b, a) == "has an access list the library doesn't")
        #expect(try ProcessCommandRunner().run("/bin/chmod", ["+a", "everyone deny delete", b]).ok)
        #expect(MirrorCopy.differentAttributes(a, b) == nil)

        for name in ["com.apple.provenance", "com.apple.macl", "com.apple.rootless", "com.apple.decmpfs",
                     "com.apple.system.Security", "com.apple.metadata:kMDLabel_abc"] {
            #expect(MirrorCopy.managedBySystem(name), "\(name)")
        }
        for name in ["com.apple.metadata:_kMDItemUserTags", "com.apple.FinderInfo", "com.apple.ResourceFork", "com.apple.quarantine"] {
            #expect(!MirrorCopy.managedBySystem(name), "\(name)")
        }
    }
}

extension MirrorAttributeReadBackTests {
    // copyfile(3) re-stamps a download's quarantine on every copy (flags, time and
    // agent change; the id stays). The copy gets the library's value byte for byte.
    @Test func aDownloadsQuarantineIsCopiedExactly() throws {
        let dir = attrDir("qtn")
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.pdf"), b = dir.appendingPathComponent("b.pdf")
        for f in [a, b] { try Data("pdf".utf8).write(to: f) }
        let value = Array("0083;66f9a1b2;Safari;8E3C2F7A-1B2C-4D5E-9F00-112233445566".utf8)
        #expect(setxattr(a.path, "com.apple.quarantine", value, value.count, 0, 0) == 0)
        try MirrorCopy.copyAttributes(from: a, to: b)
        #expect(MirrorCopy.attributeValue(b.path, "com.apple.quarantine") == value)
        #expect(MirrorCopy.differentAttributes(a.path, b.path) == nil)
    }

    // A resource fork whose write is lost after the run has finished writing: the
    // read-back reads it from the drive, finds it neither the old fork nor the new,
    // and nothing is put in place.
    @Test func aResourceForkLostAfterTheWritesIsCaught() throws {
        let src = attrDir("forksrc").appendingPathComponent("Lib")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let doc = src.appendingPathComponent("doc.txt")
        try Data("body".utf8).write(to: doc)
        let fork = [UInt8](repeating: 1, count: 4096)
        #expect(setxattr(doc.path, "com.apple.ResourceFork", fork, fork.count, 0, 0) == 0)
        let out = attrDir("fork"), base = attrDir("base")
        defer { for d in [out, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        let bundle = try SparseBundleMirrorEngine(sizeGB: 1, mountBase: base).archive(ArchiveSource(name: "Lib", root: src), to: out).artifacts[0]
        let fork2 = [UInt8](repeating: 2, count: 4096)
        #expect(setxattr(doc.path, "com.apple.ResourceFork", fork2, fork2.count, 0, 0) == 0)
        let loses = LosesAfterRsync { staging in
            let path = staging.appendingPathComponent("doc.txt").path
            let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            let junk = [UInt8](repeating: 9, count: 4096)
            guard setxattr(path, "com.apple.ResourceFork", junk, junk.count, 0, 0) == 0, let date else { return false }
            try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
            return true
        }
        var failure: Error?
        do { _ = try SparseBundleMirrorEngine(sizeGB: 1, runner: loses, mountBase: base).archive(ArchiveSource(name: "Lib", root: src), to: out) }
        catch { failure = error }
        try #require(loses.lost, "no fork was lost, so this proves nothing")
        guard case .readBackMismatch(_, let examples)? = failure as? MirrorCopyError else {
            Issue.record("a lost fork wasn't caught: \(String(describing: failure))"); return
        }
        #expect(examples == ["doc.txt has a different resource fork"])
        let inMirror = try inMirror(bundle, "Lib/doc.txt") { MirrorCopy.attributeValue($0, "com.apple.ResourceFork") }
        #expect(inMirror == fork, "the previous copy wasn't kept")
    }

    // openrsync -E sends a file's attributes as an AppleDouble file, and a file with
    // none has nothing to send, so a Finder tag or an access list taken off the
    // library's last one stayed on the copy, and the read-back then failed every run
    // (on the CI runners, whose files carry no provenance attribute). Here the copy
    // holds what the library no longer has, on a plain file, a read-only file and a
    // folder; after the pass it holds exactly what the library does, dates kept.
    @Test func theCopyLosesAttributesAndAccessListsTheLibraryNoLongerHas() throws {
        let fm = FileManager.default
        let lib = attrDir("matchsrc"), copy = attrDir("matchdst")
        defer {
            _ = try? ProcessCommandRunner().run("/bin/chmod", ["-R", "u+w", lib.path, copy.path])
            for d in [lib, copy] { try? fm.removeItem(at: d) }
        }
        for root in [lib, copy] {
            try fm.createDirectory(at: root.appendingPathComponent("Folder"), withIntermediateDirectories: true)
            for f in ["plain.txt", "locked.txt", "kept.txt"] { try Data("x".utf8).write(to: root.appendingPathComponent(f)) }
        }
        #expect(setTag(lib.appendingPathComponent("kept.txt").path, "Green") == 0)
        #expect(setTag(copy.appendingPathComponent("kept.txt").path, "Green") == 0)
        for rel in ["plain.txt", "locked.txt", "Folder"] {
            #expect(setTag(copy.appendingPathComponent(rel).path, "Red") == 0)
            #expect(try ProcessCommandRunner().run("/bin/chmod", ["+a", "everyone deny delete", copy.appendingPathComponent(rel).path]).ok)
        }
        for root in [lib, copy] { chmod(root.appendingPathComponent("locked.txt").path, 0o444) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: copy.appendingPathComponent("locked.txt").path)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: lib.appendingPathComponent("locked.txt").path)

        try MirrorCopy.matchAttributes(from: lib, to: copy, control: nil)
        for rel in ["plain.txt", "locked.txt", "kept.txt", "Folder"] {
            #expect(MirrorCopy.differentAttributes(lib.appendingPathComponent(rel).path, copy.appendingPathComponent(rel).path) == nil,
                    "\(rel): \(MirrorCopy.differentAttributes(lib.appendingPathComponent(rel).path, copy.appendingPathComponent(rel).path) ?? "")")
        }
        #expect(tag(copy.appendingPathComponent("kept.txt").path) == "Green")
        let locked = try fm.attributesOfItem(atPath: copy.appendingPathComponent("locked.txt").path)
        #expect(locked[.modificationDate] as? Date == date)
        #expect((locked[.posixPermissions] as? Int) == 0o444)
    }

    // A file the read-back can't open used to be reported as "doesn't match the
    // library", the same as lost data. It says which it was now.
    @Test func theReadBackSaysWhetherBytesDifferOrAFileCouldNotBeRead() throws {
        let dir = attrDir("bytes")
        defer { chmod(dir.appendingPathComponent("locked").path, 0o644); try? FileManager.default.removeItem(at: dir) }
        func file(_ name: String, _ text: String) throws -> String {
            let p = dir.appendingPathComponent(name).path
            try Data(text.utf8).write(to: URL(fileURLWithPath: p))
            return p
        }
        let size = 4
        let x = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        let y = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { x.deallocate(); y.deallocate() }
        let a = try file("a", "the same bytes"), b = try file("b", "the same bytes")
        let c = try file("c", "the other byte"), d = try file("d", "the same bytes, and more")
        #expect(MirrorCopy.byteDifference(a, b, x, y, size) == nil)
        #expect(MirrorCopy.byteDifference(a, c, x, y, size) == "doesn't match the library")
        #expect(MirrorCopy.byteDifference(a, d, x, y, size) == "doesn't match the library")
        #expect(MirrorCopy.byteDifference(d, a, x, y, size) == "doesn't match the library")
        #expect(MirrorCopy.byteDifference(a, dir.appendingPathComponent("gone").path, x, y, size)
                == "couldn't be read back (No such file or directory)")
        let locked = try file("locked", "secret")
        chmod(locked, 0)
        #expect(MirrorCopy.byteDifference(locked, a, x, y, size) == "couldn't be read in the library (Permission denied)")
    }
}

/// Damages the staging copy the way a lost write would (and says whether it did), at
/// the last moment before the read-back: when the run detaches the image to attach it
/// again, after every rsync pass and the attribute pass are done.
private final class LosesAfterRsync: CommandRunner, @unchecked Sendable {
    let inner = ProcessCommandRunner()
    let lose: (URL) -> Bool
    private var staging: URL?
    private(set) var lost = false
    var forTeardown: CommandRunner { self }      // the run detaches through its teardown runner
    init(_ lose: @escaping (URL) -> Bool) { self.lose = lose }
    func run(_ launchPath: String, _ args: [String], stdin: Data?) throws -> CommandResult {
        let tool = (launchPath as NSString).lastPathComponent
        if tool == "hdiutil", args.first == "detach", !lost, let staging { lost = lose(staging) }
        let r = try inner.run(launchPath, args, stdin: stdin)
        if tool == "rsync", r.ok, staging == nil, let dest = args.last { staging = URL(fileURLWithPath: dest) }
        return r
    }
}
