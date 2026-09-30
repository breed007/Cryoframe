//
//  RecoveryCloseoutTests.swift
//  CryoframeKitTests
//
//  The milestone 4 close-out: a drill or rehearsal refused for room on the startup
//  disk is a skipped check with its reason, not a failed archive blaming the
//  passphrase; a zip whose listing can't be read is refused plainly; the key check
//  treats an unanswered hdiutil info as "can't tell"; and the report keeps the
//  numbers and tool words a fix needs.
//

import Testing
import Foundation
@testable import CryoframeKit

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-m4co-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

/// a sealed zip of a small "Notes" folder at <base>/dest/Notes, and a job writing there
private func zippedNotes(_ base: URL) throws -> BackupJob {
    let lib = base.appendingPathComponent("src/Notes")
    try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
    try Data("inside".utf8).write(to: lib.appendingPathComponent("a.txt"))
    let dir = base.appendingPathComponent("dest/Notes")
    let result = try SealedArchiveEngine(.zip).archive(ArchiveSource(name: "Notes", root: lib), to: dir)
    try ArchiveManifest.write(try ArchiveManifest.build(for: result, encrypted: false), toDir: dir)
    let notes = ContentType.genericFolder(id: "n", displayName: "Notes", path: .absolute(lib.path))
    let target = Target.localVolume(id: "d", name: "Backups", dir: base.appendingPathComponent("dest"))
    return BackupJob(name: "Nightly", libraries: [notes], target: target, format: .sealedZip,
                     frequency: .daily(hour: 2, minute: 0), createdAt: Date(timeIntervalSince1970: 0))
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ s: String) { lock.lock(); list.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return list }
}

@Suite(.serialized) struct RecoveryCloseoutTests {

    // MARK: drills and rehearsals without room

    // A zip is unpacked on the startup disk; with no room there the drill is refused
    // before anything is written. That says nothing about the archive: a skipped
    // check that says why, not a failure blaming the passphrase (and an alert).
    @Test func aDrillWithoutRoomOnTheStartupDiskIsSkippedNotFailed() throws {
        let base = folder("drill")
        defer { try? FileManager.default.removeItem(at: base) }
        let job = try zippedNotes(base)
        let report = RestoreDriller(freeSpace: { _ in 1024 }).drill(job: job)
        try #require(report.checks.count == 1)
        let check = report.checks[0]
        #expect(check.skipped, "\(check.detail)")
        #expect(report.passed)
        #expect(check.detail.contains("not enough room"), "\(check.detail)")
        #expect(!check.detail.contains("passphrase"))
        let record = HealthRecord.from(job: job, report: report, at: Date(), kind: "drill")
        #expect(record.failures.isEmpty)
        let phrase = try #require(record.skipPhrase)
        #expect(phrase.contains("not enough room") && !phrase.contains("cloud"), "\(phrase)")
        // with room, the same archive drills clean
        let roomy = RestoreDriller(freeSpace: { _ in 1 << 40 }).drill(job: job)
        #expect(roomy.passed && roomy.checks.allSatisfy { !$0.skipped })
    }

    @Test func aRehearsalWithoutRoomIsSkippedNotFailed() throws {
        let base = folder("rehearse")
        defer { try? FileManager.default.removeItem(at: base) }
        _ = try zippedNotes(base)
        let report = RecoveryRehearsal(freeSpace: { _ in 1024 }).rehearse(destination: base.appendingPathComponent("dest"),
                                                                           expecting: ["Notes"])
        try #require(report.outcomes.count == 1)
        #expect(report.outcomes[0].skipped && report.outcomes[0].ok, "\(report.outcomes[0].detail)")
        #expect(report.asHealthReport(multiDestination: false).passed)
    }

    // A record from before the reasons were kept, a cloud skip, and an open mirror's
    // unchecked copy (which used to be called "not downloaded" too).
    @Test func aSkipIsWordedByWhatItWas() {
        func record(_ notes: [String], skipped: Int) -> HealthRecord {
            HealthRecord(jobID: "j", jobName: "J", checkedAt: Date(), archivesChecked: 0, failures: [], skipped: skipped, skipNotes: notes)
        }
        #expect(record([], skipped: 2).skipPhrase == "2 cloud archives not downloaded")
        #expect(record(["Photos: not downloaded from iCloud Drive — skipped"], skipped: 1).skipPhrase == "1 cloud archive not downloaded")
        #expect(record(["Photos: \(MirrorSeal.uncheckedDetail)"], skipped: 1).skipPhrase?.hasPrefix("1 not checked: Photos: ") == true)
        #expect(record([], skipped: 0).skipPhrase == nil)
    }

    // MARK: a zip whose listing can't be read

