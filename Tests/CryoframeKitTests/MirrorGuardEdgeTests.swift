//
//  MirrorGuardEdgeTests.swift
//  CryoframeKitTests
//
//  The third round of mirror edges: attributes carried by the read-only paths across
//  a second run into a clone, the per-drive run lock, fsck on an encrypted image, and
//  waiting for tools that genuinely run long.
//

import Testing
import Foundation
@testable import CryoframeKit

private let hdiutil = "/usr/bin/hdiutil"

/// a fresh folder, named by its real path (see MirrorEdgeTests' edgeDir)
private func guardDir(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-mguard-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

private func tree(_ root: URL) -> [String: Data] {
    var out: [String: Data] = [:]
    guard let walker = FileManager.default.enumerator(atPath: root.path) else { return out }
    while let rel = walker.nextObject() as? String {
        guard walker.fileAttributes?[.type] as? FileAttributeType == .typeRegular else { continue }
        out[rel] = try? Data(contentsOf: root.appendingPathComponent(rel))
    }
    return out
}

/// every path under `root` (and `root` itself as "."), with its extended attributes
/// (names and values), ACL text, mode and, for links, target
private func metadata(_ root: URL) -> [String: String] {
    var out: [String: String] = [:]
    var rels = ["."]
    if let walker = FileManager.default.enumerator(atPath: root.path) { while let r = walker.nextObject() as? String { rels.append(r) } }
    for rel in rels {
        let path = rel == "." ? root.path : root.appendingPathComponent(rel).path
        var st = stat()
        guard lstat(path, &st) == 0 else { continue }
        var line = String(format: "mode %o", st.st_mode & 0o7777)
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        if size > 0 {
            var names = [CChar](repeating: 0, count: size)
            _ = listxattr(path, &names, size, XATTR_NOFOLLOW)
            let list = names.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }.sorted()
            for n in list where n != "com.apple.provenance" {
                let vs = getxattr(path, n, nil, 0, 0, XATTR_NOFOLLOW)
                var v = [UInt8](repeating: 0, count: max(vs, 0))
                if vs > 0 { _ = getxattr(path, n, &v, vs, 0, XATTR_NOFOLLOW) }
                line += " | \(n)=\(v.map { String(format: "%02x", $0) }.joined())"
            }
        }
        if let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) {
            if let text = acl_to_text(acl, nil) {
                // entries only: the header carries the file's own identity
                line += " | acl " + String(cString: text).split(separator: "\n").dropFirst().joined(separator: ";")
                acl_free(UnsafeMutableRawPointer(text))
            }
            acl_free(UnsafeMutableRawPointer(acl))
        }
        if st.st_mode & S_IFMT == S_IFLNK, let t = try? FileManager.default.destinationOfSymbolicLink(atPath: path) { line += " | -> \(t)" }
        out[rel] = line
    }
    return out
}

private func differences(_ got: [String: String], _ want: [String: String]) -> [String] {
    Set(got.keys).union(want.keys).sorted().compactMap { k in
        got[k] == want[k] ? nil : "\(k): mirror [\(got[k] ?? "missing")] library [\(want[k] ?? "missing")]"
    }
}

private func lookInside<T>(_ bundle: URL, _ body: (URL) throws -> T) throws -> T {
    let mnt = guardDir("look")
    defer { MountPoint.detach(mnt, runner: ProcessCommandRunner()); try? FileManager.default.removeItem(at: mnt) }
    let r = try DiskImageGate.serialized {
        try ProcessCommandRunner().runRetryingBusy(hdiutil, ["attach", bundle.path, "-mountpoint", mnt.path, "-nobrowse", "-readonly"])
    }
    try #require(r.ok && MountPoint.isMounted(mnt), "\(r.stderr)")
    return try body(mnt)
}

private func setTag(_ url: URL, _ value: String, name: String = "com.example.tag") {
    _ = value.withCString { setxattr(url.path, name, $0, strlen($0), 0, XATTR_NOFOLLOW) }
}

