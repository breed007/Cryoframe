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
