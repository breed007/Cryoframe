//
//  CoverageAdvisorTests.swift
//  CryoframeKitTests
//
//  The advisor's job is to notice what isn't protected without becoming a nag.
//  These pin both halves: it finds a real gap, and it stays quiet about libraries
//  that are covered, absent, or already waved off.
//

import Testing
import Foundation
@testable import CryoframeKit

private let photos = ContentType.photos
private let music = ContentType.appleMusic
private let garageBand = ContentType.garageBand

/// pretend every type exists on disk.
private func allPresent(_ t: ContentType) -> URL? { URL(fileURLWithPath: "/Users/x/\(t.displayName)") }

/// a job needs at least one destination — BackupJob's init enforces it.
private let someTarget = Target.localVolume(id: "t", name: "Backup", dir: URL(fileURLWithPath: "/Volumes/Backup"))

private func job(_ name: String, _ libs: [ContentType], enabled: Bool = true) -> BackupJob {
    BackupJob(id: name, name: name, libraries: libs, targets: [someTarget], format: .sealedDMG,
              frequency: .manual, verification: .checksumOnly, runPolicy: .proceed,
              enabled: enabled, createdAt: Date(timeIntervalSince1970: 0))
}

@Test func findsLibrariesNoJobCovers() {
    let gaps = CoverageAdvisor.gaps(types: [photos, music, garageBand],
                                    jobs: [job("Photos nightly", [photos])],
                                    resolve: allPresent)
    #expect(gaps.map(\.typeID) == [music.id, garageBand.id])
    #expect(gaps.first?.displayName == music.displayName)
}

@Test func silentWhenEverythingIsCovered() {
    let gaps = CoverageAdvisor.gaps(types: [photos, music],
                                    jobs: [job("Everything", [photos, music])],
                                    resolve: allPresent)
    #expect(gaps.isEmpty)
}

@Test func aLibraryCoveredByAnyJobCounts() {
    // spread across two jobs — still covered.
    let gaps = CoverageAdvisor.gaps(types: [photos, music],
                                    jobs: [job("A", [photos]), job("B", [music])],
                                    resolve: allPresent)
    #expect(gaps.isEmpty)
}

@Test func disabledJobStillCountsAsCoverage() {
    // pausing a schedule is a deliberate choice, not an oversight — don't prod.
    let gaps = CoverageAdvisor.gaps(types: [photos],
                                    jobs: [job("Paused", [photos], enabled: false)],
                                    resolve: allPresent)
    #expect(gaps.isEmpty)
}

@Test func librariesNotOnThisMacAreNotGaps() {
    // no GarageBand installed → nothing to protect, nothing to say.
    let gaps = CoverageAdvisor.gaps(types: [photos, garageBand], jobs: [],
                                    resolve: { $0.id == garageBand.id ? nil : URL(fileURLWithPath: "/x") })
    #expect(gaps.map(\.typeID) == [photos.id])
}

@Test func dismissedLibrariesStayDismissed() {
    let gaps = CoverageAdvisor.gaps(types: [photos, music, garageBand], jobs: [],
                                    dismissed: [music.id, garageBand.id],
                                    resolve: allPresent)
    #expect(gaps.map(\.typeID) == [photos.id])
}

@Test func dismissingEveryGapSilencesTheAdvisor() {
    let gaps = CoverageAdvisor.gaps(types: [photos, music], jobs: [],
                                    dismissed: [photos.id, music.id], resolve: allPresent)
    #expect(gaps.isEmpty)
}

@Test func gapsKeepRegistryOrderSoPhotosLeads() {
    let gaps = CoverageAdvisor.gaps(types: ContentTypeRegistry.builtIns, jobs: [], resolve: allPresent)
    #expect(gaps.first?.typeID == ContentType.photos.id)
    #expect(gaps.count == ContentTypeRegistry.builtIns.count)
}

@Test func gapCarriesTheRootToBackUp() {
    let root = URL(fileURLWithPath: "/Users/x/Pictures/Photos Library.photoslibrary")
    let gaps = CoverageAdvisor.gaps(types: [photos], jobs: [], resolve: { _ in root })
    #expect(gaps.first?.root == root)
}

@Test func noJobsAndNoLibrariesIsQuiet() {
    #expect(CoverageAdvisor.gaps(types: [], jobs: [], resolve: allPresent).isEmpty)
}