@Suite(.serialized) struct MirrorGuardEdgeTests {

    // MARK: - what the read-only paths carry into a clone

    // Both ways of copying a library that holds read-only files (the usual one, and
    // the one a backslash in a read-only name forces) go into a clone of the previous
    // copy from the second run on. Everything -E carries has to follow the library
    // there too: an attribute changed or removed since, a folder's ACL, a read-only
    // folder's attribute, a resource fork, links, a new nested read-only file, a file
    // deleted since, the library folder's own attributes.
    @Test(arguments: ["usual", "backslash"])
    func theReadOnlyPathsCarryEveryChangeIntoTheClone(_ path: String) throws {
        let fm = FileManager.default
        let src = guardDir("attrsrc").appendingPathComponent("Lib")
        let run = ProcessCommandRunner()
        for d in ["sub", "denied", "locked"] { try fm.createDirectory(at: src.appendingPathComponent(d), withIntermediateDirectories: true) }
        for f in ["a.txt", "sub/b.txt", "sub/gone.txt", "denied/c.txt", "locked/d.txt", "tagged.txt", "untagged-later.txt", "forked.txt"] {
            try Data("v1 \(f)".utf8).write(to: src.appendingPathComponent(f))
        }
        setTag(src.appendingPathComponent("tagged.txt"), "v1")
        setTag(src.appendingPathComponent("untagged-later.txt"), "v1")
        setTag(src.appendingPathComponent("forked.txt"), "FORK", name: "com.apple.ResourceFork")
        setTag(src.appendingPathComponent("locked"), "dir-tag")
        setTag(src, "root-tag")
        try fm.createSymbolicLink(atPath: src.appendingPathComponent("link").path, withDestinationPath: "a.txt")
        _ = try run.run("/bin/chmod", ["+a", "everyone deny delete", src.appendingPathComponent("denied").path])
        _ = try run.run("/bin/chmod", ["+a", "everyone deny delete", src.path])
        let readOnly = path == "backslash" ? "sub/ro\\name.txt" : "sub/ro-name.txt"
        try Data("ro".utf8).write(to: src.appendingPathComponent(readOnly))
        setTag(src.appendingPathComponent(readOnly), "ro-tag")
        chmod(src.appendingPathComponent(readOnly).path, 0o444)
        chmod(src.appendingPathComponent("locked/d.txt").path, 0o444)
        chmod(src.appendingPathComponent("locked").path, 0o555)
        let out = guardDir("attrs"), base = guardDir("base")
        defer {
            _ = try? run.run("/bin/chmod", ["-R", "-N", src.path])
            _ = try? run.run("/bin/chmod", ["-R", "u+w", src.deletingLastPathComponent().path])
            for d in [out, base, src.deletingLastPathComponent()] { try? fm.removeItem(at: d) }
        }
        let engine = SparseBundleMirrorEngine(sizeGB: 1, mountBase: base)
        let bundle = try engine.archive(ArchiveSource(name: "Lib", root: src), to: out).artifacts[0]
        let first = try lookInside(bundle) { vol in
            differences(metadata(vol.appendingPathComponent("Lib")), metadata(src)) + (tree(vol.appendingPathComponent("Lib")) == tree(src) ? [] : ["contents differ"])
        }
        #expect(first.isEmpty, "after the first run:\n\(first.joined(separator: "\n"))")

        // between runs: attributes change and go, a file goes, a nested read-only file arrives
        setTag(src.appendingPathComponent("tagged.txt"), "v2")
        _ = removexattr(src.appendingPathComponent("untagged-later.txt").path, "com.example.tag", 0)
        setTag(src, "root-tag-v2")
        try fm.removeItem(at: src.appendingPathComponent("sub/gone.txt"))
        try Data("new ro".utf8).write(to: src.appendingPathComponent("sub/new-ro.txt"))
        chmod(src.appendingPathComponent("sub/new-ro.txt").path, 0o444)
        _ = try engine.archive(ArchiveSource(name: "Lib", root: src), to: out)

        let second = try lookInside(bundle) { vol in
            differences(metadata(vol.appendingPathComponent("Lib")), metadata(src)) + (tree(vol.appendingPathComponent("Lib")) == tree(src) ? [] : ["contents differ"])
        }
        #expect(second.isEmpty, "after the second run:\n\(second.joined(separator: "\n"))")
    }

