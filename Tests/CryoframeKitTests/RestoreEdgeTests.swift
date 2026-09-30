//
//  RestoreEdgeTests.swift
//  CryoframeKitTests
//
//  Safer restores at their edges: where the room is needed (the destination, and
//  the place a zip is unpacked or split parts are joined), what a mirror's disk
//  image weighs against its library, and restoring alongside names
//  that clash by case, by Unicode normalization, or through a broken link.
//

import Testing
import Foundation
@testable import CryoframeKit

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-redge-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

private func randomFile(_ url: URL, bytes: Int) throws {
    var data = Data(count: bytes)
    data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, bytes) }
    try data.write(to: url)
}

private func sealed(_ kind: SealedArchiveEngine.Sealed, split: SplitPolicy = .none, _ lib: URL, to dir: URL) throws -> RestorableArchive {
    let result = try SealedArchiveEngine(kind, split: split).archive(ArchiveSource(name: lib.lastPathComponent, root: lib), to: dir)
    try ArchiveManifest.write(try ArchiveManifest.build(for: result), toDir: dir)
    return try #require(RestoreDiscovery.archive(at: dir))
}

private final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [String] = []
    func add(_ u: URL) { lock.lock(); urls.append(u.path); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return urls }
}

@Suite(.serialized) struct RestoreEdgeTests {

    // MARK: where the room is needed

