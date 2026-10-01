//
//  PruneTransferTests.swift
//  CryoframeKitTests
//
//  Retention sweeps version folders without a manifest as a failed run's leftovers.
//  An interrupted upload's folder has no manifest either, until its last part: it
//  was swept, its parts with it, and its record then named a folder that wasn't
//  there, so it never finished and its staged archive stayed in scratch for good.
//  Also: what retention would delete is one list, the same one the job editor
//  shows before a save (see JobEditImpact).
//

import Testing
import Foundation
@testable import CryoframeKit

private func scratch(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-prunexfer-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return TempTracker.track(d) }
    defer { free(real) }
    return TempTracker.track(URL(fileURLWithPath: String(cString: real), isDirectory: true))
}

private let papers = ContentType.genericFolder(id: "papers", displayName: "Papers", path: .absolute("/nowhere/Papers"))

private func version(_ folder: URL, _ stamp: String, manifest: Bool = true) throws -> URL {
    let v = folder.appendingPathComponent(stamp)
    try FileManager.default.createDirectory(at: v, withIntermediateDirectories: true)
    try Data("zip \(stamp)".utf8).write(to: v.appendingPathComponent(manifest ? "Papers.zip" : "Papers.zip.part.000"))
    if manifest {
        _ = try ArchiveManifest.write(try ArchiveManifest.build(for: ArchiveResult(artifacts: [v.appendingPathComponent("Papers.zip")],
                                                                                   format: .sealedZip)), toDir: v)
    }
    return v
}

@Suite struct PruneTransferTests {
    @Test func anInterruptedUploadsFolderIsNotSweptAsALeftover() throws {
        let folder = scratch("upload")
        let partial = try version(folder, "2026-09-30-020000", manifest: false)
        let husk = try version(folder, "2026-09-29-020000", manifest: false)
        try version(folder, "2026-09-28-020000")
        JobExecutor.pruneVersions(folders: [(papers, folder)], policy: .keepLast(5),
                                  transferring: { DestinationRules.contains($0, partial) || DestinationRules.contains(partial, $0) }, confirmed: { _, _ in true })
        #expect(FileManager.default.fileExists(atPath: partial.appendingPathComponent("Papers.zip.part.000").path))
        #expect(!FileManager.default.fileExists(atPath: husk.path))            // a real leftover still goes
    }

    @Test func thePlanIsWhatIsDeleted() throws {
        let folder = scratch("plan")
        for d in 1...6 { try version(folder, String(format: "2026-09-%02d-020000", d)) }
        let husk = try version(folder, "2026-09-07-020000", manifest: false)
        let plan = JobExecutor.prunePlan(folders: [(papers, folder)], policy: .keepLast(2))
        #expect(plan.husks.map(\.lastPathComponent) == [husk.lastPathComponent])
        #expect(plan.versions.map(\.url.lastPathComponent).sorted() ==
                ["2026-09-01-020000", "2026-09-02-020000", "2026-09-03-020000", "2026-09-04-020000"])
        #expect(FileManager.default.fileExists(atPath: husk.path))            // planning deletes nothing
        JobExecutor.pruneVersions(folders: [(papers, folder)], policy: .keepLast(2), confirmed: { _, _ in true })
        let left = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        #expect(left == ["2026-09-05-020000", "2026-09-06-020000"])
    }
}
