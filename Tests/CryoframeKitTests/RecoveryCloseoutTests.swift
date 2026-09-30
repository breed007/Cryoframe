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

    // MARK: the word list

    // One letter isn't a word of the vocabulary: every letter was in it.
    @Test func singleLettersArentInTheVocabulary() {
        #expect(Redactor.productWords.allSatisfy { $0.count > 1 || $0 == "a" })
        #expect(Redactor.systemWords.allSatisfy { $0.count > 1 || $0 == "a" })
    }
}
