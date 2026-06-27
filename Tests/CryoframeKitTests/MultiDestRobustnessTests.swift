//
//  MultiDestRobustnessTests.swift
//  CryoframeKitTests
//
//  Regression coverage for the multi-destination QA pass: resilient job decode (F2),
//  back-compat target key (F2), single→multi target migration, and the shared-source
//  resume fix (F1).
//

import Testing
import Foundation
@testable import CryoframeKit

private func tmpDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("cf-md-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func sampleJob(_ name: String) -> BackupJob {
    BackupJob(name: name, libraries: [.photos],
              target: .localVolume(id: "t", name: "Disk", dir: URL(fileURLWithPath: "/x")),
              format: .sealedZip, frequency: .manual, createdAt: Date(timeIntervalSince1970: 0))
}

// MARK: - F2: resilient decode

@Test func scheduleStateSkipsUndecodableJobsInsteadOfLosingAll() throws {
    let goodObj = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(sampleJob("Good")))
    let state: [String: Any] = ["jobs": [goodObj, ["garbage": true]], "lastRun": [String: Double]()]
    let data = try JSONSerialization.data(withJSONObject: state)

    let decoded = try JSONDecoder().decode(ScheduleState.self, from: data)
    #expect(decoded.jobs.count == 1)                 // the good one survived
    #expect(decoded.jobs.first?.name == "Good")
    #expect(decoded.droppedJobs == 1)                // and we know one was dropped
}

@Test func backupJobEncodesLegacyTargetKeyForOldBuilds() throws {
    let job = BackupJob(name: "J", libraries: [.photos],
                        targets: [.localVolume(id: "a", name: "A", dir: URL(fileURLWithPath: "/a")),
                                  .localVolume(id: "b", name: "B", dir: URL(fileURLWithPath: "/b"))],
                        format: .sealedZip, frequency: .manual, createdAt: Date(timeIntervalSince1970: 0))
    let obj = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(job)) as! [String: Any]
    #expect(obj["targets"] != nil)
    #expect(obj["target"] != nil)                    // legacy single-target key written for downgrade safety
}

@Test func backupJobMigratesPre11SingleTargetJSON() throws {
    var obj = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(sampleJob("Old"))) as! [String: Any]
    obj.removeValue(forKey: "targets")               // simulate a pre-1.1 record: only "target"
    let data = try JSONSerialization.data(withJSONObject: obj)

    let decoded = try JSONDecoder().decode(BackupJob.self, from: data)
    #expect(decoded.targets.count == 1)
    #expect(decoded.target.id == "t")
}

// MARK: - F1: shared scratch source survives until the last destination resumes

@Test func resumeKeepsSharedSourceUntilEveryDestinationIsDone() throws {
    let base = tmpDir(); defer { try? FileManager.default.removeItem(at: base) }
    let buildDir = base.appendingPathComponent("scratch/job/build/lib", isDirectory: true)
    try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
    let src = buildDir.appendingPathComponent("Lib.dmg")
    try Data(repeating: 7, count: 5_000).write(to: src)

    let d1 = base.appendingPathComponent("d1"); let d2 = base.appendingPathComponent("d2")
    for d in [d1, d2] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }

    let store = PendingTransferStore(url: base.appendingPathComponent("pending.json"))
    // two destinations, ONE shared build artifact — the multi-destination case.
    store.save(PendingTransfer(jobID: "job:d1:lib", sourceFile: src.path, baseName: "Lib.dmg",
                               totalBytes: 5_000, chunkSize: 1_000, targetDir: d1.path, format: .sealedDMG, encrypted: false))
    store.save(PendingTransfer(jobID: "job:d2:lib", sourceFile: src.path, baseName: "Lib.dmg",
                               totalBytes: 5_000, chunkSize: 1_000, targetDir: d2.path, format: .sealedDMG, encrypted: false))

    let resumed = TransferResumer.resumeAll(store: store, reachable: { _ in true })

    // before the fix, resuming the first deleted the shared source and orphaned the second.
    #expect(Set(resumed) == ["job:d1:lib", "job:d2:lib"])
    #expect(store.all().isEmpty)                                         // both completed, nothing stuck
    #expect(!FileManager.default.fileExists(atPath: src.path))          // source cleaned only after the last
    #expect(((try? FileManager.default.contentsOfDirectory(atPath: d1.path)) ?? []).contains { $0.hasPrefix("Lib.dmg.part") })
    #expect(((try? FileManager.default.contentsOfDirectory(atPath: d2.path)) ?? []).contains { $0.hasPrefix("Lib.dmg.part") })
}
