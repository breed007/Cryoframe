//
//  CloudUploadTests.swift
//  CryoframeKitTests
//
//  The cloud upload check fails safe: no provider's word is taken until it is on the
//  allowlist (empty), only an evicted file counts as uploaded, a version is uploaded
//  only when all of its files are, a provider that doesn't answer is "can't tell",
//  a vanished version is dropped (never counted), and the ledger's cap never clears
//  a warning.
//

import Testing
import Foundation
@testable import CryoframeKit

private let hour: TimeInterval = 3600
private let now = Date(timeIntervalSince1970: 1_790_000_000)

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-up-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

private func lib(_ id: String, _ name: String) -> ContentType {
    .genericFolder(id: id, displayName: name, path: .absolute("/Users/someone/\(name)"))
}

private func cloudJob(_ libs: [ContentType], dest: URL) -> BackupJob {
    BackupJob(id: "job-\(UUID().uuidString.prefix(6))", name: "Cloud", libraries: libs,
              target: .cloudSyncFolder(id: "t1", name: "Dropbox", dir: dest, provider: .dropbox),
              format: .sealedZip, frequency: .manual, createdAt: Date(timeIntervalSince1970: 0))
}

/// a sealed version of `bundle` in the job's folder for `library`, with a file list
@discardableResult
private func version(_ job: BackupJob, _ library: ContentType, dest: URL, stamp: String) throws -> URL {
    let f = try LibraryFolders.prepare(job: job, library: library, in: dest, jobs: [job], isOpen: { _ in false }).folder
    let at = f.appendingPathComponent(stamp)
    try FileManager.default.createDirectory(at: at, withIntermediateDirectories: true)
    let zip = at.appendingPathComponent(library.displayName + ".zip")
    try Data("zip \(UUID())".utf8).write(to: zip)
    try Data("list".utf8).write(to: at.appendingPathComponent(ContentsListing.plainName))
    let contents = ContentsDigest(name: ContentsListing.plainName, size: 4, sha256: "00", entries: 1, partial: false)
    _ = try ArchiveManifest.write(try ArchiveManifest.build(for: ArchiveResult(artifacts: [zip], format: .sealedZip), contents: contents), toDir: at)
    return at
}

/// a probe whose answer for each file is set by its name
private func probe(_ answer: @escaping @Sendable (URL) -> FileUpload, timeout: TimeInterval = 5) -> UploadProbe {
    UploadProbe(verified: [], timeout: timeout, look: { url, _, _ in answer(url) })
}

@Suite struct CloudUploadTests {
    // MARK: the allowlist

    @Test func noProviderIsBelievedYetICloudIncluded() {
        #expect(CloudUpload.verifiedProviders.isEmpty)
        #expect(!CloudUpload.verifiedProviders.contains(.iCloud))
    }

    // A file in a cloud folder that the provider hasn't evicted reads "can't tell",
    // whatever its keys say: with the allowlist empty, they aren't asked.
    @Test func aResidentFileIsUnknownNotUploaded() throws {
        let dir = folder("resident"); defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("a.zip")
        try Data(repeating: 7, count: 2_000_000).write(to: f)
        for provider in CloudProvider.allCases {
            #expect(UploadProbe.systemLook(f, provider, []) == .status(.unknown(nil)), "\(provider)")
        }
        // and the keys alone don't make a file uploaded even for a verified provider:
        // a plain local file has no upload state, which is "can't tell"
        #expect(UploadProbe.systemLook(f, .iCloud, [.iCloud]) == .status(.unknown(nil)))
    }

    // An evicted file (here hollow: 10 MB long, nothing on disk) is uploaded: the
    // provider couldn't have dropped what it doesn't hold.
    @Test func anEvictedFileIsUploaded() throws {
        let dir = folder("evicted"); defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("a.zip")
        #expect(FileManager.default.createFile(atPath: f.path, contents: nil))
        let h = try FileHandle(forWritingTo: f); try h.truncate(atOffset: 10_000_000); try h.close()
        try #require(CloudFile.isDataless(f), "the hollow file reads as resident here")
        #expect(UploadProbe.systemLook(f, .dropbox, []) == .status(.uploaded))
    }

    @Test func aMissingFileIsGone() {
        #expect(UploadProbe.systemLook(URL(fileURLWithPath: "/nonexistent/cf/\(UUID())"), .dropbox, []) == .gone)
    }

    // MARK: a version is all its files

    @Test func aVersionIsUploadedOnlyWhenEveryFileIs() {
        #expect(UploadProbe.combine([.status(.uploaded), .status(.uploaded), .status(.uploaded)]) == .uploaded)
        #expect(UploadProbe.combine([.status(.uploaded), .status(.unknown(nil)), .status(.uploaded)]) == .unknown(nil))
        #expect(UploadProbe.combine([.status(.uploaded), .status(.uploading)]) == .uploading)
        #expect(UploadProbe.combine([.status(.uploading), .status(.failed("quota"))]) == .failed("quota"))
        #expect(UploadProbe.combine([.status(.uploaded), .gone]) == nil, "a version with a file gone is gone")
        #expect(UploadProbe.combine([]) == nil)
    }

