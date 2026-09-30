//
//  TransferSourceTests.swift
//  CryoframeKitTests
//
//  A resumed upload reads the staged archive again. A later run of the job can
//  have built its next archive at the same path; the parts of two archives never
//  make one version.
//

import Testing
import Foundation
@testable import CryoframeKit

private func scratch(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-source-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return TempTracker.track(d) }
    defer { free(real) }
    return TempTracker.track(URL(fileURLWithPath: String(cString: real), isDirectory: true))
}

private final class Saved: @unchecked Sendable { var pending: PendingTransfer; init(_ p: PendingTransfer) { pending = p } }

/// send the first part of `p`, then stop, as an interrupted upload does
private func firstPartOnly(_ p: PendingTransfer) -> PendingTransfer {
    let saved = Saved(p), control = RunControl()
    _ = try? ChunkedShipper().ship(p, persist: { s in saved.pending = s; if s.completed.count == 1 { control.cancel() } }, control: control)
    return saved.pending
}

@Suite struct TransferSourceTests {
    // A rebuilt archive of the very same size: the parts already sent don't match it
    // by their hashes, so the upload is dropped rather than finished as a mix.
    @Test func aSameSizedRebuiltArchiveIsNeverResumedInto() throws {
        let work = scratch("same"), dest = scratch("same-dest")
        let source = work.appendingPathComponent("Papers.dmg")
        try Data((0..<3_000_000).map { _ in UInt8.random(in: 0...255) }).write(to: source)
        let store = PendingTransferStore(url: work.appendingPathComponent("pending.json"))
        // the first part is sent, then the upload stops
        let pending = firstPartOnly(PendingTransfer(jobID: "job-1:t7:papers", sourceFile: source.path, baseName: "Papers.dmg",
                                                    totalBytes: 3_000_000, chunkSize: 1_000_000, targetDir: dest.path, format: .sealedDMG))
        #expect(pending.completed.count == 1 && pending.source != nil)
        store.save(pending)
        try? FileManager.default.removeItem(at: source)
        try Data((0..<3_000_000).map { _ in UInt8.random(in: 0...255) }).write(to: source)

        #expect(throws: TransferSourceChanged.self) { try ChunkedShipper().ship(pending, persist: { _ in }) }
        _ = TransferResumer.resumeAll(store: store, reachable: { _ in true }, volumes: FixedVolumeTable([]))
        #expect(store.all().isEmpty, "a transfer that can't be finished stayed recorded")
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent(ArchiveManifest.sidecarName).path))
    }

    // The same file, as it was: the resume goes on from where it stopped.
    @Test func theSameArchiveResumes() throws {
        let work = scratch("resume"), dest = scratch("resume-dest")
        let source = work.appendingPathComponent("Papers.dmg")
        let data = Data((0..<3_000_000).map { _ in UInt8.random(in: 0...255) })
        try data.write(to: source)
        var pending = firstPartOnly(PendingTransfer(jobID: "job-1:t7:papers", sourceFile: source.path, baseName: "Papers.dmg",
                                                    totalBytes: 3_000_000, chunkSize: 1_000_000, targetDir: dest.path, format: .sealedDMG))
        #expect(pending.completed.count == 1)
        let m = try ChunkedShipper().ship(pending, persist: { _ in })
        var whole = Data()
        for a in m.artifacts { whole.append(try Data(contentsOf: dest.appendingPathComponent(a.name))) }
        #expect(whole == data)
        // a record from before the stamp: checked by the parts' hashes, and resumed
        pending.source = nil
        #expect(throws: Never.self) { try ChunkedShipper().ship(pending, persist: { _ in }) }
    }
}
