//
//  PassphraseEscrowTests.swift
//  CryoframeKitTests
//
//  The recovery file is what makes "encrypted backups survive a lost Mac" true, and
//  on a new Mac it is matched to archives by library NAME. These pin that matching,
//  including the case that used to break it: a library whose own name has a comma.
//

import Testing
import Foundation
@testable import CryoframeKit

private func entry(_ job: String, _ libs: [String], _ pass: String) -> PassphraseEscrow.Entry {
    PassphraseEscrow.Entry(jobName: job, libraries: libs, passphrase: pass)
}

@Test func recoveryFileRoundTripsThroughTheMasterPassword() throws {
    let entries = [entry("Nightly", ["Photos"], "hunter2"), entry("Msgs", ["Messages"], "s3cret")]
    let data = try #require(PassphraseEscrow.exportData(entries, password: "master"))
    let back = try #require(PassphraseEscrow.importEntries(data, password: "master"))
    #expect(back.map(\.libraries) == [["Photos"], ["Messages"]])
    #expect(back.map(\.passphrase) == ["hunter2", "s3cret"])
}

@Test func wrongMasterPasswordRecoversNothing() throws {
    let data = try #require(PassphraseEscrow.exportData([entry("J", ["Photos"], "p")], password: "right"))
    #expect(PassphraseEscrow.importEntries(data, password: "wrong") == nil)
}

@Test func libraryNameWithACommaSurvivesTheRoundTrip() throws {
    // the bug this fixes: names were stored as one comma-joined string and split back
    // apart, so "Client Work, 2026" came back as two names that matched no archive and
    // the library could never be unlocked on a new Mac. Custom libraries take their
    // name from the folder, so this is an ordinary name, not an edge case.
    let name = "Client Work, 2026"
    let data = try #require(PassphraseEscrow.exportData([entry("Archive", [name], "pw")], password: "m"))
    let back = try #require(PassphraseEscrow.importEntries(data, password: "m"))
    #expect(back[0].libraries == [name])
    #expect(PassphraseEscrow.passphrasesByLibrary(back)[name] == "pw")
}

@Test func oneEntryUnlocksEveryLibraryInItsJob() throws {
    let e = entry("Photos + Music", ["Photos", "Apple Music"], "shared")
    let map = PassphraseEscrow.passphrasesByLibrary([e])
    #expect(map["Photos"] == "shared")
    #expect(map["Apple Music"] == "shared")
    #expect(map["iMovie"] == nil)
}

@Test func firstEntryWinsWhenTwoClaimTheSameLibrary() {
    let map = PassphraseEscrow.passphrasesByLibrary([
        entry("Newer", ["Photos"], "new"), entry("Older", ["Photos"], "old"),
    ])
    #expect(map["Photos"] == "new")
}

@Test func emptyNamesAreNotKeys() {
    #expect(PassphraseEscrow.passphrasesByLibrary([entry("J", ["", "Photos"], "p")].map { $0 }).count == 1)
    #expect(PassphraseEscrow.passphrasesByLibrary([]).isEmpty)
}

@Test func aPre15RecoveryFileStillOpens() throws {
    // written before libraries became a list: only the joined `library` key.
    let legacy = #"[{"jobName":"Nightly","library":"Photos, Apple Music","passphrase":"pw"}]"#
    let entries = try JSONDecoder().decode([PassphraseEscrow.Entry].self, from: Data(legacy.utf8))
    #expect(entries[0].libraries == ["Photos", "Apple Music"])
    let map = PassphraseEscrow.passphrasesByLibrary(entries)
    #expect(map["Photos"] == "pw" && map["Apple Music"] == "pw")
}

@Test func filesWrittenNowStayReadableByOlderBuilds() throws {
    // the joined `library` key is still written, so a 1.4 build can read a 1.5 file.
    let data = try JSONEncoder().encode([entry("J", ["Photos", "Messages"], "pw")])
    let raw = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    #expect(raw[0]["library"] as? String == "Photos, Messages")
    #expect(raw[0]["libraries"] as? [String] == ["Photos", "Messages"])
}
