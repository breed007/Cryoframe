//
//  LibraryRenameTests.swift
//  CryoframeKitTests
//
//  Renaming a library in one job: the name is the job's (a built-in keeps it at
//  every run), the job remembers the names it had, and its folders follow at the
//  next run that reaches them, except one an interrupted transfer still writes
//  into. A drive that was away during the rename is still recognized by the old name.
//

import Testing
import Foundation
@testable import CryoframeKit

private let start = Date(timeIntervalSince1970: 1_790_000_000)

private func scratch(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-rename-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return TempTracker.track(d) }
    defer { free(real) }
    return TempTracker.track(URL(fileURLWithPath: String(cString: real), isDirectory: true))
}

private let papers = ContentType.genericFolder(id: "papers", displayName: "Papers", path: .absolute("/nowhere/Papers"))

private func job(_ lib: ContentType, dest: URL, format: FormatChoice = .sealedZip) -> BackupJob {
    BackupJob(id: "job-1", name: "Job", libraries: [lib], target: .localVolume(id: "d", name: "Dest", dir: dest),
              format: format, frequency: .manual, retention: .keepLast(5), createdAt: start)
}

/// a sealed version with a manifest in `folder`
@discardableResult
private func version(in folder: URL, _ stamp: String = "2026-09-01-020000") throws -> URL {
    let v = folder.appendingPathComponent(stamp)
    try FileManager.default.createDirectory(at: v, withIntermediateDirectories: true)
    try Data("zip".utf8).write(to: v.appendingPathComponent("Papers.zip"))
    _ = try ArchiveManifest.write(try ArchiveManifest.build(for: ArchiveResult(artifacts: [v.appendingPathComponent("Papers.zip")],
                                                                               format: .sealedZip)), toDir: v)
    return v
}

private func renamed(_ lib: ContentType, _ name: String) -> ContentType {
    var l = lib; l.rename(to: name); return l
}

private func names(_ dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
}

@Suite struct LibraryRenameTests {
    @Test func aRenameRemembersTheNamesItHad() {
        var l = papers
        let ok = l.rename(to: "  Research  ")
        #expect(ok)
        #expect(l.displayName == "Research" && l.formerNames == ["Papers"])
        #expect(l.answers(to: "papers") && l.answers(to: "Research"))
        l.rename(to: "Papers")                                     // back again
        #expect(l.displayName == "Papers" && l.formerNames == ["Research"])
        let empty = l.rename(to: "   ")
        #expect(!empty)
        #expect(l.displayName == "Papers")
    }

    @Test func theDraftRenamesOneLibraryOfThisJob() {
        var d = JobDraftState(libraries: [.photos], targets: [], now: start)
        let ok = d.renameLibrary(ContentType.photos.id, to: "Family photos")
        #expect(ok)
        #expect(d.libraries.first?.displayName == "Family photos")
        let none = d.renameLibrary("no-such-library", to: "X")
        #expect(!none)
        #expect(ContentType.photos.displayName == "Photos")        // the built-in itself is untouched
    }

    @Test func aRenamedBuiltInKeepsItsNameAtEveryRun() {
        let mine = renamed(.photos, "Family photos")
        let j = BackupJob(name: "J", libraries: [mine], target: .localVolume(id: "d", name: "D", dir: URL(fileURLWithPath: "/tmp/d")),
                          format: .sealedZip, frequency: .manual, createdAt: start)
        let moved = LibraryPath.absolute("/Volumes/Media/Photos Library.photoslibrary")
        let run = j.resolvingLibraries(in: .withOverrides([ContentType.photos.id: moved]))
        #expect(run.libraries[0].displayName == "Family photos")
        #expect(run.libraries[0].formerNames == ["Photos"])
        #expect(run.libraries[0].paths == [moved])                          // the folder is still the app's
        #expect(run.libraries[0].integrityProbe == ContentType.photos.integrityProbe)
    }

