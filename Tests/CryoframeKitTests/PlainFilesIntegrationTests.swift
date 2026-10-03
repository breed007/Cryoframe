//
//  PlainFilesIntegrationTests.swift
//  CryoframeKitTests
//
//  A plain-files copy as the rest of Cryoframe sees it: its library folder (made new,
//  never a 1.5 folder taken over), Restore (found by its identity, never looked into
//  for archives, restored from where it is; an app's library with an unfinished
//  update refused), Find a File's list, a check, Storage with Removed items, and the
//  cloud upload check.
//

import Testing
import Foundation
@testable import CryoframeKit

private func tempDir(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-plainint-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@discardableResult
private func put(_ root: URL, _ rel: String, _ text: String) throws -> URL {
    let url = root.appendingPathComponent(rel)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
    return url
}

private let exfatLike = FileSystemProfile(kind: .exfat, fsType: "exfat", foldsCase: true, cluster: 4096, companions: false)

/// a plain-files job of `lib` to `dest`, run once through the run's own steps
private func runOnce(_ job: BackupJob, _ lib: ContentType, _ dest: URL, source: URL,
                     profile: FileSystemProfile = exfatLike) throws -> (folder: URL, notes: [String]) {
    let prepared = try LibraryFolders.prepare(job: job, library: lib, in: dest, jobs: [job])
    let (result, notes) = try JobExecutor.plainFiles(job: job, library: lib, source: ArchiveSource(name: source.lastPathComponent, root: source),
                                                     folder: prepared.folder, target: job.target, profile: profile, bytes: 10,
                                                     partial: false, now: Date(), runner: ProcessCommandRunner())
    guard case .completed = result else { Issue.record("not completed: \(result)"); return (prepared.folder, notes) }
    return (prepared.folder, notes)
}

@Suite(.serialized) struct PlainFilesIntegrationTests {

    // Made in a folder of its own beside a 1.5 folder of the library's name (never
    // taken over), recorded in the identity with what the drive doesn't keep, said
    // once; found by Restore as one up-to-date copy whose name is the library's own,
    // and never looked into (the library's own files hold a manifest here).
    @Test func aPlainCopyIsFoundByItsIdentityAndRestoredFromWhereItIs() throws {
        let base = tempDir("restore")
        defer { try? FileManager.default.removeItem(at: base) }
        let src = base.appendingPathComponent("src/Taxes.things")
        try put(src, "2024/W-2.pdf", "w2")
        try put(src, "inner/\(ArchiveManifest.sidecarName)", "{}")     // a library's own file of that name
        let dest = base.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest.appendingPathComponent("Taxes"), withIntermediateDirectories: true)   // as 1.5 made it
        let lib = ContentType.genericFolder(id: "taxes", displayName: "Taxes", path: .absolute(src.path))
        let job = BackupJob(name: "T", libraries: [lib], target: .localVolume(id: "d", name: "Disk", dir: dest),
                            format: .plainFiles, frequency: .manual, createdAt: Date())

        var (folder, notes) = try runOnce(job, lib, dest, source: src)
        #expect(folder.lastPathComponent != "Taxes")
        #expect(LibraryIdentity.read(in: dest.appendingPathComponent("Taxes")) == nil)
        #expect(notes.contains { $0.contains("doesn't keep permissions") })
        let identity = try #require(LibraryIdentity.read(in: folder))
        #expect(identity.mirror == nil)
        #expect(identity.files?.copy == "Taxes.things")
        #expect(identity.files?.fileSystem == "an exFAT drive")
        (folder, notes) = try runOnce(job, lib, dest, source: src)
        #expect(notes.isEmpty, "said again: \(notes)")

        let found = RestoreDiscovery.scan(dest)
        #expect(found.count == 1)
        let a = try #require(found.first)
        #expect(a.format == .plainFiles && a.version == nil && a.bundleName == "Taxes.things")
        #expect(LibraryFolders.archives(job: job, library: lib, in: dest).map(\.dir) == [folder])
        var sealedJob = job; sealedJob.format = .sealedDMG
        #expect(LibraryFolders.archives(job: sealedJob, library: lib, in: dest).isEmpty)

        let out = base.appendingPathComponent("out")
        let restored = try RestoreEngine().restore(a, to: out)
        #expect(restored.lastPathComponent == "Taxes.things")
        #expect(try String(contentsOf: restored.appendingPathComponent("2024/W-2.pdf"), encoding: .utf8) == "w2")

        // Find a File's list, beside the copy
        var paths: [String] = []
        let outcome = ContentsListing.read(a, master: { _ in [] }) { paths.append($0.path) }
        #expect(outcome == .read(entries: 4, partial: false))
        #expect(Set(paths) == ["2024", "2024/W-2.pdf", "inner", "inner/\(ArchiveManifest.sidecarName)"])
    }

    // A check finds the copy and passes it; an update stopped part way isn't counted
    // either way; a missing copy fails. An app's library stopped part way isn't
    // restored until a backup has finished it.
    @Test func checksAndAnUnfinishedUpdate() throws {
        let base = tempDir("check")
        defer { try? FileManager.default.removeItem(at: base) }
        let src = base.appendingPathComponent("src/Photos Library.photoslibrary")
        try put(src, "database/Photos.sqlite", "db")
        let dest = base.appendingPathComponent("dest")
        let lib = ContentType.genericFolder(id: "pl", displayName: "Pictures", path: .absolute(src.path))
        let job = BackupJob(name: "P", libraries: [lib], target: .localVolume(id: "d", name: "Disk", dir: dest),
                            format: .plainFiles, frequency: .manual, createdAt: Date())
        let (folder, _) = try runOnce(job, lib, dest, source: src)

        var report = HealthChecker().check(job: job)
        #expect(report.checks.count == 1 && report.checks[0].passed && !report.checks[0].skipped)
        try PlainCopy.mark(folder)
        report = HealthChecker().check(job: job)
        #expect(report.checks.first?.skipped == true)

        let a = try #require(RestoreDiscovery.scan(dest).first)
        #expect(throws: RestoreError.unfinishedPlainCopy("Photos Library.photoslibrary")) {
            try RestoreEngine().restore(a, to: base.appendingPathComponent("out"))
        }
        PlainCopy.unmark(folder)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("Photos Library.photoslibrary"))
        report = HealthChecker().check(job: job)
        #expect(report.checks.isEmpty || report.checks.first?.passed == false)
    }

    // Storage shows the copy and its Removed items apart; deleting removed items older
    // than a day deletes only those days, and the folder once it is empty.
    @Test func storageAndRemovedItems() throws {
        let base = tempDir("storage")
        defer { try? FileManager.default.removeItem(at: base) }
        let src = base.appendingPathComponent("src/Notes")
        try put(src, "keep.txt", "k")
        try put(src, "gone.txt", "g")
        let dest = base.appendingPathComponent("dest")
        let lib = ContentType.genericFolder(id: "notes", displayName: "Notes", path: .absolute(src.path))
        let job = BackupJob(name: "N", libraries: [lib], target: .localVolume(id: "d", name: "Disk", dir: dest),
                            format: .plainFiles, frequency: .manual, createdAt: Date())
        let (folder, _) = try runOnce(job, lib, dest, source: src)
        try FileManager.default.removeItem(at: src.appendingPathComponent("gone.txt"))
        _ = try runOnce(job, lib, dest, source: src)
        let removed = folder.appendingPathComponent(PlainCopyLayout.removedFolder)
        try put(removed, "2020-01-02/old.txt", "old")

        let rows = StorageReporter.report([job])
        #expect(rows.count == 1)
        #expect(rows[0].archives.map(\.library) == ["Notes", "Notes · Removed items"])
        // a copy and what was deleted from it, never "2 archives"
        #expect(rows[0].contentsSummary == "a current copy and Removed items")
        #expect(rows[0].versionCount == 0)
        #expect(rows[0].archives[1].removedItems?.resolvingSymlinksInPath().path == removed.resolvingSymlinksInPath().path)

        #expect(RemovedItems.days(in: removed).count == 2)
        let cutoff = Calendar.current.date(byAdding: .day, value: -1, to: Date())
        #expect(RemovedItems.delete(in: removed, before: cutoff).deleted == 1)
        #expect(RemovedItems.days(in: removed).count == 1)
        #expect(RemovedItems.delete(in: removed, before: nil).deleted == 1)
        #expect(!FileManager.default.fileExists(atPath: removed.path))
    }

    // Plain files in a cloud folder are never recorded by the upload check, and are
    // said to be unknown.
    @Test func theUploadCheckSaysUnknown() {
        let t = Target.cloudSyncFolder(id: "c", name: "iCloud", dir: URL(fileURLWithPath: "/nonexistent-cloud"))
        let job = BackupJob(name: "C", libraries: [.genericFolder(id: "x", displayName: "X", path: .absolute("/tmp/x"))],
                            target: t, format: .plainFiles, frequency: .manual, createdAt: Date())
        let ledger = UploadLedger(url: FileManager.default.temporaryDirectory.appendingPathComponent("cf-ledger-\(UUID().uuidString).json"))
        guard case .unknown(let why) = UploadCheck(ledger: ledger).refresh(job: job, target: t) else {
            Issue.record("not unknown"); return
        }
        #expect(why?.contains("Plain files") == true)
    }
}
