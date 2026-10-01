//
//  OpenSweepTests.swift
//  CryoframeKitTests
//
//  The launch sweep clears archives a crashed process left open. It runs in the
//  app, and the scheduled agent (or another app instance) may have an archive open
//  at that moment for a verify, a drill or a rehearsal; the sweep must leave those
//  alone. Each test sweeps its own folder: a sweep over the real temp folder would
//  close archives other tests in this suite have open.
//

import Testing
import Foundation
@testable import CryoframeKit

private func tempDir(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// a sealed zip of a small folder, the cheapest archive to open (no mount).
private func zipArchive(in base: URL) throws -> ArchiveResult {
    let src = base.appendingPathComponent("Lib")
    try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
    try Data("kept".utf8).write(to: src.appendingPathComponent("a.txt"))
    let zip = base.appendingPathComponent("Lib.zip")
    let r = try ProcessCommandRunner().run("/usr/bin/ditto", ["-c", "-k", src.path, zip.path])
    try #require(r.ok, "couldn't build the test zip: \(r.stderr)")
    return ArchiveResult(artifacts: [zip], format: .sealedZip)
}

private func workDir(_ base: URL, _ name: String, owner: ProcessIdentity?) throws -> URL {
    // named as the reader names it: the sweep takes nothing else (see OpenedArchive.isWorkFolder)
    let work = base.appendingPathComponent(OpenedArchive.workPrefix + UUID().uuidString)
    try FileManager.default.createDirectory(at: work.appendingPathComponent("extract"), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: work.appendingPathComponent("extract/file"))
    if let owner {
        try JSONEncoder().encode(owner).write(to: work.appendingPathComponent(OpenedArchive.ownerFileName))
    }
    return work
}

@Test func theLaunchSweepLeavesAnArchiveALiveProcessHasOpen() throws {
    let base = tempDir("opensweep"); defer { try? FileManager.default.removeItem(at: base) }
    let opened = try ArchiveReader(workBase: base).open(try zipArchive(in: base))
    defer { opened.close() }

    ArchiveReader.sweepStaleOpens(in: base)

    let contents = (try? FileManager.default.contentsOfDirectory(atPath: opened.root.path)) ?? []
    #expect(!contents.isEmpty, "the sweep closed an archive that was still being read")
}

@Test func openingAnArchiveRecordsWhoHasItOpen() throws {
    let base = tempDir("opensweep"); defer { try? FileManager.default.removeItem(at: base) }
    let opened = try ArchiveReader(workBase: base).open(try zipArchive(in: base))
    defer { opened.close() }
    let work = opened.root.deletingLastPathComponent()
    let data = try Data(contentsOf: work.appendingPathComponent(OpenedArchive.ownerFileName))
    let owner = try JSONDecoder().decode(ProcessIdentity.self, from: data)
    #expect(owner == ProcessIdentity.current)
}

@Test func theLaunchSweepClearsWhatAGoneProcessLeftAndLeavesTheRest() throws {
    let base = tempDir("opensweep"); defer { try? FileManager.default.removeItem(at: base) }
    let me = try #require(ProcessIdentity.current)
    let crashed = try workDir(base, "crashed", owner: ProcessIdentity(pid: me.pid, startedAt: me.startedAt - 1))
    let live = try workDir(base, "live", owner: me)
    // no owner: opened by a version before 1.6, or caught before its owner was written
    let fresh = try workDir(base, "fresh", owner: nil)
    let stale = try workDir(base, "stale", owner: nil)
    try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-3 * 24 * 3600)],
                                          ofItemAtPath: stale.path)
    let unrelated = base.appendingPathComponent("not-ours")
    try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)

    ArchiveReader.sweepStaleOpens(in: base)

    #expect(!FileManager.default.fileExists(atPath: crashed.path))
    #expect(FileManager.default.fileExists(atPath: live.appendingPathComponent("extract/file").path))
    #expect(FileManager.default.fileExists(atPath: fresh.appendingPathComponent("extract/file").path))
    #expect(!FileManager.default.fileExists(atPath: stale.path))
    #expect(FileManager.default.fileExists(atPath: unrelated.path))
}
