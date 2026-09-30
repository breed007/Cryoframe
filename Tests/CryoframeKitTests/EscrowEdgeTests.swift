//
//  EscrowEdgeTests.swift
//  CryoframeKitTests
//
//  Proving a recovered passphrase against real encrypted archives at the edges:
//  an archive another reader already has open (a restore, a drill, a disk opened
//  in Finder as the recovery note says), and damaged images. Measured on macOS
//  26.7: `hdiutil attach -nomount -readonly` of an encrypted sealed disk image that
//  is already attached read-only succeeds (status 0) with ANY passphrase and lists
//  the holder's own devices; an image whose first bytes are damaged attaches as a
//  raw disk with any passphrase; one whose key blob is damaged says "Authentication
//  error" to the right passphrase.
//

import Testing
import Foundation
@testable import CryoframeKit

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-escedge-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

/// an encrypted sealed disk image of a library `name` holding a.txt, as a run writes it
private func encryptedDMG(name: String, passphrase: String, base: URL) throws -> RestorableArchive {
    let lib = base.appendingPathComponent("src").appendingPathComponent(name)
    try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
    try Data("inside".utf8).write(to: lib.appendingPathComponent("a.txt"))
    let dir = base.appendingPathComponent("dest").appendingPathComponent(name)
    let result = try SealedArchiveEngine(.dmg, passphrase: passphrase).archive(ArchiveSource(name: name, root: lib), to: dir)
    try ArchiveManifest.write(try ArchiveManifest.build(for: result, encrypted: true), toDir: dir)
    return try #require(RestoreDiscovery.archive(at: dir))
}

private func attachedDevices(of image: URL) -> Bool {
    ((try? ProcessCommandRunner().run("/usr/bin/hdiutil", ["info"]).stdout) ?? "").contains(image.path)
}

private func damage(_ file: URL, at offset: UInt64, count: Int) throws {
    let fh = try FileHandle(forWritingTo: file)
    try fh.seek(toOffset: offset)
    try fh.write(contentsOf: Data(count: count))
    try fh.close()
}

@Suite(.serialized) struct EscrowEdgeTests {

    // The wizard proves keys while something else may have the same archive open:
    // the scheduled agent's drill or check, or the disk opened in Finder. The proof
    // must not call a wrong passphrase good, and must not take the disk away from
    // whoever has it open.
    @Test func aKeyCheckWhileAReaderHasTheArchiveOpenTrustsNoWrongKeyAndLeavesTheReaderBe() throws {
        let base = folder("held")
        defer { try? FileManager.default.removeItem(at: base) }
        let a = try encryptedDMG(name: "Documents", passphrase: "right", base: base)
        let image = a.dir.appendingPathComponent(a.artifactNames[0])
        let opened = try ArchiveReader().open(a.archiveResult(), passphrase: "right")
        defer { opened.close() }
        let inside = opened.root.appendingPathComponent("a.txt")
        let reading = try FileHandle(forReadingFrom: inside)          // a copy in progress
        defer { try? reading.close() }

        let wrong = KeyCheck().check(a, passphrase: "wrong")
        #expect(wrong != .opens, "a wrong passphrase was called good while the archive was open elsewhere")
        #expect(MountPoint.isMounted(opened.root), "the key check took the disk away from its reader (wrong key)")
        #expect(FileManager.default.fileExists(atPath: inside.path))

        if MountPoint.isMounted(opened.root) {
            _ = KeyCheck().check(a, passphrase: "right")
            #expect(MountPoint.isMounted(opened.root), "the key check took the disk away from its reader (right key)")
        }
        try? reading.close()
        opened.close()
        #expect(!attachedDevices(of: image), "left attached")
    }

    // A disk image whose first bytes are damaged attaches as a raw disk, with any
    // passphrase. That is not a passphrase that opens the archive.
    @Test func anImageWithADamagedHeaderDoesntOpenForAnyPassphrase() throws {
        let base = folder("header")
        defer { try? FileManager.default.removeItem(at: base) }
        let a = try encryptedDMG(name: "Documents", passphrase: "right", base: base)
        let image = a.dir.appendingPathComponent(a.artifactNames[0])
        try damage(image, at: 0, count: 8)
        let proof = KeyCheck().check(a, passphrase: "wrong")
        #expect(proof != .opens, "a wrong passphrase 'opened' a damaged image")
        #expect(!attachedDevices(of: image), "left attached")
    }

    // What the wizard is told of an archive every candidate is refused by: with a
    // damaged key blob, the right passphrase is refused too, and hdiutil says the
    // same words. Pinned so the wizard's wording ("the recovery file's passphrase
    // doesn't open it") is known to cover a damaged archive as well.
    @Test func aDamagedKeyBlobLooksLikeAWrongKey() throws {
        let base = folder("keyblob")
        defer { try? FileManager.default.removeItem(at: base) }
        let a = try encryptedDMG(name: "Documents", passphrase: "right", base: base)
        let image = a.dir.appendingPathComponent(a.artifactNames[0])
        #expect(KeyCheck().check(a, passphrase: "right") == .opens)
        try damage(image, at: 256, count: 768)
        #expect(KeyCheck().check(a, passphrase: "right") == .wrongKey)
        // the manifest's checksum tells the two apart
        #expect(!(try ChecksumVerifier().reverify(archiveDir: a.dir)).passed)
        #expect(!attachedDevices(of: image), "left attached")
    }

    // A 1.4 file: one joined string of libraries. Still matched, name by name.
    @Test func aPre15EntryIsStillACandidate() throws {
        let old = #"[{"jobName":"Nightly","library":"Photos, Documents","passphrase":"p1"},{"jobName":"Other","library":"Documents","passphrase":"p2"}]"#
        let entries = try JSONDecoder().decode([PassphraseEscrow.Entry].self, from: Data(old.utf8))
        #expect(PassphraseEscrow.candidates(for: "Documents", in: entries) == ["p1", "p2"])
        #expect(PassphraseEscrow.candidates(for: "Photos", in: entries) == ["p1"])
        let data = try #require(PassphraseEscrow.exportData(entries, password: "m"))
        #expect(PassphraseEscrow.importEntries(data, password: "m")?.count == 2)
        #expect(PassphraseEscrow.importEntries(data, password: "M") == nil)
    }

    // Nothing stale about a file exported the second the key was saved, libraries
    // listed in another order or twice, or a job renamed since.
    @Test func noFalseStaleness() {
        let t0 = Date(timeIntervalSince1970: 1_000_000.4)
        let export = EscrowFreshness.record([PassphraseEscrow.Entry(jobID: "a", jobName: "Nightly", libraries: ["Photos", "Mail"], passphrase: "p")], at: t0)
        let same = EscrowFreshness.Job(id: "a", name: "Renamed", libraries: ["Mail", "Photos", "Mail"],
                                       keySavedAt: Date(timeIntervalSince1970: 1_000_000))   // the keychain keeps whole seconds
        #expect(EscrowFreshness.status(export: export, jobs: [same]) == .current(t0))
        // and an export record round-trips through defaults' JSON
        let back = try? JSONDecoder().decode(EscrowFreshness.Export.self, from: JSONEncoder().encode(export))
        #expect(back == export)
    }
}
