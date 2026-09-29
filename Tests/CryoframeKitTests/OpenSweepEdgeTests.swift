//
//  OpenSweepEdgeTests.swift
//  CryoframeKitTests
//
//  The launch sweep at its edges: the one-day line for a work folder with no owner,
//  an owner file that can't be read, an owner that was a real process and died,
//  and a real archive opened by a process that then exits without closing it.
//  Every test sweeps its own folder, never the shared temp folder.
//

import Testing
import Foundation
@testable import CryoframeKit

private func sweepDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-sweepedge-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func work(_ base: URL, _ name: String, made: Date? = nil) throws -> URL {
    let w = base.appendingPathComponent("cf-open-\(name)")
    try FileManager.default.createDirectory(at: w.appendingPathComponent("extract"), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: w.appendingPathComponent("extract/file"))
    if let made { try FileManager.default.setAttributes([.creationDate: made], ofItemAtPath: w.path) }
    return w
}

private func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }

// 2026-07-01 12:00 UTC
private let madeAt = Date(timeIntervalSince1970: 1_782_907_200)

@Test func anUnownedOpenIsKeptThroughADayAndSweptAfter() throws {
    let base = sweepDir(); defer { try? FileManager.default.removeItem(at: base) }
    let w = try work(base, "legacy", made: madeAt)

    ArchiveReader.sweepStaleOpens(in: base, now: madeAt.addingTimeInterval(24 * 3600))
    #expect(exists(w.appendingPathComponent("extract/file")))

    ArchiveReader.sweepStaleOpens(in: base, now: madeAt.addingTimeInterval(24 * 3600 + 1))
    #expect(!exists(w))
}

// An owner file caught mid-write, or damaged, says nothing about who has it open.
// It must not read as "owner gone" and close a fresh open under a live process.
@Test func anOwnerFileThatCantBeReadCountsAsNoOwner() throws {
    let base = sweepDir(); defer { try? FileManager.default.removeItem(at: base) }
    let fresh = try work(base, "fresh")
    let old = try work(base, "old", made: Date().addingTimeInterval(-3 * 24 * 3600))
    for w in [fresh, old] {
        try Data(#"{"pid":12"#.utf8).write(to: w.appendingPathComponent(OpenedArchive.ownerFileName))
    }

    ArchiveReader.sweepStaleOpens(in: base)

    #expect(exists(fresh.appendingPathComponent("extract/file")))
    #expect(!exists(old))
}

@Test func anOpenWhoseRealOwnerWasKilledIsSweptAtOnce() throws {
    let base = sweepDir(); defer { try? FileManager.default.removeItem(at: base) }
    let opener = Process()
    opener.executableURL = URL(fileURLWithPath: "/bin/sleep")
    opener.arguments = ["30"]
    try opener.run()
    let owner = try #require(ProcessIdentity.of(pid: opener.processIdentifier))
    let w = try work(base, "killed")                               // made just now
    try JSONEncoder().encode(owner).write(to: w.appendingPathComponent(OpenedArchive.ownerFileName))

    ArchiveReader.sweepStaleOpens(in: base)
    #expect(exists(w.appendingPathComponent("extract/file")))       // still alive: kept

    kill(opener.processIdentifier, SIGKILL)
    opener.waitUntilExit()
    ArchiveReader.sweepStaleOpens(in: base)
    #expect(!exists(w))                                             // no day's wait once it's gone
}

// The whole path for a real archive: a separate process opens it and exits without
// closing (a crash), and the next sweep clears it. A sealed zip, so no mount is
// involved. The opener is `ditto` doing what ArchiveReader.open does, plus the
// owner file naming it; it exits right after, as a crashed opener would.
@Test func aRealExtractLeftByAnExitedProcessIsSwept() throws {
    let base = sweepDir(); defer { try? FileManager.default.removeItem(at: base) }
    let src = base.appendingPathComponent("Lib")
    try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
    try Data("kept".utf8).write(to: src.appendingPathComponent("a.txt"))
    let zip = base.appendingPathComponent("Lib.zip")
    #expect(try ProcessCommandRunner().run("/usr/bin/ditto", ["-c", "-k", src.path, zip.path]).ok)

    let w = base.appendingPathComponent("cf-open-\(UUID().uuidString)")
    let extract = w.appendingPathComponent("extract")
    try FileManager.default.createDirectory(at: extract, withIntermediateDirectories: true)
    let ditto = Process()
    ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    ditto.arguments = ["-x", "-k", zip.path, extract.path]
    try ditto.run()
    let owner = ProcessIdentity.of(pid: ditto.processIdentifier)
    ditto.waitUntilExit()
    let gone = owner ?? ProcessIdentity(pid: ditto.processIdentifier, startedAt: 1)
    try JSONEncoder().encode(gone).write(to: w.appendingPathComponent(OpenedArchive.ownerFileName))
    #expect(exists(extract.appendingPathComponent("a.txt")))

    ArchiveReader.sweepStaleOpens(in: base)
    #expect(!exists(w))
    #expect(exists(zip))                                            // the archive itself is never touched
}
