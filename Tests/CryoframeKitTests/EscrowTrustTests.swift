//
//  EscrowTrustTests.swift
//  CryoframeKitTests
//
//  The recovery file's passphrases are kept per job, a passphrase counts as
//  unlocking an archive only once it has opened it, and the app can tell when the
//  file no longer covers every encrypted job.
//

import Testing
import Foundation
@testable import CryoframeKit

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-escrow-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func entry(_ id: String?, _ job: String, _ libs: [String], _ pass: String) -> PassphraseEscrow.Entry {
    PassphraseEscrow.Entry(jobID: id, jobName: job, libraries: libs, passphrase: pass)
}

/// an encrypted archive of `name` holding one file, as a run writes it
private func encryptedArchive(_ format: ArchiveFormat, name: String, passphrase: String, in dir: URL, base: URL) throws -> RestorableArchive {
    let lib = base.appendingPathComponent("src-\(UUID().uuidString.prefix(6))").appendingPathComponent(name)
    try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
    try Data("inside".utf8).write(to: lib.appendingPathComponent("a.txt"))
    if format == .liveMirror {
        _ = try SparseBundleMirrorEngine(sizeGB: 1, passphrase: passphrase, mountBase: base)
            .archive(ArchiveSource(name: name, root: lib), to: dir)
    } else {
        let result = try SealedArchiveEngine(.dmg, passphrase: passphrase).archive(ArchiveSource(name: name, root: lib), to: dir)
        try ArchiveManifest.write(try ArchiveManifest.build(for: result, encrypted: true), toDir: dir)
    }
    return try #require(RestoreDiscovery.archive(at: dir))
}

private func attached(_ dir: URL) -> Bool {
    ((try? ProcessCommandRunner().run("/usr/bin/hdiutil", ["info"]).stdout) ?? "").contains(dir.path)
}

@Suite(.serialized) struct EscrowTrustTests {

    // MARK: entries per job

    @Test func entriesCarryTheirJobAndOldFilesStillRead() throws {
        let data = try #require(PassphraseEscrow.exportData([entry("job-1", "Nightly", ["Photos"], "p1")], password: "m"))
        let back = try #require(PassphraseEscrow.importEntries(data, password: "m"))
        #expect(back.first?.jobID == "job-1")
        // a 1.5 file: no job id, the libraries as a list and as the joined string
        let old = #"[{"jobName":"Nightly","libraries":["Photos"],"library":"Photos","passphrase":"p1"}]"#
        let decoded = try JSONDecoder().decode([PassphraseEscrow.Entry].self, from: Data(old.utf8))
        #expect(decoded.first?.jobID == nil && decoded.first?.libraries == ["Photos"] && decoded.first?.passphrase == "p1")
        // and an entry without a job still writes no job key, as 1.5 expects
        let json = String(decoding: try JSONEncoder().encode([entry(nil, "J", ["X"], "p")]), as: UTF8.self)
        #expect(!json.contains("jobID"))
    }

    // Two jobs back up a library of the same name to different drives, with
    // different passphrases. Every candidate is kept; the job known to write the
    // archive comes first.
    @Test func everyPassphraseForALibraryNameIsACandidate() {
        let entries = [entry("a", "Home to T7", ["Documents"], "first"),
                       entry("b", "Home to NAS", ["Documents", "Photos"], "second"),
                       entry(nil, "Old", ["Documents"], "first")]
        #expect(PassphraseEscrow.candidates(for: "Documents", in: entries) == ["first", "second"])
        #expect(PassphraseEscrow.candidates(for: "Documents", in: entries, preferring: ["b"]) == ["second", "first"])
        #expect(PassphraseEscrow.candidates(for: "Photos", in: entries) == ["second"])
        #expect(PassphraseEscrow.candidates(for: "Music", in: entries).isEmpty)
        // the old one-per-name map took the first, wrong for the NAS's archive
        #expect(PassphraseEscrow.passphrasesByLibrary(entries)["Documents"] == "first")
    }

    // MARK: proving a key

