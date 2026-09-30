//
//  PendingTransferDriveTests.swift
//  CryoframeKitTests
//
//  An interrupted transfer is finished on the drive it began on. Two drives of one
//  name mount at one path, so a transfer begun on one "T7" and resumed by path
//  would put its last parts on the other.
//

import Testing
import Foundation
@testable import CryoframeKit

private let hdiutil = "/usr/bin/hdiutil"
private let start = Date(timeIntervalSince1970: 1_790_000_000)

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-pdrive-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return TempTracker.track(d) }
    defer { free(real) }
    return TempTracker.track(URL(fileURLWithPath: String(cString: real), isDirectory: true))
}

private func drive(_ mount: URL, uuid: String, name: String = "T7") -> MountedVolume {
    MountedVolume(mountPoint: mount, uuid: uuid, name: name, isInternal: false, isRemovable: true, isEjectable: true)
}

/// a staged archive and a pending transfer of it into `dest`, begun on `uuid`
private func pending(in base: URL, dest: URL, uuid: String?) throws -> (PendingTransferStore, PendingTransfer) {
    let src = base.appendingPathComponent("scratch/job/build/lib/Lib.zip")
    try FileManager.default.createDirectory(at: src.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 7, count: 300).write(to: src)
    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    let store = PendingTransferStore(url: base.appendingPathComponent("pending.json"))
    let p = PendingTransfer(jobID: "job:t7:lib", sourceFile: src.path, baseName: "Lib.zip", totalBytes: 300, chunkSize: 100,
                            targetDir: dest.path, format: .sealedZip, volumeUUID: uuid)
    store.save(p)
    return (store, p)
}

@Suite(.serialized) struct PendingTransferDriveTests {
    @Test func aTransferBegunOnOneDriveIsNotFinishedOnAnotherOfItsName() throws {
        let base = folder("other")
        let t7 = base.appendingPathComponent("T7"), dest = t7.appendingPathComponent("Backups/Lib/2026-09-30-020000")
        let (store, _) = try pending(in: base, dest: dest, uuid: "DRIVE-A")
        let resumed = TransferResumer.resumeAll(store: store, reachable: { _ in true },
                                                volumes: FixedVolumeTable([drive(t7, uuid: "DRIVE-B")]))
        #expect(resumed.isEmpty)
        #expect(store.all().count == 1)                                     // waits for its own drive
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: dest.path)) ?? []).isEmpty)
    }

    @Test func onItsOwnDriveItIsFinished() throws {
        let base = folder("own")
        let t7 = base.appendingPathComponent("T7"), dest = t7.appendingPathComponent("Backups/Lib/2026-09-30-020000")
        let (store, _) = try pending(in: base, dest: dest, uuid: "DRIVE-A")
        let resumed = TransferResumer.resumeAll(store: store, reachable: { _ in true },
                                                volumes: FixedVolumeTable([drive(t7, uuid: "DRIVE-A")]))
        #expect(resumed == ["job:t7:lib"])
        #expect(store.all().isEmpty)
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent(ArchiveManifest.sidecarName).path))
    }

    @Test func aTransferRecordedBefore16ResumesAsBefore() throws {
        let base = folder("old")
        let dest = base.appendingPathComponent("Backups/Lib/2026-09-30-020000")
        let (store, _) = try pending(in: base, dest: dest, uuid: nil)
        #expect(TransferResumer.resumeAll(store: store, reachable: { _ in true },
                                          volumes: FixedVolumeTable([])) == ["job:t7:lib"])
    }

    @Test func aRecordWithoutADriveDecodes() throws {
        let json = #"[{"jobID":"j","sourceFile":"/s","baseName":"b","totalBytes":1,"chunkSize":1,"targetDir":"/t","format":"sealedZip"}]"#
        let list = try JSONDecoder().decode([PendingTransfer].self, from: Data(json.utf8))
        #expect(list.first?.volumeUUID == nil)
        #expect(list.first?.owningJobID == "j")
    }

    @Test func aDriveThatCantBeToldIsNotAssumedToBeIt() throws {
        let p = PendingTransfer(jobID: "j", sourceFile: "/s", baseName: "b", totalBytes: 1, chunkSize: 1, targetDir: "/t",
                                format: .sealedZip, volumeUUID: "DRIVE-A")
        #expect(!p.isOnItsDrive(nil))
        #expect(p.isOnItsDrive(drive(URL(fileURLWithPath: "/t"), uuid: "DRIVE-A")))
    }

    // the run records the drive the transfer goes to
    @Test func aRunRecordsTheDriveItsTransferGoesTo() async throws {
        let base = folder("run")
        let mnt = base.appendingPathComponent("vol")
        try FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)
        let dmg = base.appendingPathComponent("src.dmg")
        let made = try ProcessCommandRunner().run(hdiutil, ["create", "-size", "20m", "-fs", "HFS+", "-volname", "Src", dmg.path])
        try #require(made.ok, "\(made.stderr)")
        let attached = try DiskImageGate.serialized {
            try ProcessCommandRunner().runRetryingBusy(hdiutil, ["attach", dmg.path, "-mountpoint", mnt.path, "-nobrowse", "-owners", "on"])
        }
        try #require(attached.ok && MountPoint.isMounted(mnt), "\(attached.stderr)")
        defer { MountPoint.detach(mnt, runner: ProcessCommandRunner()) }
        let papers = mnt.appendingPathComponent("Papers")
        try FileManager.default.createDirectory(at: papers, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: papers.appendingPathComponent("a.bin"))

        let t7 = base.appendingPathComponent("T7"), dest = t7.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let lib = ContentType.genericFolder(id: "papers", displayName: "Papers", path: .absolute(papers.path))
        let job = BackupJob(name: "Papers", libraries: [lib], target: .externalDrive(id: "t7", name: "T7", dir: dest),
                            format: .sealedZip, frequency: .manual, createdAt: start)
        let store = PendingTransferStore(url: base.appendingPathComponent("pending.json"))
        let seen = Seen()
        let exec = JobExecutor(helper: FakePrivilegedHelper(), detector: FakeProcessDetector(),
                               scratchBase: base.appendingPathComponent("scratch"), chunkSize: 64, pendingStore: store,
                               volumes: FixedVolumeTable([drive(t7, uuid: "DRIVE-A")]))
        let outcome = try await exec.run(job, ownerUID: getuid(), now: start, onProgress: { p in
            if p.stage == .transferring { seen.add(store.all().compactMap(\.volumeUUID)) }
        })
        guard case .finished = outcome else { Issue.record("\(outcome)"); return }
        #expect(seen.values.contains("DRIVE-A"), "\(seen.values)")
        #expect(!seen.values.contains { $0 != "DRIVE-A" })
    }
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [String] = []
    func add(_ v: [String]) { lock.lock(); all += v; lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return all }
}
