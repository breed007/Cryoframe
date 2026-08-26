//
//  StoragePressureTests.swift
//  CryoframeKitTests
//
//  A full destination doesn't slow backups down, it ends them — so the warning has
//  to arrive while there is still room to act, and the number it quotes has to be
//  the number pruning actually gives back.
//

import Testing
import Foundation
@testable import CryoframeKit

private func day(_ d: Int) -> Date { VersionStamp.date("2026-07-\(String(format: "%02d", d))-020000")! }

private func sizes(_ library: String, days: [Int], bytes: UInt64) -> [ArchiveSize] {
    days.map { ArchiveSize(library: library, version: day($0), bytes: bytes) }
}

private func storage(_ archives: [ArchiveSize], free: UInt64, job: String = "j") -> JobStorage {
    JobStorage(jobID: job, jobName: "Photos nightly", targetName: "Backup SSD", targetPath: "/Volumes/Backup",
               archiveBytes: archives.reduce(0) { $0 + $1.bytes }, versionCount: archives.count,
               archives: archives, volumeFree: free, volumeTotal: 1_000_000_000_000)
}

// MARK: - running out

@Test func warnsWhenTheNextRunWouldNotFit() {
    // 10 GB per run, 6 GB free — tonight fails. Say so tonight, not tomorrow.
    let s = storage(sizes("Photos", days: [20, 21, 22], bytes: 10_000_000_000), free: 6_000_000_000)
    let f = StoragePressure.findings(storage: [s], retention: ["j": .keepLast(14)])
    #expect(f.count == 1)
    #expect(f.first?.kind == .tight)
    #expect(f.first?.runBytes == 10_000_000_000)
}

@Test func plentyOfRoomIsNotAWarning() {
    let s = storage(sizes("Photos", days: [20, 21], bytes: 10_000_000_000), free: 800_000_000_000)
    #expect(StoragePressure.findings(storage: [s], retention: ["j": .keepLast(14)]).isEmpty)
}

@Test func spaceIsJudgedAgainstTheNextRunNotAPercentage() {
    // the same 40 GB free is fine for a small job and hopeless for a big one, which a
    // percentage of the volume could never express.
    let small = storage(sizes("Notes", days: [20], bytes: 1_000_000_000), free: 40_000_000_000)
    let big = storage(sizes("Video", days: [20], bytes: 90_000_000_000), free: 40_000_000_000, job: "k")
    #expect(StoragePressure.findings(storage: [small], retention: [:]).isEmpty)
    #expect(StoragePressure.findings(storage: [big], retention: [:]).first?.kind == .tight)
}

// MARK: - growing forever

@Test func flagsAJobThatKeepsEveryVersion() {
    let s = storage(sizes("Photos", days: Array(20...31), bytes: 1_000_000_000), free: 500_000_000_000)
    let f = StoragePressure.findings(storage: [s], retention: ["j": .keepAll])
    #expect(f.first?.kind == .unbounded)
    #expect(f.first?.versionCount == 12)
    #expect(f.first?.reclaimable == 5_000_000_000)   // 12 versions, keep 7, drop 5
}

@Test func aBoundedJobIsNotFlaggedNoMatterHowManyVersions() {
    let s = storage(sizes("Photos", days: Array(20...31), bytes: 1_000_000_000), free: 500_000_000_000)
    #expect(StoragePressure.findings(storage: [s], retention: ["j": .keepLast(14)]).isEmpty)
    #expect(StoragePressure.findings(storage: [s], retention: ["j": .gfs(daily: 7, weekly: 4, monthly: 6)]).isEmpty)
}

@Test func keepAllIsQuietUntilThereIsSomethingToReclaim() {
    // three versions and a suggestion to keep seven would free nothing — nagging.
    let s = storage(sizes("Photos", days: [20, 21, 22], bytes: 1_000_000_000), free: 500_000_000_000)
    #expect(StoragePressure.findings(storage: [s], retention: ["j": .keepAll]).isEmpty)
}

// MARK: - the number has to be true

@Test func reclaimableMatchesWhatPruningActuallyDeletes() {
    // computed with the same rule the engine prunes by, so the figure quoted in a
    // warning is the figure you get back.
    let archives = sizes("Photos", days: Array(20...29), bytes: 2_000_000_000)
    #expect(StoragePressure.reclaimable(archives, keeping: .keepLast(4)) == 12_000_000_000)  // drop 6
    #expect(StoragePressure.reclaimable(archives, keeping: .keepLast(10)) == 0)
    #expect(StoragePressure.reclaimable(archives, keeping: .keepAll) == 0)
}

@Test func reclaimableCountsEachLibrarySeparately() {
    // retention is per library, so two libraries each keep their own recent versions.
    let both = sizes("Photos", days: Array(20...25), bytes: 1_000_000_000)
             + sizes("Music", days: Array(20...25), bytes: 500_000_000)
    #expect(StoragePressure.reclaimable(both, keeping: .keepLast(4)) == 3_000_000_000)  // 2×1GB + 2×0.5GB
}

@Test func aRunIsSizedByTheNewestVersionOfEachLibrary() {
    // libraries grow; last night is a better guide to tonight than an old average.
    let archives = [ArchiveSize(library: "Photos", version: day(20), bytes: 1_000_000_000),
                    ArchiveSize(library: "Photos", version: day(25), bytes: 4_000_000_000),
                    ArchiveSize(library: "Music", version: day(25), bytes: 500_000_000)]
    #expect(StoragePressure.typicalRunBytes(archives) == 4_500_000_000)
}

@Test func aDestinationWeCannotMeasureIsNotGuessedAbout() {
    let s = JobStorage(jobID: "j", jobName: "n", targetName: "NAS", targetPath: "/x",
                       archiveBytes: 0, versionCount: 3, archives: [], volumeFree: nil, volumeTotal: nil)
    #expect(StoragePressure.findings(storage: [s], retention: ["j": .keepAll]).isEmpty)
}

// MARK: - what reaches your phone

@Test func runningOutOfRoomIsWorthAnAlert() {
    let f = StoragePressure.Finding(kind: .tight, jobID: "j", jobName: "Photos nightly",
                                    destination: "Backup SSD", free: 6_000_000_000,
                                    runBytes: 10_000_000_000, versionCount: 3, reclaimable: 0)
    let p = AlertPolicy.payload(forStorage: f)
    #expect(p?.high == true)
    #expect(p?.title.contains("Backup SSD") == true)
    #expect(p?.body.contains("likely to fail") == true)
}

@Test func keepingEveryVersionIsNotWorthWakingSomeoneUp() {
    // worth showing in the app, not worth a notification: nothing is broken yet.
    let f = StoragePressure.Finding(kind: .unbounded, jobID: "j", jobName: "Photos nightly",
                                    destination: "Backup SSD", free: 500_000_000_000,
                                    runBytes: 1_000_000_000, versionCount: 40, reclaimable: 30_000_000_000)
    #expect(AlertPolicy.payload(forStorage: f) == nil)
}