    // A zip is unpacked, and split parts are joined, in a temporary folder on the
    // startup disk before the library is copied anywhere: the whole library (or the
    // whole archive) is written there first. With no room there, the restore should
    // be refused before that, as it is for the destination; instead the room there
    // is never asked about, and the restore goes on to write it.
    @Test(arguments: ["zip", "split dmg"])
    func theRoomWhereAnArchiveIsUnpackedOrJoinedIsChecked(_ kind: String) throws {
        let base = folder("unpack")
        defer { try? FileManager.default.removeItem(at: base) }
        let lib = base.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try randomFile(lib.appendingPathComponent("data.bin"), bytes: 3 * 1024 * 1024)
        let a = kind == "zip" ? try sealed(.zip, lib, to: base.appendingPathComponent("archive"))
                              : try sealed(.dmg, split: .maxBytes(1_000_000), lib, to: base.appendingPathComponent("archive"))
        if kind != "zip" { #expect(a.artifactNames.count > 1) }
        let destRoot = base.appendingPathComponent("drive")
        let asked = Asked()
        // plenty of room on the destination drive, none anywhere else
        let engine = RestoreEngine(freeSpace: { url in
            asked.add(url)
            return url.path.hasPrefix(destRoot.path) ? 1 << 40 : 0
        })
        var thrown: Error?
        do { try engine.restore(a, to: destRoot.appendingPathComponent("Restored")) } catch { thrown = error }
        guard case .notEnoughRoom? = thrown as? RestoreError else {
            Issue.record("\(kind): restored (or failed otherwise: \(String(describing: thrown))) after writing the \(kind == "zip" ? "unpacked library" : "joined archive") to \(FileManager.default.temporaryDirectory.path) without asking about its room; asked only about \(Set(asked.all))")
            return
        }
    }

    // A mirror's archive is its disk image, which weighs more than the library in it
    // (the image's own file system, and bands a shrunk library leaves behind). The
    // check before anything is read takes the archive's size as a floor for the
    // library, which a mirror's isn't: a drive with room for the library is refused
    // up front.
    @Test func aMirrorIsNotRefusedUpFrontForTheWeightOfItsDiskImage() throws {
        let base = folder("mroom")
        defer { try? FileManager.default.removeItem(at: base) }
        let lib = base.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        for i in 0..<8 { try randomFile(lib.appendingPathComponent("f\(i).bin"), bytes: 4 * 1024 * 1024) }
        let out = base.appendingPathComponent("mirror")
        let engine = SparseBundleMirrorEngine(sizeGB: 1, mountBase: base)
        _ = try engine.archive(ArchiveSource(name: "Documents", root: lib), to: out)
        for i in 1..<8 { try FileManager.default.removeItem(at: lib.appendingPathComponent("f\(i).bin")) }   // the library shrinks
        _ = try engine.archive(ArchiveSource(name: "Documents", root: lib), to: out)
        let a = try #require(RestoreDiscovery.archive(at: out))
        let library = RestoreRoom.bytes(of: [lib])
        let free = RestoreRoom.needed(for: library) + 4 * 1024 * 1024        // room for the library and its margin, and 4 MB more
        var thrown: Error?
        do { try RestoreEngine(freeSpace: { _ in free }).restore(a, to: base.appendingPathComponent("dest")) } catch { thrown = error }
        #expect(thrown == nil, "library \(library) bytes, disk image \(a.bytes) bytes, free \(free): \(String(describing: thrown))")
    }

    // MARK: alongside

    // A broken link where the library goes takes the name as surely as a folder: a
    // plain restore says so, and a restore alongside goes beside it.
    @Test func aBrokenLinkWhereTheLibraryGoesIsAClash() throws {
        let base = folder("link")
        defer { try? FileManager.default.removeItem(at: base) }
        let lib = base.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try Data("main".utf8).write(to: lib.appendingPathComponent("main.swift"))
        let a = try sealed(.zip, lib, to: base.appendingPathComponent("archive"))
        let dest = base.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let link = dest.appendingPathComponent("Projects")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/nowhere/Projects")
        #expect(throws: RestoreError.destinationExists(link.path)) { try RestoreEngine().restore(a, to: dest) }
        var got: URL?
        do { got = try RestoreEngine().restore(a, to: dest, onClash: .alongside) }
        catch { Issue.record("alongside failed beside a broken link: \(error)") }
        #expect(got?.lastPathComponent == "Projects (2)")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == "/nowhere/Projects", "the link was touched")
    }

    // Names that are the same to the drive: another case, the other Unicode form.
    @Test func clashesByCaseAndByUnicodeFormGoAlongside() throws {
        let base = folder("forms")
        defer { try? FileManager.default.removeItem(at: base) }
        for (name, there, expected) in [("Projects", ["projects", "PROJECTS (2)"], "Projects (3)"),
                                        ("Caf\u{E9}", ["Cafe\u{301}"], "Caf\u{E9} (2)"),
                                        ("Name (2)", ["Name (2)"], "Name (2) (2)")] {
            let lib = base.appendingPathComponent("src-\(UUID().uuidString.prefix(4))").appendingPathComponent(name)
            try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: lib.appendingPathComponent("x.txt"))
            let a = try sealed(.zip, lib, to: base.appendingPathComponent("archive-\(UUID().uuidString.prefix(4))"))
            let dest = base.appendingPathComponent("dest-\(UUID().uuidString.prefix(4))")
            for t in there {
                try FileManager.default.createDirectory(at: dest.appendingPathComponent(t), withIntermediateDirectories: true)
                try Data("mine".utf8).write(to: dest.appendingPathComponent(t).appendingPathComponent("mine.txt"))
            }
            #expect(throws: RestoreError.self) { try RestoreEngine().restore(a, to: dest) }
            let got = try RestoreEngine().restore(a, to: dest, onClash: .alongside)
            #expect(got.lastPathComponent.precomposedStringWithCanonicalMapping == expected.precomposedStringWithCanonicalMapping,
                    "\(name): \(got.lastPathComponent)")
            for t in there {
                #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent(t).appendingPathComponent("mine.txt").path), "\(t) was touched")
            }
        }
    }

    // MARK: quarantine

    // Best effort, and never a failed restore: a download locked in Finder can't take
    // its quarantine back (it keeps the copy's), and a read-only folder's is written
    // back without leaving the folder writable.
    @Test func aLockedDownloadAndAReadOnlyFolderRestore() throws {
        let base = folder("locked")
        defer {
            _ = try? ProcessCommandRunner().run("/usr/bin/chflags", ["-R", "nouchg", base.path])
            _ = try? ProcessCommandRunner().run("/bin/chmod", ["-R", "u+rwx", base.path])
            try? FileManager.default.removeItem(at: base)
        }
        let lib = base.appendingPathComponent("Downloads")
        let saved = lib.appendingPathComponent("Saved")
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
        let value = Array("0083;66f9a1b2;Safari;8E3C2F7A-1B2C-4D5E-9F00-112233445566".utf8)
        let locked = lib.appendingPathComponent("contract.pdf")
        try Data("signed".utf8).write(to: locked)
        try Data("kept".utf8).write(to: saved.appendingPathComponent("kept.zip"))
        for p in [locked.path, saved.path, saved.appendingPathComponent("kept.zip").path] {
            #expect(setxattr(p, "com.apple.quarantine", value, value.count, 0, XATTR_NOFOLLOW) == 0)
        }
        #expect(chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0)
        #expect(chmod(saved.path, 0o555) == 0)
        let out = base.appendingPathComponent("mirror")
        _ = try SparseBundleMirrorEngine(sizeGB: 1, mountBase: base).archive(ArchiveSource(name: "Downloads", root: lib), to: out)
        let a = try #require(RestoreDiscovery.archive(at: out))
        let got = try RestoreEngine().restore(a, to: base.appendingPathComponent("dest"))
        #expect(try String(contentsOf: got.appendingPathComponent("contract.pdf"), encoding: .utf8) == "signed")
        let folderValue = MirrorCopy.attributeValue(got.appendingPathComponent("Saved").path, "com.apple.quarantine")
        #expect(folderValue == value, "\(String(decoding: folderValue ?? [], as: UTF8.self))")
        var st = stat()
        #expect(lstat(got.appendingPathComponent("Saved").path, &st) == 0 && st.st_mode & 0o777 == 0o555, "the folder's mode moved")
    }
}
