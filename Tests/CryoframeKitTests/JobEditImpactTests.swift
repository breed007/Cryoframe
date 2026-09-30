//
//  JobEditImpactTests.swift
//  CryoframeKitTests
//
//  What saving an edit does, said before the save (see JobEditImpact): only a Keep
//  rule that keeps fewer deletes anything, counted as retention itself counts;
//  everything else makes, renames or keeps. And a job's footprint.
//

import Testing
import Foundation
@testable import CryoframeKit

private let start = Date(timeIntervalSince1970: 1_790_000_000)
private let day: TimeInterval = 86_400

private func scratch(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-impact-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return TempTracker.track(d) }
    defer { free(real) }
    return TempTracker.track(URL(fileURLWithPath: String(cString: real), isDirectory: true))
}

private let papers = ContentType.genericFolder(id: "papers", displayName: "Papers", path: .absolute("/Users/me/Papers"))

private func job(_ dests: [URL], format: FormatChoice = .sealedZip, retention: RetentionPolicy = .keepLast(5),
                 libraries: [ContentType] = [papers]) -> BackupJob {
    BackupJob(id: "job-1", name: "Papers", libraries: libraries,
              targets: dests.map { Target.localVolume(id: $0.path, name: $0.lastPathComponent, dir: $0) },
              format: format, frequency: .manual, retention: retention, createdAt: start)
}

private func version(in dir: URL, _ date: Date) throws {
    let at = dir.appendingPathComponent(VersionStamp.string(date))
    try FileManager.default.createDirectory(at: at, withIntermediateDirectories: true)
    let f = at.appendingPathComponent("Papers.zip")
    try Data("zip \(date)".utf8).write(to: f)
    _ = try ArchiveManifest.write(try ArchiveManifest.build(for: ArchiveResult(artifacts: [f], format: .sealedZip)), toDir: at)
}

private func folder(_ j: BackupJob, in dest: URL) throws -> URL {
    try LibraryFolders.prepare(job: j, library: j.libraries[0], in: dest, jobs: [j], isOpen: { _ in false }).folder
}

@Suite struct JobEditImpactTests {
    @Test func aLowerKeepRuleSaysWhatTheNextBackupDeletesAndThatIsWhatGoes() throws {
        let dest = scratch("keep")
        let base = job([dest])
        let f = try folder(base, in: dest)
        for d in 0..<6 { try version(in: f, start.addingTimeInterval(Double(d) * day)) }
        var draft = base; draft.retention = .keepLast(2)
        let now = start.addingTimeInterval(30 * day)
        let impact = JobEditImpact.of(draft: draft, base: base, volumes: FixedVolumeTable([]), now: now)
        #expect(impact.deletes == 5)
        #expect(impact.lines.contains { $0.kind == .deletes && $0.text.contains("5 versions of Papers") })

        try version(in: f, now)                                                    // the next backup
        let before = LibraryFolders.versionNames(in: f).count
        JobExecutor.pruneVersions(folders: [(papers, f)], policy: draft.retention)
        #expect(before - LibraryFolders.versionNames(in: f).count == impact.deletes)
    }

    @Test func aHigherKeepRuleDeletesNothing() throws {
        let dest = scratch("more")
        let base = job([dest], retention: .keepLast(2))
        let f = try folder(base, in: dest)
        for d in 0..<3 { try version(in: f, start.addingTimeInterval(Double(d) * day)) }
        var draft = base; draft.retention = .keepLast(10)
        let impact = JobEditImpact.of(draft: draft, base: base, volumes: FixedVolumeTable([]), now: start.addingTimeInterval(9 * day))
        #expect(impact.deletes == 0)
        #expect(!impact.lines.contains { $0.kind == .deletes })
    }

    @Test func takingOutADestinationOrALibraryDeletesNothing() throws {
        let a = scratch("a"), b = scratch("b")
        let notes = ContentType.genericFolder(id: "notes", displayName: "Notes", path: .absolute("/Users/me/Notes"))
        let base = job([a, b], libraries: [papers, notes])
        let draft = job([a], libraries: [papers])
        let impact = JobEditImpact.of(draft: draft, base: base, volumes: FixedVolumeTable([]))
        #expect(impact.deletes == 0)
        #expect(impact.lines.filter { $0.kind == .keeps }.count == 2)
        #expect(impact.lines.allSatisfy { $0.kind != .deletes })
    }

    @Test func aRenameSaysWhichFolderIsRenamedAndWhen() throws {
        let dest = scratch("rename")
        let base = job([dest])
        let f = try folder(base, in: dest)
        var draft = base; draft.libraries[0].rename(to: "Research")
        var impact = JobEditImpact.of(draft: draft, base: base, volumes: FixedVolumeTable([]))
        #expect(impact.lines.contains { $0.kind == .renames && $0.text.contains("“Papers” is renamed “Research” at the next backup") })
        let p = PendingTransfer(jobID: "job-1:x:papers", sourceFile: "/s", baseName: "b", totalBytes: 1, chunkSize: 1,
                                targetDir: f.appendingPathComponent("2026-09-30-020000").path, format: .sealedZip)
        impact = JobEditImpact.of(draft: draft, base: base, volumes: FixedVolumeTable([]), pending: [p])
        #expect(impact.lines.contains { $0.text.contains("once its interrupted upload has finished") })
        // a destination whose drive is away
        var away = base
        away.targets[0] = Target.externalDrive(id: "t7", name: "Backups on T7", dir: URL(fileURLWithPath: "/Volumes/Gone/Backups"))
        away.targets[0].volume = VolumeIdentity(uuid: "GONE", name: "Gone", relativePath: "Backups")
        var awayDraft = away; awayDraft.libraries[0].rename(to: "Research")
        impact = JobEditImpact.of(draft: awayDraft, base: away, volumes: FixedVolumeTable([]))
        #expect(impact.lines.contains { $0.kind == .renames && $0.text.contains("the next time it's connected") })
    }

    @Test func aFormatChangeKeepsWhatTheOtherFormatMade() throws {
        let dest = scratch("format")
        let base = job([dest])
        let f = try folder(base, in: dest)
        try version(in: f, start)
        var draft = base; draft.format = .liveMirror(sizeGB: 1); draft.retention = .keepAll
        let impact = JobEditImpact.of(draft: draft, base: base, volumes: FixedVolumeTable([]))
        #expect(impact.lines.contains { $0.kind == .keeps && $0.text.contains("1 dated version of Papers stay, marked kept") })
        #expect(impact.deletes == 0)
    }

    @Test func aNewDestinationSaysWhatItMakes() throws {
        let a = scratch("old"), b = scratch("new")
        let base = job([a])
        let impact = JobEditImpact.of(draft: job([a, b]), base: base, volumes: FixedVolumeTable([]))
        #expect(impact.lines.contains { $0.kind == .creates && $0.text.contains("creates") })
    }

    @Test func theFootprintCountsWhatEachFolderHolds() throws {
        let dest = scratch("footprint")
        let j = job([dest])
        let f = try folder(j, in: dest)
        for d in 0..<3 { try version(in: f, start.addingTimeInterval(Double(d) * day)) }
        let fp = JobFootprint.measure(j, volumes: FixedVolumeTable([]))
        #expect(fp.places.count == 1)
        #expect(fp.places[0].folders.map(\.versions) == [3])
        #expect(fp.places[0].bytes > 0)
        #expect(fp.places[0].folders[0].kept.isEmpty)
    }
}
