//
//  RemovedArchiveTests.swift
//  CryoframeKitTests
//
//  Dated versions of Messages attachments: before retention deletes old versions,
//  what only they hold is saved in a removed-items archive, in the same format and
//  with the same key, which retention never deletes and Restore shows under its own
//  name. Anything that stops the save keeps the versions. Versions are made here as
//  a run makes them (an archive, its file list and its manifest) from a made-up
//  Attachments folder.
//

import Testing
import Foundation
import CryptoKit
@testable import CryoframeKit

private func tempDir(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-rmv-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@discardableResult
private func put(_ root: URL, _ rel: String, _ text: String, date: TimeInterval = 1_700_000_000) throws -> URL {
    let url = root.appendingPathComponent(rel)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
    var times = [timespec(tv_sec: Int(date), tv_nsec: 0), timespec(tv_sec: Int(date), tv_nsec: 0)]
    _ = utimensat(AT_FDCWD, url.path, &times, 0)
    return url
}

private let attachments = ContentType.messagesAttachments
private let jobID = "job-1"

/// a destination with the library's folder in it, its identity written
private struct Shelf {
    let base: URL
    let destination: URL
    let folder: URL
    let scratch: URL
    init() throws {
        base = tempDir("dest")
        destination = base.appendingPathComponent("Backups", isDirectory: true)
        folder = destination.appendingPathComponent("Messages attachments", isDirectory: true)
        scratch = base.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try LibraryIdentity(jobID: jobID, libraryID: attachments.id, name: attachments.displayName, jobName: "Texts").write(in: folder)
    }

    /// a version of the library as it is in `src` now, as a run leaves one
    @discardableResult
    func version(_ src: URL, at date: TimeInterval, sealed: SealedArchiveEngine.Sealed = .zip, passphrase: String? = nil) throws -> URL {
        let stamp = VersionStamp.string(Date(timeIntervalSince1970: date))
        let build = base.appendingPathComponent("build-\(stamp)")
        let listing = ContentsListing.Collector(binding: ContentsCrypto.Binding(jobID: jobID, libraryID: attachments.id, version: stamp))
        _ = JobExecutor.directoryStats(src, listing: listing)
        let built = try SealedArchiveEngine(sealed, passphrase: passphrase).archive(ArchiveSource(name: "Attachments", root: src), to: build)
        let key = passphrase.flatMap { ContentsCrypto.masterKey(passphrase: $0, jobID: jobID) }
        let contents = ContentsListing.write(listing, master: key, encrypted: passphrase != nil, into: build)
        let dir = folder.appendingPathComponent(stamp, isDirectory: true)
        _ = try SealedArchiveEngine(sealed).distribute(builtFile: built.artifacts[0], into: dir, encrypted: passphrase != nil, contents: contents)
        try? FileManager.default.removeItem(at: build)
        return dir
    }

    func keeper(sealed: SealedArchiveEngine.Sealed = .zip, passphrase: String? = nil, now: TimeInterval = 1_800_000_000,
                control: RunControl = RunControl(),
                open: ((RestorableArchive, String?) throws -> OpenedArchive)? = nil) -> RemovedArchive {
        let rel = "\(jobID)/build/messages.removed"
        return RemovedArchive(library: attachments, jobID: jobID, sealed: sealed, passphrase: passphrase,
                              listKey: passphrase.flatMap { ContentsCrypto.masterKey(passphrase: $0, jobID: jobID) },
                              buildDir: scratch.appendingPathComponent(rel), gatherDir: scratch.appendingPathComponent(rel),
                              runner: ProcessCommandRunner(control: control), now: Date(timeIntervalSince1970: now), open: open)
    }
}

/// the files a removed-items archive holds, with their contents, read through its list
/// and by opening it
private func held(_ a: RestorableArchive, passphrase: String? = nil) throws -> [String: String] {
    var listed: [String] = []
    let key = passphrase.flatMap { ContentsCrypto.masterKey(passphrase: $0, jobID: jobID) }
    let outcome = ContentsListing.read(a, master: { _ in key.map { [$0] } ?? [] }) { if $0.kind == .file { listed.append($0.path) } }
    #expect(outcome == .read(entries: outcome.entries, partial: false), "\(outcome)")
    let opened = try ArchiveReader().open(a.archiveResult(), passphrase: passphrase)
    defer { opened.close() }
    let root = ArchiveLayout.libraryRoot(in: opened.root, for: a)
    var out: [String: String] = [:]
    for rel in listed { out[rel] = try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8) }
    return out
}

