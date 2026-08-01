//
//  RecoveryPlanTests.swift
//  CryoframeKitTests
//
//  "Rebuild this Mac as it was on <date>" is only trustworthy if each library
//  contributes the version that actually existed then. These pin that: never a
//  version from after the chosen moment (that would rebuild a Mac that never
//  existed), and an honest flag when a library is too young to have one.
//

import Testing
import Foundation
@testable import CryoframeKit

private func stub(_ library: String, _ version: Date?, bytes: UInt64 = 1000,
                  format: ArchiveFormat = .sealedDMG) -> RestorableArchive {
    RestorableArchive(dir: URL(fileURLWithPath: "/tmp/\(library)/\(version.map { VersionStamp.string($0) } ?? "cur")"),
                      libraryName: library, format: format, bytes: bytes,
                      artifactNames: ["\(library).dmg"], encrypted: false, version: version)
}

private func day(_ d: Int) -> Date { VersionStamp.date("2026-07-\(String(format: "%02d", d))-020000")! }

/// Photos runs nightly; Music only every third day. Discovery returns newest-first
/// within a library, which is what selections() relies on.
private let scan: [RestorableArchive] = [
    stub("Photos", day(24)), stub("Photos", day(23)), stub("Photos", day(22)),
    stub("Photos", day(21)), stub("Photos", day(20)),
    stub("Music", day(24)), stub("Music", day(21)), stub("Music", day(18)),
]

@Test func momentsAreTheDistinctVersionDatesOldestFirst() {
    let m = RecoveryPlan.moments(in: scan)
    #expect(m == [day(18), day(20), day(21), day(22), day(23), day(24)])
    // a mirror has no history, so it contributes no slider stop
    #expect(RecoveryPlan.moments(in: [stub("Music", nil, format: .liveMirror)]).isEmpty)
}

@Test func eachLibraryContributesTheVersionThatExistedAtThatMoment() {
    let sel = RecoveryPlan.selections(at: day(22), in: scan)
    #expect(sel.map(\.library) == ["Photos", "Music"])
    #expect(sel.first { $0.library == "Photos" }?.archive.version == day(22))   // exact
    // Music ran on the 21st and 24th. At the moment of the 22nd, the 21st is what
    // existed — the 24th contains changes that hadn't happened yet.
    #expect(sel.first { $0.library == "Music" }?.archive.version == day(21))
    #expect(sel.allSatisfy { !$0.isAfterMoment })
}

@Test func neverPicksAVersionFromAfterTheMoment() {
    // this is the whole point: no selection may postdate the requested moment,
    // unless the library has nothing older (covered separately).
    for d in 18...24 {
        for s in RecoveryPlan.selections(at: day(d), in: scan) where !s.isAfterMoment {
            #expect(s.archive.version! <= day(d))
        }
    }
}

@Test func libraryYoungerThanTheMomentIsFlagged() {
    // ask for the 19th: Photos' oldest is the 20th, so it can't honour the moment.
    let sel = RecoveryPlan.selections(at: day(19), in: scan)
    let photos = sel.first { $0.library == "Photos" }
    #expect(photos?.archive.version == day(20))     // its oldest
    #expect(photos?.isAfterMoment == true)          // and we say so
    // Music does have an older one (the 18th), so it's satisfied exactly.
    let music = sel.first { $0.library == "Music" }
    #expect(music?.archive.version == day(18))
    #expect(music?.isAfterMoment == false)
}

@Test func momentBetweenRunsPicksThePrecedingVersion() {
    let mid = day(22).addingTimeInterval(60 * 60 * 12)     // midday on the 22nd
    let sel = RecoveryPlan.selections(at: mid, in: scan)
    #expect(sel.first { $0.library == "Photos" }?.archive.version == day(22))
    #expect(sel.first { $0.library == "Music" }?.archive.version == day(21))
}

@Test func mirrorAlwaysContributesItsCurrentState() {
    let withMirror = scan + [stub("AppleMusicMirror", nil, format: .liveMirror)]
    for d in [18, 21, 24] {
        let s = RecoveryPlan.selections(at: day(d), in: withMirror).first { $0.library == "AppleMusicMirror" }
        #expect(s?.isCurrentOnly == true)
        #expect(s?.isAfterMoment == false)          // "current" isn't a broken promise
    }
}

@Test func latestMomentSelectsEveryLibrarysNewest() {
    let sel = RecoveryPlan.selections(at: day(24), in: scan)
    #expect(sel.first { $0.library == "Photos" }?.archive.version == day(24))
    #expect(sel.first { $0.library == "Music" }?.archive.version == day(24))
}

@Test func totalBytesSumsTheSelectedVersionsOnly() {
    let s = RecoveryPlan.selections(at: day(22), in: [
        stub("Photos", day(22), bytes: 500), stub("Photos", day(21), bytes: 400),
        stub("Music", day(21), bytes: 250),
    ])
    #expect(RecoveryPlan.totalBytes(s) == 750)      // one version per library, not all of them
}

@Test func emptyScanPlansNothing() {
    #expect(RecoveryPlan.selections(at: day(22), in: []).isEmpty)
    #expect(RecoveryPlan.moments(in: []).isEmpty)
    #expect(RecoveryPlan.totalBytes([]) == 0)
}
