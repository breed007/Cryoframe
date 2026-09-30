//
//  RecoveryNoteEdgeTests.swift
//  CryoframeKitTests
//
//  The recovery note checked against a real folder, and followed as written: a
//  folder holding what real runs write (versions of an encrypted disk image, a
//  disk image split into parts, a live mirror), the Terminal steps the note gives
//  run as given, several writers at once, and an exFAT drive.
//

import Testing
import Foundation
@testable import CryoframeKit

private let hdiutil = "/usr/bin/hdiutil"

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-noteedge-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

private func library(_ name: String, in base: URL, bytes: Int = 4096) throws -> URL {
    let lib = base.appendingPathComponent("src-\(UUID().uuidString.prefix(6))").appendingPathComponent(name)
    try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
    var data = Data(count: bytes)
    data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, bytes) }
    try data.write(to: lib.appendingPathComponent("data.bin"))
    return lib
}

/// a sealed version as a run writes it: <dest>/<name>/<stamp>/ with the manifest
@discardableResult
private func version(_ name: String, _ kind: SealedArchiveEngine.Sealed, at date: Date, split: SplitPolicy = .none,
                     passphrase: String? = nil, bytes: Int = 4096, dest: URL, base: URL) throws -> URL {
    let dir = dest.appendingPathComponent(name).appendingPathComponent(VersionStamp.string(date))
    let lib = try library(name, in: base, bytes: bytes)
    let result = try SealedArchiveEngine(kind, split: split, passphrase: passphrase).archive(ArchiveSource(name: name, root: lib), to: dir)
    try ArchiveManifest.write(try ArchiveManifest.build(for: result, encrypted: passphrase != nil), toDir: dir)
    return dir
}

private func sh(_ script: String) throws -> CommandResult {
    try ProcessCommandRunner().run("/bin/sh", ["-c", script])
}

@Suite(.serialized) struct RecoveryNoteEdgeTests {

