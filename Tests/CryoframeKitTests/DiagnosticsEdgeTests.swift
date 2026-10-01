//
//  DiagnosticsEdgeTests.swift
//  CryoframeKitTests
//
//  The "Report a problem" file is public once attached to an issue, and says of
//  itself that "paths and file names are removed". These feed it what Cryoframe
//  itself writes into the history: a mirror's read-back naming the files that
//  differ, a sealed run naming what it can't read, and a tool's error quoting a
//  path inside a snapshot of an external drive. Mac file names hold spaces, so a
//  name is several words, and every word of it is private.
//

import Testing
import Foundation
@testable import CryoframeKit

private let home = "/Users/jdoe"

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-diagedge-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

/// the report for one job ("Work", a folder on an external drive, to "Backups")
/// whose last run failed with `error`, and warned `warning`
private func report(error: String, warning: String? = nil) -> String {
    let dest = Target.localVolume(id: "t7", name: "Backups", dir: URL(fileURLWithPath: "/Volumes/T7/Backups"))
    let work = ContentType.genericFolder(id: "w", displayName: "Work", path: .absolute("/Volumes/Media/Clients"))
    let job = BackupJob(name: "Nightly", libraries: [work], target: dest, format: .liveMirror(sizeGB: 1),
                        frequency: .daily(hour: 2, minute: 0), createdAt: Date(timeIntervalSince1970: 0))
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let run = RunRecord(id: "r", jobID: job.id, jobName: job.name, startedAt: now.addingTimeInterval(-60), finishedAt: now,
                        trigger: "scheduled", outcome: .failed, summary: "Work failed",
                        libraries: [LibraryOutcome(from: .failed(library: "Work", destination: "Backups", error: error))],
                        bytes: 0, warning: warning)
    let input = DiagnosticsReport.Input(appVersion: "1.6.0 (160)", helperVersion: "1.6.0", agentState: "on", macOS: "26.7",
                                        hardware: "Mac14,2", jobs: [job], runs: [run], health: [], settings: [], now: now)
    let redactor = DiagnosticsReport.redactor(for: input, home: home, userName: "jdoe", fullName: "Jane Doe", hostName: "Jane's MacBook Pro")
    return DiagnosticsReport.build(input, redactor: redactor)
}

/// the private words `report` still holds
private func leaked(_ words: [String], in report: String) -> [String] {
    words.filter { report.range(of: $0, options: .caseInsensitive) != nil }
}

@Suite struct DiagnosticsEdgeTests {

    // The mirror's read-back names up to three items it found different, by their
    // path in the library.
    @Test func aReadBackNamingLibraryFilesLeavesNoWordOfThem() {
        let error = MirrorCopyError.readBackMismatch(count: 3, examples: [
            "Acme Merger/Due Diligence Memo.docx has different extended attributes",
            "Saved/Tax Return 2025.pdf has the wrong size or date",
            "Letter to Dr Smith re divorce.pdf is missing"]).localizedDescription
        let text = report(error: error)
        let found = leaked(["Acme", "Merger", "Diligence", "Memo", "Tax Return", "Letter to", "Smith", "divorce"], in: text)
        #expect(found.isEmpty, "\(found) in the report:\n\(text)")
        #expect(text.contains("didn't read back the same as the library"), "what a fix needs went too:\n\(text)")
    }

    // A sealed run refused up front names the items it can't read, and one that
    // leaves out pipes warns naming them, by their path in the library.
    @Test func aSealedRunNamingWhatItCantReadLeavesNoWordOfIt() throws {
        let base = folder("blockers")
        defer {
            _ = try? ProcessCommandRunner().run("/bin/chmod", ["-R", "u+rwx", base.path])
            try? FileManager.default.removeItem(at: base)
        }
        let lib = base.appendingPathComponent("Clients")
        try FileManager.default.createDirectory(at: lib.appendingPathComponent("Acme Merger"), withIntermediateDirectories: true)
        let locked = lib.appendingPathComponent("Acme Merger/Divorce Settlement Draft v3.pages")
        try Data("draft".utf8).write(to: locked)
        #expect(chmod(locked.path, 0) == 0)
        try #require(mkfifo(lib.appendingPathComponent("Custody Notes Helper.pipe").path, 0o644) == 0)
        let blockers = JobExecutor.directoryStats(lib, forDMG: true).dmgBlockers
        let why = blockers.refusing.explanation(library: "Work")
        try #require(why.contains("Settlement"), "the fixture didn't produce the message: \(why)")
        let note = try #require(blockers.leftOutOfSealed(library: "Work", zip: false))
        try #require(note.contains("Custody"), "the fixture didn't produce the note: \(note)")
        let text = report(error: why, warning: note)
        let found = leaked(["Acme", "Merger", "Divorce", "Settlement", "Draft", "Custody", "Notes"], in: text)
        #expect(found.isEmpty, "\(found) in the report:\n\(text)")
    }

    // A folder on an external APFS drive is read from a snapshot of that drive,
    // mounted under /private/var/run/app.cryoframe/mnt; the drive's own name is
    // gone from the path, and so is the /Volumes/ the redactor looks for.
    @Test func aToolErrorQuotingASnapshotPathLeavesNoWordOfIt() {
        let error = #"rsync: [sender] opendir "/private/var/run/app.cryoframe/mnt/1790000000-ab12cd34/Clients/Acme Merger/Board Minutes" failed: Permission denied (13)"#
        let text = report(error: error)
        let found = leaked(["Clients", "Acme", "Merger", "Board", "Minutes"], in: text)
        #expect(found.isEmpty, "\(found) in the report:\n\(text)")
        #expect(text.contains("Permission denied"))
    }
}