private extension ContentsListing.ReadOutcome {
    var entries: Int { if case .read(let n, _) = self { return n }; return -1 }
}

@Suite(.serialized) struct RemovedArchiveTests {

    // v1 holds a, b and c; v2 a and b (b changed since v1); v3 (the run's own) a and d.
    // Retention lets v1 and v2 go: b (from v2, the newest holding it) and c are saved,
    // a and d aren't.
    // The archive keeps each file's date, is in Removed items, is found by Restore
    // under its own name, and is never something retention deletes. A later prune
    // doesn't save again what an earlier archive holds.
    @Test func whatOnlyGoingVersionsHoldIsSavedOnce() throws {
        let s = try Shelf()
        let src = s.base.appendingPathComponent("Attachments")
        defer { try? FileManager.default.removeItem(at: s.base) }
        try put(src, "0a/01/A/a.heic", "a")
        try put(src, "0b/02/B/b.jpg", "b, first")
        try put(src, "0c/03/C/c.pdf", "c", date: 1_710_000_000)
        let v1 = try s.version(src, at: 1_750_000_000)
        try put(src, "0b/02/B/b.jpg", "b, edited", date: 1_720_000_000)
        try FileManager.default.removeItem(at: src.appendingPathComponent("0c"))
        let v2 = try s.version(src, at: 1_760_000_000)
        try FileManager.default.removeItem(at: src.appendingPathComponent("0b"))
        try put(src, "0d/04/D/d.mov", "d")
        try s.version(src, at: 1_770_000_000)

        let out = s.keeper().keep(goingFrom: [v1, v2], in: s.folder)
        #expect(out == RemovedArchive.Outcome(kept: 2))
        let archives = RemovedArchive.archives(in: s.folder)
        try #require(archives.count == 1)
        let a = archives[0]
        let stamp = VersionStamp.string(Date(timeIntervalSince1970: 1_800_000_000))
        #expect(a.dir.path == s.folder.appendingPathComponent("Removed items/\(stamp)").path)
        #expect(a.removedItems && a.libraryName == "Messages attachments, removed items" && a.libraryFolder.path == s.folder.path)
        #expect(a.libraryKey == "\(jobID)/\(attachments.id)" && a.format == .sealedZip)
        #expect(try held(a) == ["0b/02/B/b.jpg": "b, edited", "0c/03/C/c.pdf": "c"])
        // nothing left in scratch
        #expect(!FileManager.default.fileExists(atPath: s.scratch.appendingPathComponent("\(jobID)/build/messages.removed").path))

        // Restore finds it beside the versions, under its own name; nothing that counts
        // versions is handed it
        let scan = RestoreDiscovery.scan(s.destination, removedItems: true)
        #expect(scan.filter { $0.libraryName == "Messages attachments" }.count == 3)
        #expect(scan.filter(\.removedItems).map(\.dir.lastPathComponent) == [stamp])
        #expect(RestoreDiscovery.scan(s.destination).count == 3)
        #expect(RestoreDiscovery.scan(s.folder, maxDepth: 1).count == 3)
        #expect(RestoreDiscovery.scan(s.destination, maxDepth: 5).count == 3)
        // retention never counts or deletes it
        let plan = JobExecutor.prunePlan(folders: [(attachments, s.folder)], policy: .keepLast(1))
        #expect(plan.versions.count == 2 && plan.husks.isEmpty)

        // v1 and v2 go; then v3 goes too, its a and d still in the source's next version:
        // nothing new to save, so no second archive
        for v in [v1, v2] { try FileManager.default.removeItem(at: v) }
        let v3 = s.folder.appendingPathComponent(VersionStamp.string(Date(timeIntervalSince1970: 1_770_000_000)))
        try s.version(src, at: 1_780_000_000)
        #expect(s.keeper(now: 1_800_000_100).keep(goingFrom: [v3], in: s.folder) == RemovedArchive.Outcome())
        #expect(RemovedArchive.archives(in: s.folder).count == 1)
    }

