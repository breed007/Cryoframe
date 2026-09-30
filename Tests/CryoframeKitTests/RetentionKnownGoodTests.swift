//
//  RetentionKnownGoodTests.swift
//  CryoframeKitTests
//
//  Retention never deletes the version last known to restore. A policy counts
//  versions; it doesn't know which of them pass their drills, and a week of failing
//  ones would otherwise prune away the last one that did.
//

import Testing
import Foundation
@testable import CryoframeKit

private let cal = Calendar(identifier: .gregorian)
private func day(_ d: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 9, day: d, hour: 2))! }

/// a check of one library's versions: `passed` and `failed` by day
private func check(_ kind: String, library: String = "Photos", passed: [Int] = [], failed: [Int] = [], at d: Int) -> HealthRecord {
    let verified = passed.map { VerifiedArchive(library: library, version: day($0), passed: true) }
        + failed.map { VerifiedArchive(library: library, version: day($0), passed: false) }
    return HealthRecord(jobID: "j", jobName: "Job", checkedAt: day(d).addingTimeInterval(3600),
                        archivesChecked: verified.count, failures: failed.map { "Photos (\($0)): drill failed" },
                        kind: kind, verified: verified)
}

@Suite struct RetentionKnownGoodTests {
    // Day 1's version passed its drill; every version since failed one. Keep the last
    // three, and day 1's goes too, leaving three that don't restore.
    @Test func aWeekOfFailingDrillsDoesNotPruneTheLastGoodVersion() {
        let versions = (1...10).map(day)
        let records = (2...10).reversed().map { check("drill", failed: [$0], at: $0) } + [check("drill", passed: [1], at: 1)]
        let known = KnownGood.version(of: "Photos", among: versions, records: records)
        #expect(known == day(1))
        let doomed = retentionPrune(versions, policy: .keepLast(3), keeping: Set([known].compactMap { $0 }))
        #expect(!doomed.contains(day(1)))
        #expect(doomed == Set((2...7).map(day)))
        // the same under grandfather-father-son: one daily, no weeklies or monthlies
        let gfs = retentionPrune(versions, policy: .gfs(daily: 2, weekly: 0, monthly: 0), keeping: [day(1)])
        #expect(!gfs.contains(day(1)))
        #expect(gfs.contains(day(2)))
    }

    // A drill is the stronger promise: the newest drilled version is kept even when a
    // newer one only passed a checksum check. With no drill at all, the newest
    // checksum-verified version. Nothing checked, or only failures: nothing to keep.
    @Test func theKnownGoodVersionIsTheNewestDrilledElseTheNewestVerified() {
        let versions = (1...6).map(day)
        let mixed = [check("checksum", passed: [5], at: 5), check("drill", passed: [3], at: 3), check("checksum", passed: [4], at: 4)]
        #expect(KnownGood.version(of: "Photos", among: versions, records: mixed) == day(3))
        let checksumsOnly = [check("checksum", passed: [4], at: 4), check("checksum", passed: [2], at: 2)]
        #expect(KnownGood.version(of: "Photos", among: versions, records: checksumsOnly) == day(4))
        #expect(KnownGood.version(of: "Photos", among: versions, records: []) == nil)
        #expect(KnownGood.version(of: "Photos", among: versions, records: [check("drill", failed: [6, 5], at: 6)]) == nil)
        // another library's checks don't count
        #expect(KnownGood.version(of: "Music", among: versions, records: mixed) == nil)
        // nor does a version that has since been pruned
        #expect(KnownGood.version(of: "Photos", among: [day(5), day(6)], records: [check("drill", passed: [3], at: 3)]) == nil)
    }

    // On disk, through the run's own pruning.
    @Test func pruningAVersionFolderKeepsTheLastGoodOne() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("cf-kg-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let name = ContentType.photos.displayName
        let lib = base.appendingPathComponent(name)
        for d in 1...8 {
            let v = lib.appendingPathComponent(VersionStamp.string(day(d)))
            try fm.createDirectory(at: v, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: v.appendingPathComponent(ArchiveManifest.sidecarName))
        }
        let checks = [check("drill", library: name, failed: [8, 7, 6, 5], at: 8), check("drill", library: name, passed: [2], at: 2)]
        let failures = JobExecutor.pruneVersions(target: base, libraries: [.photos], policy: .keepLast(2), checks: checks)
        #expect(failures.isEmpty)
        let left = try fm.contentsOfDirectory(atPath: lib.path).sorted()
        #expect(left == [2, 7, 8].map { VersionStamp.string(day($0)) })
    }

    // Two libraries of one name in one job ("Projects" from Work and from Home), and a
    // library renamed: a check that recorded whose archive it was counts only for that
    // library, whatever either is called; one from before 1.6 counts by the name the
    // library had.
    @Test func checksCountForTheLibraryTheyWereOfNotItsName() {
        let versions = (1...3).map(day)
        let work = HealthRecord(jobID: "j", jobName: "Job", checkedAt: day(2).addingTimeInterval(3600), archivesChecked: 1,
                                failures: [], kind: "drill",
                                verified: [VerifiedArchive(library: "Projects", version: day(2), passed: true, key: "j/work")])
        #expect(KnownGood.version(of: "Projects", key: "j/work", among: versions, records: [work]) == day(2))
        #expect(KnownGood.version(of: "Projects", key: "j/home", among: versions, records: [work]) == nil,
                "the other Projects' drill was taken for this one's")
        #expect(KnownGood.version(of: "Client Work", key: "j/work", among: versions, records: [work]) == day(2), "lost with a rename")
        let old = check("drill", library: "Projects", passed: [1], at: 1)
        #expect(KnownGood.version(of: "Client Work", key: "j/work", formerNames: ["Projects"], among: versions, records: [old]) == day(1))
        #expect(KnownGood.version(of: "Client Work", key: "j/work", among: versions, records: [old]) == nil)
    }

    // A folder's identity remembers the names its library had, for those older checks.
    @Test func aFoldersIdentityRemembersTheLibrarysFormerNames() {
        let first = LibraryIdentity(jobID: "j", libraryID: "p", name: "Projects", jobName: "Job")
        let second = LibraryIdentity(jobID: "j", libraryID: "p", name: "Client Work", jobName: "Job").following(first)
        #expect(second.formerNames == ["Projects"])
        let back = LibraryIdentity(jobID: "j", libraryID: "p", name: "Projects", jobName: "Job").following(second)
        #expect(back.formerNames == ["Client Work"])
        #expect(LibraryIdentity(jobID: "x", libraryID: "p", name: "Other", jobName: "X").following(first).formerNames == nil)
    }
}