    @Test func theManifestAndTheFileListCount() throws {
        let dest = folder("parts"); defer { try? FileManager.default.removeItem(at: dest) }
        let notes = lib("n", "Notes"), job = cloudJob([notes], dest: dest)
        let at = try version(job, notes, dest: dest, stamp: "2026-09-01-020000")
        let archive = try #require(RestoreDiscovery.archive(at: at))
        #expect(Set(UploadProbe.files(of: archive).map(\.lastPathComponent))
                == ["Notes.zip", ArchiveManifest.sidecarName, ContentsListing.plainName])
        // the archive itself evicted, its manifest and list still here: not uploaded
        let p = probe { $0.pathExtension == "zip" ? .status(.uploaded) : .status(.unknown(nil)) }
        let ledger = UploadLedger(url: dest.deletingLastPathComponent().appendingPathComponent("up-\(UUID()).json"))
        defer { try? FileManager.default.removeItem(at: ledger.fileURL) }
        #expect(UploadCheck(ledger: ledger, probe: p).rescan(job: job, target: job.target, now: now) == .unknown(nil))
        let all = probe { _ in .status(.uploaded) }
        #expect(UploadCheck(ledger: ledger, probe: all).rescan(job: job, target: job.target, now: now) == .uploaded)
    }

    // MARK: a provider that doesn't answer

    @Test func aLookThatDoesntAnswerIsUnknownAndStopsTheRest() throws {
        let dest = folder("slow"); defer { try? FileManager.default.removeItem(at: dest) }
        let notes = lib("n", "Notes"), job = cloudJob([notes], dest: dest)
        try version(job, notes, dest: dest, stamp: "2026-09-01-020000")
        try version(job, notes, dest: dest, stamp: "2026-09-02-020000")
        final class Count: @unchecked Sendable { var n = 0; let lock = NSLock() }
        let count = Count()
        let p = probe({ _ in count.lock.withLock { count.n += 1 }; Thread.sleep(forTimeInterval: 2); return .status(.uploaded) },
                      timeout: 0.2)
        let (one, timedOut) = p.file(dest, provider: .dropbox)
        #expect(timedOut)
        guard case .status(.unknown) = one else { Issue.record("\(one)"); return }
        let ledger = UploadLedger(url: dest.deletingLastPathComponent().appendingPathComponent("up-\(UUID()).json"))
        defer { try? FileManager.default.removeItem(at: ledger.fileURL) }
        let started = Date()
        let summary = UploadCheck(ledger: ledger, probe: p).rescan(job: job, target: job.target, now: now)
        guard case .unknown = summary else { Issue.record("\(summary)"); return }
        #expect(Date().timeIntervalSince(started) < 1.5, "every file waited out its timeout")
        #expect(count.lock.withLock { count.n } <= 2, "the look went on asking a provider that had stopped answering")
    }

    // MARK: a vanished version

    @Test func aVanishedVersionIsDroppedNeverCountedAsUploaded() throws {
        let dest = folder("gone"); defer { try? FileManager.default.removeItem(at: dest) }
        let notes = lib("n", "Notes"), job = cloudJob([notes], dest: dest)
        let at = try version(job, notes, dest: dest, stamp: "2026-09-01-020000")
        let ledger = UploadLedger(url: dest.deletingLastPathComponent().appendingPathComponent("up-\(UUID()).json"))
        defer { try? FileManager.default.removeItem(at: ledger.fileURL) }
        let check = UploadCheck(ledger: ledger, probe: probe { _ in .status(.unknown(nil)) })
        #expect(check.rescan(job: job, target: job.target, now: now) == .unknown(nil))
        try FileManager.default.removeItem(at: at)          // pruned
        let after = check.refresh(job: job, target: job.target, now: now)
        #expect(after == .notChecked, "\(after)")
        let key = DestinationKey(jobID: job.id, targetID: job.target.id)
        #expect(ledger.destination(key)?.entries.isEmpty == true)
        #expect(ledger.destination(key)?.confirmed == 0)
    }

    // A cloud folder that isn't there makes every version look gone; nothing is
    // looked at and nothing is dropped.
    @Test func aMissingCloudFolderChangesNothing() throws {
        let dest = folder("away")
        let notes = lib("n", "Notes"), job = cloudJob([notes], dest: dest)
        try version(job, notes, dest: dest, stamp: "2026-09-01-020000")
        let ledger = UploadLedger(url: dest.deletingLastPathComponent().appendingPathComponent("up-\(UUID()).json"))
        defer { try? FileManager.default.removeItem(at: ledger.fileURL) }
        let check = UploadCheck(ledger: ledger, probe: probe { _ in .status(.unknown(nil)) })
        _ = check.rescan(job: job, target: job.target, now: now)
        try FileManager.default.removeItem(at: dest)
        let key = DestinationKey(jobID: job.id, targetID: job.target.id)
        let before = ledger.destination(key)
        guard case .unknown = check.refresh(job: job, target: job.target, now: now) else { Issue.record("not unknown"); return }
        guard case .unknown = check.rescan(job: job, target: job.target, now: now) else { Issue.record("not unknown"); return }
        #expect(ledger.destination(key) == before)
    }

    // MARK: the summary and the ledger

    @Test func notOffsiteOnlyADayAfterAVerifiedProvidersNo() {
        var d = DestinationUploads()
        d.entries = [UploadEntry(version: "/a", runAt: now.addingTimeInterval(-2 * hour), status: .uploading)]
        #expect(UploadSummary.of(d, now: now) == .uploading(count: 1, error: nil))
        #expect(UploadSummary.of(d, now: now.addingTimeInterval(23 * hour)) == .notOffsite(count: 1, since: now.addingTimeInterval(-2 * hour)))
        // "can't tell" never becomes a warning, however old
        d.entries = [UploadEntry(version: "/a", runAt: now.addingTimeInterval(-90 * 24 * hour), status: .unknown(nil))]
        #expect(UploadSummary.of(d, now: now) == .unknown(nil))
        // and never green
        d.entries = []
        #expect(UploadSummary.of(d, now: now) == .notChecked)
        d.confirmed = 3
        #expect(UploadSummary.of(d, now: now) == .uploaded)
        d.untracked = UploadUntracked(count: 4, since: now, notUploaded: false)
        #expect(UploadSummary.of(d, now: now) == .unknown(nil), "folded versions read as uploaded")
    }

    @Test func passingTheCapKeepsAWarning() throws {
        let dir = folder("cap"); defer { try? FileManager.default.removeItem(at: dir) }
        let ledger = UploadLedger(url: dir.appendingPathComponent("up.json"), cap: 3)
        let key = DestinationKey(jobID: "j", targetID: "t")
        let old = now.addingTimeInterval(-48 * hour)
        ledger.replace(with: [UploadEntry(version: "/v0", runAt: old, status: .uploading)], confirmed: 0,
                       looked: ["/v0"], for: key, at: now)
        #expect(UploadSummary.of(ledger.destination(key), now: now) == .notOffsite(count: 1, since: old))
        ledger.record((1...5).map { UploadEntry(version: "/v\($0)", runAt: now.addingTimeInterval(Double($0))) }, for: key)
        let d = try #require(ledger.destination(key))
        #expect(d.entries.count == 3)
        #expect(!d.entries.contains { $0.version == "/v0" }, "the oldest wasn't folded")
        #expect(d.untracked?.notUploaded == true)
        #expect(UploadSummary.of(d, now: now) == .notOffsite(count: 3, since: old), "the cap cleared the warning")
        // the record changing again doesn't clear it either
        ledger.apply(Dictionary(uniqueKeysWithValues: d.entries.map { ($0.version, UploadStatus?.some(.uploaded)) }), for: key, at: now)
        guard case .notOffsite = UploadSummary.of(ledger.destination(key), now: now) else {
            Issue.record("confirming the newer versions cleared the folded warning"); return
        }
    }

    @Test func twoWritersLoseNothing() async throws {
        let dir = folder("writers"); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("up.json")
        let a = UploadLedger(url: url, cap: 1000), b = UploadLedger(url: url, cap: 1000)
        let key = DestinationKey(jobID: "j", targetID: "t")
        await withTaskGroup(of: Void.self) { group in
            for (name, ledger) in [("a", a), ("b", b)] {
                group.addTask {
                    for i in 0..<40 { ledger.record([UploadEntry(version: "/\(name)\(i)", runAt: now.addingTimeInterval(Double(i)))], for: key) }
                }
            }
        }
        #expect(a.destination(key)?.entries.count == 80)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("upload-status.lock").path))
    }

    @Test func pruneDropsGoneDestinations() throws {
        let dir = folder("prune"); defer { try? FileManager.default.removeItem(at: dir) }
        let ledger = UploadLedger(url: dir.appendingPathComponent("up.json"))
        let keep = DestinationKey(jobID: "j", targetID: "t"), drop = DestinationKey(jobID: "gone", targetID: "t")
        ledger.record([UploadEntry(version: "/a", runAt: now)], for: keep)
        ledger.record([UploadEntry(version: "/b", runAt: now)], for: drop)
        ledger.prune(keeping: [keep])
        #expect(ledger.destination(keep) != nil && ledger.destination(drop) == nil)
    }
}