    // MARK: - what a failed run leaves in staging

    // A run that saw its drive fill can leave its staging copy behind (its removal
    // needs room too), and lost band writes leave files there whose size and date are
    // right and whose data isn't. The next run starts from that copy, rsync's quick
    // check (size and date) passes those files over, and the swap puts them in place
    // with the run reported a success. Measured with the harness: 1 of 6 runs after a
    // drive filled by another writer reported success over a library that differed.
    // Here the lost data is planted directly: same size, same date, zeros.
    @Test func aStagingCopyWithLostDataIsNotTrustedByTheNextRun() throws {
        let fm = FileManager.default
        let src = guardDir("lostsrc").appendingPathComponent("Lib")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        for i in 0..<6 {
            var d = Data(count: 64 << 10)
            d.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, 64 << 10) }
            try d.write(to: src.appendingPathComponent("p\(i).raw"))
        }
        let out = guardDir("lost"), base = guardDir("base")
        defer { for d in [out, base, src.deletingLastPathComponent()] { try? fm.removeItem(at: d) } }
        let engine = SparseBundleMirrorEngine(sizeGB: 1, mountBase: base)
        let bundle = try engine.archive(ArchiveSource(name: "Lib", root: src), to: out).artifacts[0]

        // what the failed run left: a staging copy with one file's data lost
        let mnt = guardDir("plant")
        let a = try DiskImageGate.serialized { try ProcessCommandRunner().runRetryingBusy(hdiutil, ["attach", bundle.path, "-mountpoint", mnt.path, "-nobrowse"]) }
        try #require(a.ok, "\(a.stderr)")
        let staging = mnt.appendingPathComponent("\(MirrorCopy.stagingName)/Lib")
        try fm.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
        let cp = try ProcessCommandRunner().run("/bin/cp", ["-c", "-R", "-p", mnt.appendingPathComponent("Lib").path, staging.path])
        try #require(cp.ok, "\(cp.stderr)")
        let damaged = staging.appendingPathComponent("p3.raw")
        let date = try #require(try fm.attributesOfItem(atPath: src.appendingPathComponent("p3.raw").path)[.modificationDate] as? Date)
        try Data(count: 64 << 10).write(to: damaged)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: damaged.path)
        MountPoint.detach(mnt, runner: ProcessCommandRunner())
        try? fm.removeItem(at: mnt)

        _ = try engine.archive(ArchiveSource(name: "Lib", root: src), to: out)
        let inside = try lookInside(bundle) { tree($0.appendingPathComponent("Lib")) }
        let wrong = tree(src).keys.filter { inside[$0] != tree(src)[$0] }.sorted()
        #expect(wrong.isEmpty, "the run succeeded and the mirror holds lost data in \(wrong)")
    }

    // MARK: - one mirror run per drive

    // The lock is per mounted volume. Two drives with the same name are two volumes,
    // and a lock file left from an earlier run holds nothing.
    @Test func twoDrivesWithTheSameNameDontWaitForEachOther() throws {
        let base = guardDir("locks"), scratch = guardDir("twins")
        var drives: [URL] = []
        defer {
            for d in drives { MountPoint.detach(d, runner: ProcessCommandRunner()) }
            for d in [base, scratch] { try? FileManager.default.removeItem(at: d) }
        }
        for i in 0..<2 {
            let img = scratch.appendingPathComponent("twin\(i)")
            let made = try ProcessCommandRunner().run(hdiutil, ["create", "-size", "64m", "-fs", "APFS", "-volname", "Backups", "-type", "SPARSE", img.path])
            try #require(made.ok, "\(made.stderr)")
            let mnt = scratch.appendingPathComponent("m\(i)")
            try FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)
            let a = try DiskImageGate.serialized { try ProcessCommandRunner().runRetryingBusy(hdiutil, ["attach", img.path + ".sparseimage", "-mountpoint", mnt.path, "-nobrowse"]) }
            try #require(a.ok, "\(a.stderr)")
            drives.append(mnt)
        }
        let first = try #require(try VolumeLock.acquire(for: drives[0], in: base, control: nil))
        defer { first.release() }
        let start = ProcessInfo.processInfo.systemUptime
        let second = try VolumeLock.acquire(for: drives[1], in: base, control: nil)
        second?.release()
        #expect(second != nil)
        #expect(ProcessInfo.processInfo.systemUptime - start < 0.4, "a drive with the same name waited for the other")

        // released, the lock file stays; taking it again doesn't wait
        first.release()
        let again = try VolumeLock.acquire(for: drives[0], in: base, control: nil)
        #expect(again != nil)
        again?.release()
    }

    // A run waiting for the drive stops when Stop is pressed, within a moment.
    @Test func stopEndsAWaitForTheDrive() throws {
        let base = guardDir("stoplock"), dest = guardDir("stopdest")
        defer { for d in [base, dest] { try? FileManager.default.removeItem(at: d) } }
        let holder = try #require(try VolumeLock.acquire(for: dest, in: base, control: nil))
        defer { holder.release() }
        let control = RunControl()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { control.cancel() }
        let start = ProcessInfo.processInfo.systemUptime
        #expect(throws: CancelledError.self) { _ = try VolumeLock.acquire(for: dest, in: base, control: control) }
        #expect(ProcessInfo.processInfo.systemUptime - start < 3)
    }

    // MARK: - fsck on an encrypted image

    // The check after a dip attaches the image without mounting it and runs fsck_apfs
    // on the container. An encrypted mirror has to be checkable too, with its key,
    // and one without it must not be called damaged.
    @Test func anEncryptedMirrorIsCheckedWithItsKey() throws {
        let src = guardDir("encsrc").appendingPathComponent("Lib")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: src.appendingPathComponent("s.txt"))
        let out = guardDir("enc"), base = guardDir("base")
        defer { for d in [out, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        let bundle = try SparseBundleMirrorEngine(sizeGB: 1, passphrase: "pw", mountBase: base)
            .archive(ArchiveSource(name: "Lib", root: src), to: out).artifacts[0]
        #expect(MirrorIntegrity.check(bundle, passphrase: "pw", runner: ProcessCommandRunner()) == .sound)
        if case .damaged(let why) = MirrorIntegrity.check(bundle, passphrase: "wrong", runner: ProcessCommandRunner()) {
            Issue.record("a wrong key called a sound mirror damaged: \(why)")
        }
        #expect(MirrorMounts.mountPoints(of: bundle, runner: ProcessCommandRunner()).isEmpty)
    }

    // MARK: - waiting for tools

    // Waiting no longer relies on Foundation's notice, and gives up on a process only
    // once it has been reaped without one. A tool that really runs longer than that
    // has to be waited for, and its exit status reported, signals included.
    @Test func aToolThatRunsLongIsWaitedForAndItsStatusKept() throws {
        let start = ProcessInfo.processInfo.systemUptime
        let r = try ProcessCommandRunner().run("/bin/sh", ["-c", "sleep 7; echo done; exit 3"])
        #expect(r.status == 3 && r.stdout == "done\n", "\(r)")
        #expect(ProcessInfo.processInfo.systemUptime - start >= 6.9)

        let killed = try ProcessCommandRunner().run("/bin/sh", ["-c", "sleep 6; kill -TERM $$"])
        #expect(killed.status == SIGTERM, "\(killed)")

        let chatty = try ProcessCommandRunner().run("/bin/sh", ["-c", "for i in 1 2 3 4 5 6; do head -c 200000 /dev/zero | tr '\\0' x; sleep 1; done"])
        #expect(chatty.ok && chatty.stdout.count == 1_200_000)
    }
}
