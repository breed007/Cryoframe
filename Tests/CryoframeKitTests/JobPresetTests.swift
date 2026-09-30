//
//  JobPresetTests.swift
//  CryoframeKitTests
//
//  Quick start for a new job, and the note on room at the main destination (see
//  JobPreset): one click sets the choices, each stays editable, and a job that may
//  not fit is said to, never refused.
//

import Testing
import Foundation
@testable import CryoframeKit

private let start = Date(timeIntervalSince1970: 1_790_000_000)

private func draft() -> JobDraftState {
    let t = Target.localVolume(id: "t", name: "T7", dir: URL(fileURLWithPath: "/Volumes/T7/Backups"))
    return JobDraftState(libraries: [.photos, .appleMusic], targets: [t], now: start)
}

@Suite struct JobPresetTests {
    @Test func aPresetSetsTheChoicesAndIsShownAsChosen() throws {
        var d = draft()
        let photos = try #require(JobPreset.all.first { $0.id == "photos-nightly" })
        d.apply(photos, now: start)
        #expect(d.selectedLibraryIDs == [ContentType.photos.id])
        #expect(d.formatKind == "dmg" && d.verification == .mountAndOpen && d.retentionPolicy == .keepLast(14))
        #expect(d.freqKind == .daily)
        #expect(d.matches(photos))
        #expect(d.isValid(existing: []))

        let music = try #require(JobPreset.all.first { $0.id == "music-copy" })
        d.apply(music, now: start)
        #expect(d.selectedLibraryIDs == [ContentType.appleMusic.id] && !d.isSealed && !d.matches(photos))

        let scratch = try #require(JobPreset.all.first { $0.libraryIDs.isEmpty })
        d.apply(scratch, now: start)
        #expect(d.selectedLibraryIDs.isEmpty && d.matches(scratch))
    }

    @Test func aPresetKeepsTheDestinationsTheNameAndEncryption() throws {
        var d = draft()
        d.name = "Mine"; d.encrypt = true
        d.apply(try #require(JobPreset.all.first { $0.id == "photos-music" }), now: start)
        #expect(d.name == "Mine" && d.encrypt && d.selectedTargetIDs == ["t"])
        #expect(d.selectedLibraryIDs == [ContentType.photos.id, ContentType.appleMusic.id])
    }

    @Test func mayNotFitIsSaidNotRefused() throws {
        var d = draft()
        d.selectedLibraryIDs = [ContentType.photos.id, ContentType.appleMusic.id]
        #expect(d.roomNote(sizes: [:], free: 1_000) == nil)
        let tight = try #require(d.roomNote(sizes: [ContentType.photos.id: 5_000_000_000], free: 1_000_000_000))
        #expect(tight.mayNotFit && tight.advice == "This may not fit on the main destination.")
        #expect(tight.line.contains("+"))                                    // Music's size isn't known yet
        #expect(d.isValid(existing: []))
        let room = try #require(d.roomNote(sizes: [ContentType.photos.id: 1_000, ContentType.appleMusic.id: 1_000], free: 1_000_000))
        #expect(!room.mayNotFit && !room.line.contains("+"))
    }
}