    // Every place the note names is there, every count it gives is right, and its
    // Terminal steps work as written: the checksum matches the manifest, the parts
    // join into a disk image that opens, the mirror opens and holds the library.
    @Test func theNoteMatchesARealFolderAndItsStepsWork() throws {
        let base = folder("real")
        defer {
            _ = try? ProcessCommandRunner().run(hdiutil, ["detach", "-force", base.appendingPathComponent("look").path])
            try? FileManager.default.removeItem(at: base)
        }
        let dest = base.appendingPathComponent("dest")
        let d1 = Date(timeIntervalSince1970: 1_790_000_000), d2 = d1.addingTimeInterval(86_400)
        try version("Photos", .dmg, at: d1, passphrase: "pw", dest: dest, base: base)
        let newest = try version("Photos", .dmg, at: d2, passphrase: "pw", dest: dest, base: base)
        let split = try version("Mail", .dmg, at: d1, split: .maxBytes(400_000), bytes: 1_000_000, dest: dest, base: base)
        let projects = try library("Projects", in: base)
        _ = try SparseBundleMirrorEngine(sizeGB: 1, mountBase: base)
            .archive(ArchiveSource(name: "Projects", root: projects), to: dest.appendingPathComponent("Projects"))
        #expect(RecoveryNote.write(in: dest) == nil)
        let note = try String(contentsOf: dest.appendingPathComponent(RecoveryNote.fileName), encoding: .utf8)

        // what it says is there
        #expect(note.contains("Photos - sealed disk image (.dmg), encrypted") && note.contains("2 versions"), "\(note)")
        #expect(note.contains("Photos/\(newest.lastPathComponent)/") && FileManager.default.fileExists(atPath: newest.path))
        let parts = try FileManager.default.contentsOfDirectory(atPath: split.path).filter { $0.contains(".part.") }.count
        #expect(parts > 1 && note.contains("split into \(parts) parts"), "\(parts) parts; \(note)")
        #expect(note.contains("one copy kept up to date: Projects.sparsebundle"))
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("Projects/Projects.sparsebundle").path))
        for line in note.split(separator: "\n") where line.contains("In the folder ") {
            let named = line.components(separatedBy: "In the folder ")[1].components(separatedBy: "/")[0]
            #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent(named).path), "\(named) isn't there")
        }
        #expect(!note.contains("pw"), "a passphrase is in the note")

        // shasum, as the note says, against the manifest
        let manifest = try String(contentsOf: newest.appendingPathComponent(ArchiveManifest.sidecarName), encoding: .utf8)
        let sum = try sh("cd '\(newest.path)' && shasum -a 256 'Photos.dmg'")
        let digest = String(sum.stdout.prefix(64))
        #expect(sum.ok && digest.count == 64 && manifest.contains(digest), "\(sum.stdout) vs \(manifest)")

        // join the parts, as the note says, then open the joined image
        let join = try sh("cd '\(split.path)' && cat \"Mail.dmg.part.\"* > '\(base.path)/Mail.dmg'")
        #expect(join.ok, "\(join.stderr)")
        let verified = try ProcessCommandRunner().run(hdiutil, ["verify", base.appendingPathComponent("Mail.dmg").path])
        #expect(verified.ok, "the joined parts aren't a disk image: \(verified.stderr)")

        // the mirror opens read-only and the folder named after the library is the backup
        let look = base.appendingPathComponent("look")
        try FileManager.default.createDirectory(at: look, withIntermediateDirectories: true)
        let opened = try DiskImageGate.serialized {
            try ProcessCommandRunner().runRetryingBusy(hdiutil, ["attach", "-readonly", "-nobrowse", "-mountpoint", look.path,
                                                                 dest.appendingPathComponent("Projects/Projects.sparsebundle").path])
        }
        #expect(opened.ok, "\(opened.stderr)")
        #expect(FileManager.default.fileExists(atPath: look.appendingPathComponent("Projects/data.bin").path))
        MountPoint.detach(look, runner: ProcessCommandRunner())
    }

    // Two jobs finishing at once both bring the note up to date. It ends complete
    // and describing the folder, with nothing else left at the top of it.
    @Test func writersAtOnceLeaveOneCompleteNote() throws {
        let base = folder("race")
        defer { try? FileManager.default.removeItem(at: base) }
        let dest = base.appendingPathComponent("dest")
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        try version("Photos", .zip, at: t0, dest: dest, base: base)
        DispatchQueue.concurrentPerform(iterations: 16) { i in
            if i % 4 == 0 { _ = try? version("Lib\(i)", .zip, at: t0.addingTimeInterval(Double(i)), dest: dest, base: base) }
            RecoveryNote.write(in: dest)
        }
        RecoveryNote.write(in: dest)
        let note = try String(contentsOf: dest.appendingPathComponent(RecoveryNote.fileName), encoding: .utf8)
        #expect(note == RecoveryNote.text(for: RestoreDiscovery.scan(dest)))
        let top = try FileManager.default.contentsOfDirectory(atPath: dest.path).filter { !$0.hasPrefix("Lib") && $0 != "Photos" }
        #expect(top == [RecoveryNote.fileName], "\(top)")
    }

    // An exFAT drive (the usual format for a drive shared with a PC): written, and
    // rewritten over the old one when the folder changes.
    @Test func theNoteOnAnExFATDrive() throws {
        let base = folder("exfat")
        let mnt = base.appendingPathComponent("vol")
        defer {
            MountPoint.detach(mnt, runner: ProcessCommandRunner())
            try? FileManager.default.removeItem(at: base)
        }
        let made = try ProcessCommandRunner().run(hdiutil, ["create", "-size", "64m", "-fs", "ExFAT", "-volname", "SHARED",
                                                            base.appendingPathComponent("x.dmg").path])
        try #require(made.ok, "\(made.stderr)")
        try FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)
        let attached = try DiskImageGate.serialized {
            try ProcessCommandRunner().runRetryingBusy(hdiutil, ["attach", base.appendingPathComponent("x.dmg").path,
                                                                 "-mountpoint", mnt.path, "-nobrowse"])
        }
        try #require(attached.ok && MountPoint.isMounted(mnt), "\(attached.stderr)")
        let dest = mnt.appendingPathComponent("Backups")
        try version("Photos", .zip, at: Date(timeIntervalSince1970: 1_790_000_000), dest: dest, base: base)
        #expect(RecoveryNote.write(in: dest) == nil)
        try version("Mail", .zip, at: Date(timeIntervalSince1970: 1_790_000_000), dest: dest, base: base)
        #expect(RecoveryNote.write(in: dest) == nil)
        let note = try String(contentsOf: dest.appendingPathComponent(RecoveryNote.fileName), encoding: .utf8)
        #expect(note.contains("Photos - sealed zip") && note.contains("Mail - sealed zip"), "\(note)")
        #expect(RestoreDiscovery.libraries(in: RestoreDiscovery.scan(dest)) == ["Mail", "Photos"])
    }
}
