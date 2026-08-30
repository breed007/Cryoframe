//
//  ErrorDescriptionTests.swift
//  CryoframeKitTests
//
//  A failed run is written into the job row, the activity log, the run history, and
//  the alert that reaches your phone — all through the same call. What that call
//  returns is what someone reads at the moment they need to know whether their
//  backup is in trouble.
//

import Testing
import Foundation
@testable import CryoframeKit

// A run failure is written straight into the job row, the activity log, the run
// history, and the alert that reaches your phone — all of them through
// localizedDescription. Left to Swift's default that reads "The operation couldn't
// be completed. (CryoframeKit.ArchiveError error 3.)", which tells you nothing at
// the one moment you need to know whether your backup is in trouble.
@Test func aFailedRunSaysSomethingAPersonCanActOn() {
    let cases: [any Error] = [
        ArchiveError.passphraseUnavailable,
        ArchiveError.toolFailed(tool: "hdiutil", status: 1, stderr: "hdiutil: attach failed - no mountable file systems"),
        ArchiveError.sourceMissing("Photos Library.photoslibrary"),
        TargetError.unavailable("Backup SSD"),
        RestoreError.libraryNotFound,
        SnapshotBackendError.dataVolumeNotFound,
    ]
    for e in cases {
        let text = e.localizedDescription
        #expect(!text.contains("couldn't be completed"), "leaked the default rendering: \(text)")
        #expect(!text.contains("error "), "leaked an error code: \(text)")
        #expect(!text.isEmpty)
    }
}

@Test func anEncryptedJobWithNoKeySaysWhereToPutOne() {
    let text = ArchiveError.passphraseUnavailable.localizedDescription
    #expect(text.contains("encrypted"))
    #expect(text.contains("passphrase"))
}

@Test func aToolFailureQuotesTheToolsOwnLastWords() {
    let text = ArchiveError.toolFailed(tool: "hdiutil", status: 1,
                                       stderr: "some earlier noise\nhdiutil: attach failed - no mountable file systems")
        .localizedDescription
    #expect(text.contains("hdiutil"))
    #expect(text.contains("no mountable file systems"))
    #expect(!text.contains("earlier noise"))
}

// MARK: - the sealed-DMG ACL failure

// hdiutil refuses to build a sealed DMG when a file inside carries a deny-delete
// ACL, and says only "Permission denied" — which reads as Cryoframe lacking access.
// It isn't: ditto archives the same file, so sealed zip is the way out. Every
// standard home folder carries that ACL by default and inheriting ones propagate,
// so the message has to carry the way out rather than a bare errno.
@Test func aSealedDMGBlockedByAnACLExplainsItself() {
    let e = ArchiveError.toolFailed(tool: "hdiutil", status: 1,
        stderr: "could not access /Volumes/Lib/database/main.sqlite - Permission denied\nhdiutil: create failed - Permission denied")
    let text = e.localizedDescription
    #expect(text.contains("sealed zip"), "should point at the format that works: \(text)")
    #expect(text.contains("main.sqlite"), "should name the file: \(text)")
    #expect(!text.hasPrefix("hdiutil failed"), "should not just echo the tool: \(text)")
}

// a permission failure from any other tool keeps the ordinary treatment
@Test func anotherToolsPermissionFailureIsNotBlamedOnACLs() {
    let e = ArchiveError.toolFailed(tool: "ditto", status: 1, stderr: "ditto: /x/y: Permission denied")
    #expect(!e.localizedDescription.contains("sealed zip"))
    #expect(e.localizedDescription.contains("ditto"))
}
