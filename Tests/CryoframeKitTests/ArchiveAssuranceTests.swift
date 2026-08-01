//
//  ArchiveAssuranceTests.swift
//  CryoframeKitTests
//
//  The restore timeline badges a version as verified. Getting this wrong means
//  telling someone an unchecked backup is proven — so these pin the conservative
//  rules: only versions actually checked count, a failed copy disqualifies the
//  version, and pre-1.4 records (which stored no per-version detail) claim nothing.
//

import Testing
import Foundation
@testable import CryoframeKit

private let v20 = VersionStamp.date("2026-07-20-020000")!
private let v21 = VersionStamp.date("2026-07-21-020000")!
private let v22 = VersionStamp.date("2026-07-22-020000")!

private func record(_ kind: String, at: Date, _ entries: [VerifiedArchive],
                    failures: [String] = []) -> HealthRecord {
    HealthRecord(jobID: "j1", jobName: "Nightly", checkedAt: at, archivesChecked: entries.count,
                 failures: failures, kind: kind, verified: entries)
}

@Test func verifiedOnlyForVersionsActuallyChecked() {
    // a latest-only run checks ONLY the newest version — the older ones are not proven.
    let recs = [record("checksum", at: v22, [VerifiedArchive(library: "Photos", version: v22, passed: true)])]

    #expect(ArchiveAssurance.lastVerified(library: "Photos", version: v22, in: recs)?.level == .checksum)
    #expect(ArchiveAssurance.lastVerified(library: "Photos", version: v21, in: recs) == nil)   // never checked
    #expect(ArchiveAssurance.lastVerified(library: "Photos", version: v20, in: recs) == nil)
    #expect(ArchiveAssurance.lastVerified(library: "Messages", version: v22, in: recs) == nil) // other library
}

@Test func drillOutranksChecksumEvenWhenOlder() {
    let recs = [
        record("checksum", at: v22, [VerifiedArchive(library: "Photos", version: v20, passed: true)]),
        record("drill",    at: v21, [VerifiedArchive(library: "Photos", version: v20, passed: true)]),
    ]
    let r = ArchiveAssurance.lastVerified(library: "Photos", version: v20, in: recs)
    #expect(r?.level == .drill)          // the stronger promise wins
    #expect(r?.checkedAt == v21)
}

@Test func newestWinsWithinTheSameLevel() {
    let recs = [
        record("checksum", at: v22, [VerifiedArchive(library: "Photos", version: v20, passed: true)]),
        record("checksum", at: v21, [VerifiedArchive(library: "Photos", version: v20, passed: true)]),
    ]
    #expect(ArchiveAssurance.lastVerified(library: "Photos", version: v20, in: recs)?.checkedAt == v22)
}

@Test func failedCheckIsNotVerified() {
    let recs = [record("checksum", at: v22, [VerifiedArchive(library: "Photos", version: v22, passed: false)],
                       failures: ["Photos (2026-07-22): checksum mismatch"])]
    #expect(ArchiveAssurance.lastVerified(library: "Photos", version: v22, in: recs) == nil)
}

@Test func oneBadCopyDisqualifiesTheVersion() {
    // multi-destination: the same version is checked once per copy. If the copy on
    // the drive you're restoring from is bad, the version must not read "verified".
    let recs = [record("checksum", at: v22, [
        VerifiedArchive(library: "Photos", version: v22, passed: true),    // NAS copy fine
        VerifiedArchive(library: "Photos", version: v22, passed: false),   // drive copy rotted
    ])]
    #expect(ArchiveAssurance.lastVerified(library: "Photos", version: v22, in: recs) == nil)
}

@Test func skippedCloudPlaceholderIsNotVerified() {
    // "not downloaded" is neither pass nor fail — it must not read as proven.
    let recs = [record("checksum", at: v22, [
        VerifiedArchive(library: "Photos", version: v22, passed: false, skipped: true)])]
    #expect(ArchiveAssurance.lastVerified(library: "Photos", version: v22, in: recs) == nil)
}

@Test func laterGoodCheckRedeemsAnEarlierFailure() {
    let recs = [
        record("drill",    at: v22, [VerifiedArchive(library: "Photos", version: v20, passed: true)]),
        record("checksum", at: v21, [VerifiedArchive(library: "Photos", version: v20, passed: false)]),
    ]
    #expect(ArchiveAssurance.lastVerified(library: "Photos", version: v20, in: recs)?.level == .drill)
}

@Test func mirrorVersionlessArchiveMatches() {
    let recs = [record("drill", at: v22, [VerifiedArchive(library: "Apple Music", version: nil, passed: true)])]
    #expect(ArchiveAssurance.lastVerified(library: "Apple Music", version: nil, in: recs)?.level == .drill)
    #expect(ArchiveAssurance.lastVerified(library: "Apple Music", version: v22, in: recs) == nil)
}

@Test func pre14RecordsClaimNothing() throws {
    // a record written before 1.4 has no `verified` array. It must decode (so history
    // still loads) and must NOT be treated as proof for any version.
    let legacy = """
    [{"id":"x","jobID":"j1","jobName":"Nightly","checkedAt":773020800,
      "archivesChecked":3,"failures":[],"kind":"drill","skipped":0}]
    """
    let recs = try JSONDecoder().decode([HealthRecord].self, from: Data(legacy.utf8))
    #expect(recs.count == 1)
    #expect(recs[0].verified.isEmpty)
    #expect(recs[0].passed)                                                    // still reads as a pass overall
    #expect(ArchiveAssurance.lastVerified(library: "Photos", version: v22, in: recs) == nil)
}

@Test func healthRecordCapturesPerVersionOutcomes() {
    // HealthRecord.from must carry the per-archive results through, including skips.
    let report = HealthReport(checks: [
        ArchiveCheck(library: "Photos", version: v22, passed: true, detail: "ok"),
        ArchiveCheck(library: "Photos", version: v21, passed: false, detail: "mismatch"),
        ArchiveCheck(library: "Music", version: nil, passed: true, detail: "skipped", skipped: true),
    ])
    let target = Target.localVolume(id: "t", name: "Backup", dir: URL(fileURLWithPath: "/Volumes/Backup"))
    let job = BackupJob(id: "j1", name: "Nightly", libraries: [], targets: [target], format: .sealedDMG,
                        frequency: .manual, verification: .checksumOnly, runPolicy: .proceed,
                        createdAt: v20)
    let rec = HealthRecord.from(job: job, report: report, at: v22, kind: "drill")

    #expect(rec.verified.count == 3)
    #expect(rec.verified.first { $0.version == v22 }?.passed == true)
    #expect(rec.verified.first { $0.version == v21 }?.passed == false)
    let music = rec.verified.first { $0.library == "Music" }
    #expect(music?.skipped == true && music?.passed == false)   // skipped never counts as passed
    #expect(rec.archivesChecked == 2)                            // skipped excluded from the count
}