    // A zip can unpack to any size; its own size is no bound. When zipinfo can't read
    // the listing it isn't unpacked on a guess.
    @Test func aZipWhoseListingCantBeReadIsRefusedPlainly() throws {
        let base = folder("zipinfo")
        defer { try? FileManager.default.removeItem(at: base) }
        let zip = base.appendingPathComponent("Notes.zip")
        try Data("PK not really".utf8).write(to: zip)
        let calls = Calls()
        let runner = ScriptedCommandRunner { tool, args in
            calls.add(([tool] + args).joined(separator: " "))
            return tool.hasSuffix("zipinfo") ? CommandResult(status: 9, stdout: "", stderr: "cannot find zipfile directory")
                                             : CommandResult(status: 0, stdout: "", stderr: "")
        }
        let reader = ArchiveReader(runner: runner, workBase: base, freeSpace: { _ in 1 << 40 })
        #expect(throws: RestoreError.unpackedSizeUnknown("Notes.zip")) {
            let opened = try reader.open(ArchiveResult(artifacts: [zip], format: .sealedZip))
            opened.close()
        }
        #expect(!calls.all.contains { $0.hasPrefix("/usr/bin/ditto") }, "unpacked anyway: \(calls.all)")
        #expect(RestoreFailureText.restoreMessage(RestoreError.unpackedSizeUnknown("Notes.zip"), encrypted: false).contains("Notes.zip"))
    }

    @Test func theUnpackBudgetCountsABlockForEveryEntry() {
        let runner = ScriptedCommandRunner { _, _ in
            CommandResult(status: 0, stdout: "144100 files, 12900000 bytes uncompressed, 3000000 bytes compressed:  76.7%\n", stderr: "")
        }
        #expect(ArchiveReader.unpackedSize(of: URL(fileURLWithPath: "/x.zip"), runner: runner) == 12_900_000 + 144_100 * 4096)
    }

    // MARK: the key check when hdiutil can't be asked

    // hdiutil info failing is "can't tell". Taken for "nothing attached", a holder's
    // disk handed back by the attach (with any passphrase) was counted as proof, and
    // detached from under its holder.
    @Test func aKeyCheckThatCantAskWhatIsAttachedTriesNothing() throws {
        let base = folder("keyinfo")
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("image".utf8).write(to: base.appendingPathComponent("Notes.dmg"))
        let archive = RestorableArchive(dir: base, libraryName: "Notes", format: .sealedDMG, bytes: 5,
                                        artifactNames: ["Notes.dmg"], encrypted: true)
        let calls = Calls()
        let runner = ScriptedCommandRunner { _, args in
            calls.add(args.joined(separator: " "))
            switch args.first {
            case "info": return CommandResult(status: 1, stdout: "", stderr: "hdiutil: info failed - Resource temporarily unavailable")
            case "attach": return CommandResult(status: 0, stdout: "/dev/disk42\tGUID_partition_scheme\n", stderr: "")
            default: return CommandResult(status: 0, stdout: "", stderr: "")
            }
        }
        let proof = KeyCheck(runner: runner, isEvicted: { _ in false }).check(archive, passphrase: "wrong")
        guard case .unchecked = proof else { Issue.record("called \(proof)"); return }
        #expect(!calls.all.contains { $0.hasPrefix("attach") || $0.hasPrefix("detach") }, "\(calls.all)")
    }

    // MARK: what the report keeps

    // Short numbers and numbers with a unit, dates and times, codes and versions stay,
    // and so do the words the tools use in their errors.
    @Test func theReportKeepsTheNumbersAndToolWordsAFixNeeds() {
        let r = Redactor(names: [], userWords: ["jdoe"])
        let kept = [
            "rsync error: some files/attrs were not transferred (see previous errors) (code 23)",
            "72,000 files, 1,234,567 bytes, 12.9 MB, 3 items, 2 parts",
            "since 2026-09-28 02:00, and Sep 28, 2026 at 2:00 AM",
            "error -36 (-5341), exit status 23, version 1.6.0 on macOS 26.7",
            "stopped with SIGTERM, then SIGKILL after 10 s",
            "sha256 checksum mismatch, AES-256 encrypted",
        ]
        for line in kept {
            let out = r.redact(line)
            let lost = line.split(separator: " ").filter { !out.contains($0) }
            #expect(lost.isEmpty, "\(lost) lost from: \(out)")
        }
        // and what identifies someone goes, however it is written
        for line in ["(404) 555-1234 is missing", "4111-1111-1111-1111 is missing", "4111111111111111 is missing",
                     "123 45 6789 is missing", "404.555.1234 is missing", "1234567 is missing"] {
            #expect(r.redact(line) == "[…] is missing", "\(line) → \(r.redact(line))")
        }
    }

    // MARK: the word list

    // One letter isn't a word of the vocabulary: every letter was in it.
    @Test func singleLettersArentInTheVocabulary() {
        #expect(Redactor.productWords.allSatisfy { $0.count > 1 || $0 == "a" })
        #expect(Redactor.systemWords.allSatisfy { $0.count > 1 || $0 == "a" })
    }
}
