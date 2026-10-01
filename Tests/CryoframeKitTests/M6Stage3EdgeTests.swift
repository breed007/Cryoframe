//
//  M6Stage3EdgeTests.swift
//  CryoframeKitTests
//
//  Edges of the cloud upload check and the recovery kit: a provider that stops
//  answering must not wipe out a "not offsite yet" it gave before, green must not
//  cover a version nobody looked at, and two destinations of one name both reach
//  the printed kit.
//

import Testing
import Foundation
@testable import CryoframeKit

private let now = Date(timeIntervalSince1970: 1_790_000_000)

private func scratch(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-s3-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

private func notesLibrary() -> ContentType {
    .genericFolder(id: "n", displayName: "Notes", path: .absolute("/Users/someone/Notes"))
}

private func cloudJob(dest: URL) -> BackupJob {
    BackupJob(id: "job-\(UUID().uuidString.prefix(6))", name: "Cloud", libraries: [notesLibrary()],
              target: .cloudSyncFolder(id: "t1", name: "iCloud Drive", dir: dest, provider: .iCloud),
              format: .sealedZip, frequency: .manual, createdAt: Date(timeIntervalSince1970: 0))
}

@discardableResult
private func makeVersion(_ job: BackupJob, dest: URL, stamp: String) throws -> URL {
    let library = notesLibrary()
    let f = try LibraryFolders.prepare(job: job, library: library, in: dest, jobs: [job], isOpen: { _ in false }).folder
    let at = f.appendingPathComponent(stamp)
    try FileManager.default.createDirectory(at: at, withIntermediateDirectories: true)
    let zip = at.appendingPathComponent("Notes.zip")
    try Data("zip \(UUID())".utf8).write(to: zip)
    _ = try ArchiveManifest.write(try ArchiveManifest.build(for: ArchiveResult(artifacts: [zip], format: .sealedZip)), toDir: at)
    return at
}

@Suite struct M6Stage3EdgeTests {
    // A verified provider said a version wasn't uploaded, more than a day ago: "Not
    // offsite yet". Then the provider stops answering (wedged, which is when uploads
    // don't happen). A look that timed out knows nothing new, so the warning must
    // stand, on refresh and on Check Again alike.
    @Test func aProviderThatStopsAnsweringKeepsItsNotOffsiteWarning() throws {
        let dest = scratch("stall"); defer { try? FileManager.default.removeItem(at: dest) }
        let job = cloudJob(dest: dest)
        try makeVersion(job, dest: dest, stamp: "2026-09-01-020000")
        let ledger = UploadLedger(url: dest.deletingLastPathComponent().appendingPathComponent("up-\(UUID()).json"))
        defer { try? FileManager.default.removeItem(at: ledger.fileURL) }
        let saysNo = UploadProbe(verified: [.iCloud], timeout: 2, look: { _, _, _ in .status(.uploading) })
        let first = UploadCheck(ledger: ledger, probe: saysNo).rescan(job: job, target: job.target, now: now)
        guard case .notOffsite = first else { Issue.record("setup: \(first)"); return }

        let wedged = UploadProbe(verified: [.iCloud], timeout: 0.2, look: { _, _, _ in
            Thread.sleep(forTimeInterval: 1); return .status(.uploading)
        })
        let refreshed = UploadCheck(ledger: ledger, probe: wedged).refresh(job: job, target: job.target, now: now)
        guard case .notOffsite = refreshed else {
            Issue.record("a look that timed out cleared the warning on refresh: \(refreshed)"); return
        }
        let again = UploadCheck(ledger: ledger, probe: wedged).rescan(job: job, target: job.target, now: now)
        guard case .notOffsite = again else {
            Issue.record("a look that timed out cleared the warning on Check Again: \(again)"); return
        }
    }

    // Green says "every version here is in the cloud". A version in the folder that
    // no look has seen must not be covered by it.
    @Test func greenDoesNotCoverAVersionNobodyLookedAt() throws {
        let dest = scratch("green"); defer { try? FileManager.default.removeItem(at: dest) }
        let job = cloudJob(dest: dest)
        let old = try makeVersion(job, dest: dest, stamp: "2026-09-01-020000")
        let ledger = UploadLedger(url: dest.deletingLastPathComponent().appendingPathComponent("up-\(UUID()).json"))
        defer { try? FileManager.default.removeItem(at: ledger.fileURL) }
        // the old version evicted whole: uploaded
        let probe = UploadProbe(verified: [], timeout: 2, look: { url, _, _ in
            url.path.hasPrefix(old.path) ? .status(.uploaded) : .status(.unknown(nil))
        })
        let check = UploadCheck(ledger: ledger, probe: probe)
        #expect(check.rescan(job: job, target: job.target, now: now) == .uploaded)
        // a newer version lands without being recorded
        try makeVersion(job, dest: dest, stamp: "2026-09-02-020000")
        let after = check.refresh(job: job, target: job.target, now: now)
        #expect(after != .uploaded, "green covers a version nobody looked at")
    }

    // Two drives of one name (a rotation pair) are two destinations: both are on the
    // kit, told apart, each with its own volume UUID.
    @Test func twoDrivesOfOneNameAreBothOnTheKit() {
        var a = Target.externalDrive(id: "d1", name: "Backup", dir: URL(fileURLWithPath: "/Volumes/Backup/Cryo"))
        a.volume = VolumeIdentity(uuid: "AAAA1111-0000-4000-8000-000000000001", name: "Backup", relativePath: "Cryo")
        var b = Target.externalDrive(id: "d2", name: "Backup", dir: URL(fileURLWithPath: "/Volumes/Backup/Cryo"))
        b.volume = VolumeIdentity(uuid: "BBBB2222-0000-4000-8000-000000000002", name: "Backup", relativePath: "Cryo")
        let job = BackupJob(id: "j", name: "Two", libraries: [notesLibrary()], targets: [a, b], format: .sealedDMG,
                            frequency: .manual, createdAt: now)
        let text = RecoveryKit.text(RecoveryKit.document(jobs: [job], escrow: .notNeeded, printedAt: now))
        let lines = text.split(separator: "\n").filter { $0.hasPrefix("Destination: ") }
        #expect(lines.count == 2)
        #expect(Set(lines).count == 2, "the two drives read the same: \(lines)")
        #expect(text.contains("AAAA1111-0000-4000-8000-000000000001") && text.contains("BBBB2222-0000-4000-8000-000000000002"))
    }
}
