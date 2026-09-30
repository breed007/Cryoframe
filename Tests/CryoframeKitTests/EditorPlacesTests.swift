//
//  EditorPlacesTests.swift
//  CryoframeKitTests
//
//  Adding a destination or a folder to back up in the job editor: every rule when a
//  place is added, the path rules on every save (a library chosen after the
//  destinations included), and a destination whose drive is away never stops a save.
//

import Testing
import Foundation
@testable import CryoframeKit

private let now = Date(timeIntervalSince1970: 1_790_000_000)

private func scratch(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-places-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return TempTracker.track(d) }
    defer { free(real) }
    return TempTracker.track(URL(fileURLWithPath: String(cString: real), isDirectory: true))
}

private func make(_ url: URL) -> URL {
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func lib(_ url: URL) -> ContentType {
    .genericFolder(id: url.path, displayName: url.lastPathComponent, path: .absolute(url.path))
}

private func dest(_ url: URL) -> Target { .localVolume(id: url.path, name: url.lastPathComponent, dir: url) }

@Suite struct EditorPlacesTests {
    @Test func aDestinationInsideAChosenFolderIsRefusedAndNotAdded() {
        let base = scratch("inside")
        let papers = make(base.appendingPathComponent("Papers"))
        var d = JobDraftState(libraries: [], targets: [], now: now)
        d.addLibrary(lib(papers))
        let issues = d.addDestination(dest(make(papers.appendingPathComponent("Backups"))), volumes: FixedVolumeTable([]), systemRoots: [])
        #expect(issues.contains { $0.severity == .refusal })
        #expect(d.targets.isEmpty && d.selectedTargetIDs.isEmpty)
    }

    @Test func aWarningStillAddsTheDestinationAndIsSaid() {
        let base = scratch("warn")
        let papers = make(base.appendingPathComponent("Papers"))
        let backups = make(base.appendingPathComponent("Backups"))
        var d = JobDraftState(libraries: [], targets: [], now: now)
        d.addLibrary(lib(papers))
        let vol = MountedVolume(mountPoint: base, uuid: "ONE", name: "Disk")
        let issues = d.addDestination(dest(backups), volumes: FixedVolumeTable([vol]), systemRoots: [])
        #expect(issues.map(\.severity) == [.warning])
        #expect(d.selectedTargetIDs == [backups.path])
    }

    @Test func aFolderInsideADestinationIsRefusedAsASource() {
        let base = scratch("src")
        let backups = make(base.appendingPathComponent("Backups"))
        var d = JobDraftState(libraries: [], targets: [dest(backups)], now: now)
        let inner = make(backups.appendingPathComponent("Stuff"))
        let issues = d.addSource(lib(inner), at: inner, systemRoots: [])
        #expect(issues.contains { $0.severity == .refusal })
        #expect(d.libraries.isEmpty)
    }

    @Test func aLibraryChosenAfterTheDestinationsCantSlipThrough() {
        let base = scratch("late")
        let backups = make(base.appendingPathComponent("Backups"))
        let holder = lib(base)                                 // holds the destination
        var d = JobDraftState(libraries: [holder], targets: [dest(backups)], now: now)
        #expect(d.selectedTargetIDs == [backups.path])
        #expect(d.pathIssues().isEmpty)
        d.toggleLibrary(holder.id)                             // chosen from the list, not added
        #expect(!d.pathIssues().isEmpty)
        #expect(!d.isValid(existing: []))
    }

    @Test func aDestinationWhoseDriveIsAwayDoesNotStopASave() {
        let base = scratch("away")
        let papers = make(base.appendingPathComponent("Papers"))
        let away = URL(fileURLWithPath: "/Volumes/Not Here \(UUID().uuidString.prefix(6))/Backups")
        var d = JobDraftState(libraries: [lib(papers)], targets: [dest(away)], now: now)
        d.selectedLibraryIDs = [papers.path]
        #expect(d.pathIssues().isEmpty)
        #expect(d.isValid(existing: []))
    }

    @Test func checkStillRefusesWhatItDidBeforeTheSplit() {
        let base = scratch("same")
        let papers = make(base.appendingPathComponent("Papers"))
        let issues = DestinationRules.check(papers, sources: [papers], volumes: FixedVolumeTable([]), systemRoots: [])
        #expect(issues.first?.message.contains("is the folder being backed up") == true)
    }
}
