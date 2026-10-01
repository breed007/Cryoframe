//
//  KeptKnownGoodWordingTests.swift
//  CryoframeKitTests
//
//  What a card says about adopted versions under Keep last when one of them is the
//  last known to restore: retention keeps that one until a newer one is proven, so
//  the card doesn't count it among those deleted one at a time.
//

import Testing
import Foundation
@testable import CryoframeKit

@Suite struct KeptKnownGoodWordingTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let day: TimeInterval = 86_400
    private let papers = ContentType.genericFolder(id: "papers", displayName: "Papers", path: .absolute("/Users/me/Papers"))

    private func scratch() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-keptgood-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        guard let real = realpath(d.path, nil) else { return TempTracker.track(d) }
        defer { free(real) }
        return TempTracker.track(URL(fileURLWithPath: String(cString: real), isDirectory: true))
    }

    private func version(in dir: URL, _ date: Date) throws {
        let at = dir.appendingPathComponent(VersionStamp.string(date))
        try FileManager.default.createDirectory(at: at, withIntermediateDirectories: true)
        let f = at.appendingPathComponent("Papers.zip")
        try Data("zip \(date)".utf8).write(to: f)
        _ = try ArchiveManifest.write(try ArchiveManifest.build(for: ArchiveResult(artifacts: [f], format: .sealedZip)), toDir: at)
    }

    /// the card for two versions a 1.5 folder held, under Keep last 4, with `checks`
    private func card(checks: (_ older: Date, _ newer: Date) -> [HealthRecord]) throws -> AdoptionReview {
        let dest = scratch()
        let legacy = dest.appendingPathComponent("Papers", isDirectory: true)
        let older = start, newer = start.addingTimeInterval(day)
        for d in [older, newer] {
            try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
            try version(in: legacy, d)
        }
        let job = BackupJob(id: "job-1", name: "Papers", libraries: [papers],
                            targets: [Target.localVolume(id: dest.path, name: "dest", dir: dest)],
                            format: .sealedZip, frequency: .manual, retention: .keepLast(4), createdAt: start)
        let folder = try LibraryFolders.prepare(job: job, library: papers, in: dest, jobs: [job], isOpen: { _ in false }).folder
        let reviews = JobExecutor.adoptionReviews(job, [dest.path: [papers.id: folder]], checks: checks(older, newer),
                                                  transferring: { _ in false }, confirmed: { _, _ in false },
                                                  now: start.addingTimeInterval(10 * day))
        return try #require(reviews.first)
    }

    @Test func withNothingProvenAllAreSaidToGoInTurn() throws {
        let c = try card { _, _ in [] }
        #expect(c.effect == "Keep last 4 then applies to them: none of them are deleted at the next backup; all 2 are deleted one at a time as new backups are made.",
                "\(c.effect)")
    }

    @Test func theOneProvenByADrillIsSaidToStay() throws {
        let c = try card { _, newer in
            [HealthRecord(jobID: "job-1", jobName: "Papers", checkedAt: newer.addingTimeInterval(3600), archivesChecked: 1,
                          failures: [], kind: "drill", verified: [VerifiedArchive(library: "Papers", version: newer, passed: true)])]
        }
        #expect(c.keptKnownGood == 1)
        #expect(c.allows.count == 2, "a yes still lets it go once a newer one is proven")
        #expect(c.effect == "Keep last 4 then applies to them: none of them are deleted at the next backup; 1 is deleted one at a time as new backups are made; the one last proven to restore stays until a newer one is proven.",
                "\(c.effect)")
        #expect(!c.effect.contains("all 2"))
    }
}