    @Test func theFolderFollowsAtTheNextRun() throws {
        let dest = scratch("follow")
        let before = try LibraryFolders.prepare(job: job(papers, dest: dest), library: papers, in: dest, jobs: [], isOpen: { _ in false }).folder
        try version(in: before)
        let r = renamed(papers, "Research")
        let after = try LibraryFolders.prepare(job: job(r, dest: dest), library: r, in: dest, jobs: [], isOpen: { _ in false }).folder
        #expect(after.lastPathComponent == "Research")
        #expect(names(dest) == ["Research"])
        #expect(LibraryIdentity.read(in: after)?.name == "Research")
        #expect(LibraryIdentity.read(in: after)?.formerNames == ["Papers"])
        #expect(names(after) == ["2026-09-01-020000"])
    }

    @Test func aFolderAnInterruptedTransferWritesIntoKeepsItsNameUntilItsDone() throws {
        let dest = scratch("pending")
        let before = try LibraryFolders.prepare(job: job(papers, dest: dest), library: papers, in: dest, jobs: [], isOpen: { _ in false }).folder
        let partial = before.appendingPathComponent("2026-09-30-020000")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        let r = renamed(papers, "Research")
        let kept = try LibraryFolders.prepare(job: job(r, dest: dest), library: r, in: dest, jobs: [], isOpen: { _ in false },
                                              transferring: { DestinationRules.contains($0, partial) }).folder
        #expect(kept.lastPathComponent == "Papers")
        #expect(FileManager.default.fileExists(atPath: partial.path))
        let done = try LibraryFolders.prepare(job: job(r, dest: dest), library: r, in: dest, jobs: [], isOpen: { _ in false }).folder
        #expect(done.lastPathComponent == "Research")
    }

    @Test func the15FolderOnADriveThatWasAwayIsStillTakenOver() throws {
        let dest = scratch("away")
        let legacy = dest.appendingPathComponent("Papers")                 // what 1.5 wrote there
        try version(in: legacy)
        let r = renamed(papers, "Research")
        let j = job(r, dest: dest)
        #expect(LibraryFolders.archives(job: j, library: r, in: dest).count == 1)   // read before any run
        let folder = try LibraryFolders.prepare(job: j, library: r, in: dest, jobs: [j], isOpen: { _ in false }).folder
        #expect(LibraryIdentity.read(in: folder)?.key == LibraryIdentity.key(job: j, library: r))
        #expect(folder.lastPathComponent == "Research")
        #expect(names(dest) == ["Research"])
        #expect(names(folder) == ["2026-09-01-020000"])                   // nothing lost, nothing new
    }

    @Test func theRunRecordsItsFoldersUnderAnyNameForEvidence() throws {
        let dest = scratch("evidence")
        let legacy = dest.appendingPathComponent("Papers")
        let v = try version(in: legacy, "2026-09-01-020000")
        let r = renamed(papers, "Research")
        let j = job(r, dest: dest)
        let bytes = RestoreDiscovery.archive(at: v)?.bytes ?? 0
        let made = try #require(VersionStamp.date("2026-09-01-020000"))
        let run = RunRecord(id: "r", jobID: j.id, jobName: "Job", startedAt: made, finishedAt: made, trigger: "scheduled",
                            outcome: .completed, summary: "",
                            libraries: [LibraryOutcome(from: .completed(library: "Papers", destination: "Dest", parts: 1, bytes: bytes, verified: nil))],
                            bytes: bytes, warning: nil)
        #expect(LibraryFolders.holdsBackups(of: j, in: dest, runs: [run]))
    }

    @Test func aRehearsalFindsALibraryUnderTheNameItsFolderStillHas() throws {
        let dest = scratch("rehearse")
        let folder = try LibraryFolders.prepare(job: job(papers, dest: dest), library: papers, in: dest, jobs: [], isOpen: { _ in false }).folder
        try version(in: folder)
        let report = RecoveryRehearsal().rehearse(destination: dest, expecting: ["Research"], alsoKnownAs: ["Research": ["Papers"]])
        #expect(report.missing.isEmpty)
        #expect(RecoveryRehearsal().rehearse(destination: dest, expecting: ["Research"]).missing == ["Research"])
    }
}