    // The right passphrase is proven by opening the archive; a wrong one is refused;
    // nothing is left attached. For both encrypted formats.
    @Test(arguments: [ArchiveFormat.sealedDMG, .liveMirror])
    func aPassphraseCountsOnlyOnceItOpensTheArchive(_ format: ArchiveFormat) throws {
        let base = folder("prove")
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.appendingPathComponent("dest/Documents")
        let a = try encryptedArchive(format, name: "Documents", passphrase: "second", in: dir, base: base)
        #expect(a.encrypted)
        let check = KeyCheck()
        #expect(check.check(a, passphrase: "second") == .opens)
        #expect(check.check(a, passphrase: "first") == .wrongKey)
        let found = check.firstOpening(a, candidates: ["first", "second"])
        #expect(found.passphrase == "second" && found.proof == .opens)
        let none = check.firstOpening(a, candidates: ["first", "third"])
        #expect(none.passphrase == nil && none.proof == .wrongKey)
        #expect(!attached(dir), "the check left the archive attached")
    }

    // A split archive or one evicted to the cloud can't be tried without putting it
    // together or downloading it: it is left unchecked, never called unlocked.
    @Test func whatCantBeTriedCheaplyIsLeftUnchecked() throws {
        let split = RestorableArchive(dir: URL(fileURLWithPath: "/nowhere"), libraryName: "Photos", format: .sealedDMG, bytes: 10,
                                      artifactNames: ["Photos.dmg.part.000", "Photos.dmg.part.001"], encrypted: true)
        guard case .unchecked(let why) = KeyCheck().check(split, passphrase: "p") else { Issue.record("split was tried"); return }
        #expect(why.contains("split"))
        let evicted = RestorableArchive(dir: URL(fileURLWithPath: "/nowhere"), libraryName: "Photos", format: .sealedDMG, bytes: 10,
                                        artifactNames: ["Photos.dmg"], encrypted: true)
        guard case .unchecked(let cloud) = KeyCheck(isEvicted: { _ in true }).check(evicted, passphrase: "p") else {
            Issue.record("an evicted archive was tried"); return
        }
        #expect(cloud.contains("cloud"))
        let first = KeyCheck().firstOpening(split, candidates: ["a", "b"])
        #expect(first.passphrase == "a")
        #expect(first.proof != .opens)
    }

    @Test func aWrongKeyIsToldApartFromOtherFailures() {
        #expect(KeyCheck.isWrongKey(ArchiveError.toolFailed(tool: "hdiutil", status: 1, stderr: "hdiutil: attach failed - Authentication error")))
        #expect(!KeyCheck.isWrongKey(ArchiveError.toolFailed(tool: "hdiutil", status: 1, stderr: "hdiutil: attach failed - Resource busy")))
        #expect(!KeyCheck.isWrongKey(RestoreError.libraryNotFound))
    }

    // MARK: freshness

    @Test func theRecoveryFileIsOutOfDateWhenJobsOrKeysChangeAfterIt() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let jobs = [EscrowFreshness.Job(id: "a", name: "Nightly", libraries: ["Photos"], keySavedAt: t0.addingTimeInterval(-60)),
                    EscrowFreshness.Job(id: "b", name: "Docs", libraries: ["Documents"], keySavedAt: nil)]
        #expect(EscrowFreshness.status(export: nil, jobs: []) == .notNeeded)
        #expect(EscrowFreshness.status(export: nil, jobs: jobs) == .neverExported)
        let export = EscrowFreshness.record([entry("a", "Nightly", ["Photos"], "p"), entry("b", "Docs", ["Documents"], "q"),
                                             entry(nil, "Legacy", ["X"], "r")], at: t0)
        #expect(export.jobs == ["a": ["Photos"], "b": ["Documents"]])
        #expect(EscrowFreshness.status(export: export, jobs: jobs) == .current(t0))
        // a new encrypted job, a library added, a passphrase saved again
        let later = jobs + [EscrowFreshness.Job(id: "c", name: "Mail", libraries: ["Mail"], keySavedAt: nil)]
        guard case .outOfDate(let when, let why) = EscrowFreshness.status(export: export, jobs: later) else { Issue.record("not stale"); return }
        #expect(when == t0 && why == ["Mail isn't in it"])
        let grown = [EscrowFreshness.Job(id: "a", name: "Nightly", libraries: ["Photos", "Music"], keySavedAt: nil)]
        #expect(EscrowFreshness.status(export: export, jobs: grown) == .outOfDate(t0, ["Nightly's libraries have changed"]))
        let rekeyed = [EscrowFreshness.Job(id: "a", name: "Nightly", libraries: ["Photos"], keySavedAt: t0.addingTimeInterval(5))]
        #expect(EscrowFreshness.status(export: export, jobs: rekeyed) == .outOfDate(t0, ["Nightly's passphrase was saved after it"]))
        // a job that is gone leaves an extra key in the file: harmless
        #expect(EscrowFreshness.status(export: export, jobs: [jobs[0]]) == .current(t0))
    }
}