    // The run's pruning: the versions go once their items are saved; when the save
    // fails, the versions holding them stay, and the run names them.
    @Test func pruningWaitsForTheSave() throws {
        let s = try Shelf()
        let src = s.base.appendingPathComponent("Attachments")
        defer { try? FileManager.default.removeItem(at: s.base) }
        try put(src, "0a/01/A/a.heic", "a")
        try put(src, "0b/02/B/b.jpg", "b")
        let v1 = try s.version(src, at: 1_750_000_000)
        try FileManager.default.removeItem(at: src.appendingPathComponent("0b"))
        let v2 = try s.version(src, at: 1_760_000_000)

        struct Refused: Error, LocalizedError { var errorDescription: String? { "it is somewhere else" } }
        // no whole list for v1, and it won't open: it stays
        try FileManager.default.removeItem(at: v1.appendingPathComponent(ContentsListing.plainName))
        let failures = JobExecutor.pruneVersions(folders: [(attachments, s.folder)], policy: .keepLast(1), confirmed: { _, _ in true },
                                                 keepRemoved: { _, folder, going in
                                                     s.keeper(open: { _, _ in throw Refused() }).keep(goingFrom: going, in: folder)
                                                 })
        #expect(FileManager.default.fileExists(atPath: v1.path))
        #expect(failures.count == 1)
        #expect(failures.first?.hasPrefix("Messages attachments \(v1.lastPathComponent): kept until the items deleted from it are saved (") == true)
        #expect(failures.first?.contains("it is somewhere else") == true)
        #expect(RemovedArchive.archives(in: s.folder).isEmpty)

        // opened for real, it is looked through and goes; what it alone held is saved
        let again = JobExecutor.pruneVersions(folders: [(attachments, s.folder)], policy: .keepLast(1), confirmed: { _, _ in true },
                                              keepRemoved: { _, folder, going in s.keeper().keep(goingFrom: going, in: folder) })
        #expect(again.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: v1.path) && FileManager.default.fileExists(atPath: v2.path))
        let archives = RemovedArchive.archives(in: s.folder)
        try #require(archives.count == 1)
        #expect(try held(archives[0]) == ["0b/02/B/b.jpg": "b"])

        // Stop keeps every going version
        let stopped = RunControl(); stopped.cancel()
        #expect(s.keeper(control: stopped).keep(goingFrom: [v2], in: s.folder).spared == [v2])
    }

    // An encrypted job's disk images: the archive is an encrypted disk image, opened
    // with the job's passphrase, its list sealed with the job's key.
    @Test func anEncryptedJobsArchiveIsEncryptedTheSameWay() throws {
        let s = try Shelf()
        let src = s.base.appendingPathComponent("Attachments")
        defer { try? FileManager.default.removeItem(at: s.base) }
        let passphrase = "correct horse battery staple"
        try put(src, "0a/01/A/a.heic", "a")
        try put(src, "0b/02/B/b.jpg", "b")
        let v1 = try s.version(src, at: 1_750_000_000, sealed: .dmg, passphrase: passphrase)
        try FileManager.default.removeItem(at: src.appendingPathComponent("0b"))
        try s.version(src, at: 1_760_000_000, sealed: .dmg, passphrase: passphrase)

        let out = s.keeper(sealed: .dmg, passphrase: passphrase).keep(goingFrom: [v1], in: s.folder)
        #expect(out == RemovedArchive.Outcome(kept: 1))
        let archives = RemovedArchive.archives(in: s.folder)
        try #require(archives.count == 1)
        #expect(archives[0].encrypted && archives[0].format == .sealedDMG)
        #expect(archives[0].contents?.name == ContentsListing.encryptedName)
        #expect(try held(archives[0], passphrase: passphrase) == ["0b/02/B/b.jpg": "b"])
        #expect(throws: (any Error).self) { _ = try ArchiveReader().open(archives[0].archiveResult(), passphrase: "wrong") }
    }
}
