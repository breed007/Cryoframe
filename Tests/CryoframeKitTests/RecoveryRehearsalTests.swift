//
//  RecoveryRehearsalTests.swift
//  CryoframeKitTests
//
//  A rehearsal has to look where a recovery looks, not where the job says. These
//  build real archives on disk and then take things away underneath — the failure a
//  drill can't see, because it derives its paths from the job and keeps passing.
//

import Testing
import Foundation
@testable import CryoframeKit

private func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-reh-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// a destination laid out the way a job writes one: <dest>/<library>/<stamp>/…
///
/// Defaults to a sealed ZIP. A rehearsal doesn't care which sealed format it opens,
/// and a zip is extracted rather than attached — so these tests don't compete for
/// disk-image devices, which are limited and shared with every other test here.
/// The encrypted cases still use a DMG, because that is where encryption lives.
@discardableResult
private func writeArchive(_ dest: URL, library: String, day: Int, passphrase: String? = nil,
                          format: SealedArchiveEngine.Sealed = .zip) throws -> URL {
    let src = tempDir().appendingPathComponent(library)
    try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
    try Data("content for \(library) day \(day)".utf8).write(to: src.appendingPathComponent("file.txt"))
    let versionDir = dest.appendingPathComponent(library, isDirectory: true)
        .appendingPathComponent("2026-07-\(String(format: "%02d", day))-020000", isDirectory: true)
    try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)
    let result = try SealedArchiveEngine(.dmg, passphrase: passphrase)
        .archive(ArchiveSource(name: library, root: src), to: versionDir)
    try ArchiveManifest.write(try ArchiveManifest.build(for: result, encrypted: passphrase != nil), toDir: versionDir)
    return versionDir
}

@Suite(.serialized) struct RecoveryRehearsals {

    @Test func rehearsingOpensEveryLibraryARecoveryWouldFind() throws {
        let dest = tempDir(); defer { try? FileManager.default.removeItem(at: dest) }
        try writeArchive(dest, library: "Photos", day: 20)
        try writeArchive(dest, library: "Music", day: 20)

        let r = RecoveryRehearsal().rehearse(destination: dest, expecting: ["Photos", "Music"])
        // on failure, say which library and why — the message is the whole point of a rehearsal
        let dump = r.outcomes.map { "\($0.library): \($0.detail)" }.joined(separator: " | ")
        #expect(r.openedCount == 2, "\(dump)")
        #expect(r.passed, "\(dump); missing: \(r.missing)")
        #expect(r.missing.isEmpty)
    }

    @Test func aLibraryThatStoppedArrivingIsNamed() throws {
        // the whole point: the job still says it protects Music, and a drill derives
        // its path from that job and keeps passing. A recovery would find nothing.
        let dest = tempDir(); defer { try? FileManager.default.removeItem(at: dest) }
        try writeArchive(dest, library: "Photos", day: 20)

        let r = RecoveryRehearsal().rehearse(destination: dest, expecting: ["Photos", "Music"])
        #expect(!r.passed)
        #expect(r.missing == ["Music"])
        #expect(r.openedCount == 1)          // Photos is still fine
    }

    @Test func anEncryptedArchiveOpensWithItsKeyAndIsReportedLockedWithout() throws {
        let dest = tempDir(); defer { try? FileManager.default.removeItem(at: dest) }
        try writeArchive(dest, library: "Photos", day: 20, passphrase: "open-sesame", format: .dmg)

        let locked = RecoveryRehearsal().rehearse(destination: dest, expecting: ["Photos"])
        #expect(!locked.passed)
        #expect(locked.outcomes.first?.locked == true)
        #expect(locked.outcomes.first?.detail.contains("no passphrase") == true)

        let unlocked = RecoveryRehearsal().rehearse(destination: dest, expecting: ["Photos"],
                                                    passphrase: { _ in "open-sesame" })
        #expect(unlocked.passed)
        #expect(unlocked.openedCount == 1)
    }

    @Test func aWrongKeyIsNotMistakenForALockedLibrary() throws {
        // "locked" means nobody gave us a key. A key that doesn't work is a real
        // problem and has to read differently.
        let dest = tempDir(); defer { try? FileManager.default.removeItem(at: dest) }
        try writeArchive(dest, library: "Photos", day: 20, passphrase: "right", format: .dmg)

        let r = RecoveryRehearsal().rehearse(destination: dest, expecting: ["Photos"],
                                             passphrase: { _ in "wrong" })
        #expect(!r.passed)
        #expect(r.outcomes.first?.locked == false)
        #expect(r.outcomes.first?.detail.contains("may no longer match") == true)
    }

    @Test func aCorruptedArchiveFailsBeforeItIsEverOpened() throws {
        let dest = tempDir(); defer { try? FileManager.default.removeItem(at: dest) }
        let versionDir = try writeArchive(dest, library: "Photos", day: 20)
        // rot one byte, the way a bad disk would
        let artifact = try #require(try FileManager.default.contentsOfDirectory(at: versionDir, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent != ArchiveManifest.sidecarName })
        var bytes = try Data(contentsOf: artifact)
        bytes[bytes.count / 2] ^= 0xFF
        try bytes.write(to: artifact)

        let r = RecoveryRehearsal().rehearse(destination: dest, expecting: ["Photos"])
        #expect(!r.passed)
        #expect(r.outcomes.first?.detail.contains("checksums don't match") == true)
    }

    @Test func theRehearsalUsesTheNewestMomentAvailable() throws {
        let dest = tempDir(); defer { try? FileManager.default.removeItem(at: dest) }
        try writeArchive(dest, library: "Photos", day: 20)
        try writeArchive(dest, library: "Photos", day: 24)

        let r = RecoveryRehearsal().rehearse(destination: dest, expecting: ["Photos"])
        #expect(r.moment == VersionStamp.date("2026-07-24-020000"))
        #expect(r.outcomes.count == 1)        // one version per library, not every version
        #expect(r.outcomes.first?.version == VersionStamp.date("2026-07-24-020000"))
    }

    @Test func anEmptyDestinationFailsLoudlyRatherThanQuietly() throws {
        // nothing here at all is the most alarming result there is, and must not
        // read as "everything passed".
        let dest = tempDir(); defer { try? FileManager.default.removeItem(at: dest) }
        let r = RecoveryRehearsal().rehearse(destination: dest, expecting: ["Photos"])
        #expect(!r.passed)
        #expect(r.missing == ["Photos"])
        #expect(r.outcomes.isEmpty)
    }
}
