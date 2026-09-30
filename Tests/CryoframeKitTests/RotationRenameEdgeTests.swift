//
//  RotationRenameEdgeTests.swift
//  CryoframeKitTests
//
//  A 1.6 rotation needs no run history as evidence: each drive is known by its
//  volume, and each library folder by its identity. Renamed while it was away, the
//  other drive is still itself, and its next copy goes into the folder it already
//  has, with no runs recorded at all.
//

import Testing
import Foundation
@testable import CryoframeKit

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-rotren-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

private let day: TimeInterval = 86_400
private let start = Date(timeIntervalSince1970: 1_790_000_000)

@Suite(.serialized) struct RotationRenameEdgeTests {
    @Test func aRenamedRotationDriveIsWrittenIntoItsOwnFolderWithNoHistory() async throws {
        let base = folder("run")
        let mnt = base.appendingPathComponent("vol")
        try FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)
        let hdiutil = "/usr/bin/hdiutil"
        let made = try ProcessCommandRunner().run(hdiutil, ["create", "-size", "20m", "-fs", "HFS+", "-volname", "Src",
                                                            base.appendingPathComponent("src.dmg").path])
        try #require(made.ok, "\(made.stderr)")
        let attached = try DiskImageGate.serialized {
            try ProcessCommandRunner().runRetryingBusy(hdiutil, ["attach", base.appendingPathComponent("src.dmg").path,
                                                                 "-mountpoint", mnt.path, "-nobrowse", "-owners", "on"])
        }
        try #require(attached.ok && MountPoint.isMounted(mnt), "\(attached.stderr)")
        defer {
            MountPoint.detach(mnt, runner: ProcessCommandRunner())
            try? FileManager.default.removeItem(at: base)
        }
        let lib = mnt.appendingPathComponent("Papers")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: lib.appendingPathComponent("a.txt"))
        let dirA = base.appendingPathComponent("T7"), dirB = base.appendingPathComponent("T7 1")
        for d in [dirA, dirB] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        func drive(_ id: String, at dir: URL) -> Target {
            var t = Target.externalDrive(id: id, name: "T7", dir: dir)
            t.volume = VolumeIdentity(uuid: "UUID-\(id)", name: "T7", relativePath: "")
            t.rotation = Rotation(group: "offsite", addedAt: nil)
            return t
        }
        let papers = ContentType.genericFolder(id: "papers", displayName: "Papers", path: .absolute(lib.path))
        let job = BackupJob(name: "Papers", libraries: [papers], targets: [drive("a", at: dirA), drive("b", at: dirB)],
                            format: .sealedZip, frequency: .daily(hour: 2, minute: 0), createdAt: start)
        let store = JobStore(url: base.appendingPathComponent("jobs.json"))
        store.upsert(job)
        func executor(_ here: [(String, URL, String)]) -> JobExecutor {
            let table = FixedVolumeTable(here.map { MountedVolume(mountPoint: $0.1, uuid: "UUID-\($0.0)", name: $0.2,
                                                                  isInternal: false, isRemovable: true, isEjectable: true) })
            return JobExecutor(helper: FakePrivilegedHelper(), detector: FakeProcessDetector(),
                               scratchBase: base.appendingPathComponent("scratch"), jobStore: store, runHistory: { [] }, volumes: table)
        }
        func libraryFolders(_ d: URL) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []).filter { name in var isDir: ObjCBool = false
                return !name.hasPrefix(".") && FileManager.default.fileExists(atPath: d.appendingPathComponent(name).path, isDirectory: &isDir) && isDir.boolValue }.sorted()
        }

        for (i, (id, dir)) in [("a", dirA), ("b", dirB)].enumerated() {
            let o = try await executor([(id, dir, "T7")]).run(store.load().jobs.first { $0.id == job.id } ?? job,
                                                             ownerUID: getuid(), now: start.addingTimeInterval(Double(i + 1) * day))
            guard case .finished(let r, _) = o else { Issue.record("\(id): \(o)"); return }
            #expect(summarizeRun(r).kind == .completed, "\(id): \(r)")
        }
        let beforeB = libraryFolders(dirB)
        try #require(beforeB.count == 1, "\(beforeB)")
        try #require(LibraryIdentity.read(in: dirB.appendingPathComponent(beforeB[0])) != nil)

        // drive B renamed "Offsite" while away; it comes home at a new mount point
        let renamed = base.appendingPathComponent("Offsite")
        try FileManager.default.moveItem(at: dirB, to: renamed)
        let o = try await executor([("b", renamed, "Offsite")]).run(store.load().jobs.first { $0.id == job.id } ?? job,
                                                                    ownerUID: getuid(), now: start.addingTimeInterval(9 * day))
        guard case .finished(let r, _) = o else { Issue.record("renamed: \(o)"); return }
        #expect(summarizeRun(r).kind == .completed, "\(r)")
        #expect(libraryFolders(renamed) == beforeB, "a new folder instead of its own: \(libraryFolders(renamed))")
        #expect(RestoreDiscovery.scan(renamed.appendingPathComponent(beforeB[0]), maxDepth: 1).count == 2)
    }
}
