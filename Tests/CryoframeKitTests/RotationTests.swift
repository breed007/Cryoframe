//
//  RotationTests.swift
//  CryoframeKitTests
//
//  Drives that take turns: a drive that's away isn't a fault, each drive has its
//  own last copy, one gone too long is named with its age, drives are known by
//  their volume UUID, and a job whose other drive is off-site stays protected.
//

import Testing
import Foundation
@testable import CryoframeKit

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-rot-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

private let day: TimeInterval = 86_400
private let start = Date(timeIntervalSince1970: 1_790_000_000)

private func drive(_ id: String, _ name: String, at dir: URL = URL(fileURLWithPath: "/Volumes/x"), group: String? = "offsite",
                   addedAt: Date? = nil) -> Target {
    var t = Target.externalDrive(id: id, name: name, dir: dir)
    t.volume = VolumeIdentity(uuid: "UUID-\(id)", name: name, relativePath: "")
    if let group { t.rotation = Rotation(group: group, addedAt: addedAt) }
    return t
}

private func run(_ job: BackupJob, _ outcome: RunOutcomeKind, at: Date) -> RunRecord {
    RunRecord(id: UUID().uuidString, jobID: job.id, jobName: job.name, startedAt: at.addingTimeInterval(-60), finishedAt: at,
              trigger: "scheduled", outcome: outcome, summary: "", libraries: [], bytes: 0, warning: nil)
}

@Suite struct RotationTests {

    // MARK: the model

    @Test func aRotationIsOnePlace() {
        let nas = Target.localVolume(id: "nas", name: "NAS", dir: URL(fileURLWithPath: "/Volumes/NAS"))
        let job = BackupJob(name: "J", libraries: [.photos], targets: [drive("a", "T7 A"), nas, drive("b", "T7 B")],
                            format: .sealedDMG, frequency: .daily(hour: 2, minute: 0), createdAt: start)
        #expect(job.places.map { $0.map(\.id) } == [["a", "b"], ["nas"]])
        #expect(RotationRules.name(of: job.places[0]) == "T7 A or T7 B")
    }

    @Test func aDriveGoneTooLongIsNamedWithItsAge() {
        let job = BackupJob(name: "J", libraries: [.photos], targets: [drive("a", "T7 A"), drive("b", "T7 B", addedAt: start)],
                            format: .sealedDMG, frequency: .daily(hour: 2, minute: 0), createdAt: start)
        let now = start.addingTimeInterval(20 * day)
        let away = RotationRules.awayTooLong(job, lastCopies: ["a": now.addingTimeInterval(-day), "b": start.addingTimeInterval(3 * day)], now: now)
        #expect(away.map(\.name) == ["T7 B"] && away[0].lastCopy == start.addingTimeInterval(3 * day))
        // a drive not yet connected since it joined gets its chance first
        let fresh = RotationRules.awayTooLong(job, lastCopies: ["a": now], now: start.addingTimeInterval(10 * day))
        #expect(fresh.isEmpty)
    }

    // MARK: the dashboard

    // The run that skipped the away drive was a good one: a week of them keeps the
    // job protected (it went critical before), until the away drive passes its limit.
    @Test func aJobWhoseOtherDriveIsAwayStaysProtected() {
        let job = BackupJob(name: "Photos", libraries: [.photos], targets: [drive("a", "T7 A"), drive("b", "T7 B")],
                            format: .sealedDMG, frequency: .daily(hour: 2, minute: 0), createdAt: start)
        var now = start.addingTimeInterval(9 * day)
        let latest = run(job, .completed, at: now.addingTimeInterval(-3600))
        var copies = ["a": latest.finishedAt, "b": start.addingTimeInterval(1 * day)]
        var s = ProtectionVerdict.standing(of: job, latest: latest, lastGood: latest.finishedAt, health: nil, now: now,
                                           awayTooLong: RotationRules.awayTooLong(job, lastCopies: copies, now: now))
        #expect(s == .healthy)
        now = start.addingTimeInterval(20 * day)
        let later = run(job, .completed, at: now.addingTimeInterval(-3600))
        copies["a"] = later.finishedAt
        s = ProtectionVerdict.standing(of: job, latest: later, lastGood: later.finishedAt, health: nil, now: now,
                                       awayTooLong: RotationRules.awayTooLong(job, lastCopies: copies, now: now))
        #expect(s.level == .attention)
        #expect(s.reason(now: now) == "hasn't had a copy on T7 B in 19 days; connect it for its turn")
        let v = ProtectionVerdict.compute(jobs: [job], lastRecords: [job.id: later], lastHealth: [:], runningCount: 0,
                                          lastGood: [job.id: later.finishedAt], now: now, lastCopies: [job.id: copies])
        #expect(v.level == .attention && v.subtitle.contains("T7 B"))
    }

    // MARK: the job store

    @Test func lastCopiesAreKeptAndOldStoresStillRead() throws {
        let base = folder("store"); defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("jobs.json")
        try Data(#"{"jobs":[],"lastRun":{}}"#.utf8).write(to: url)
        let store = JobStore(url: url)
        #expect(store.load().lastCopy.isEmpty)
        store.recordCopies(jobID: "j", targetIDs: ["a"], at: start)
        store.recordRun(id: "j", at: start)
        #expect(store.load().lastCopy == ["j": ["a": start]])
    }

    // MARK: runs

    // A job to a rotation of two drives: with one connected and the other away, the
    // run writes to the one, reports no failure for the other, and each drive keeps
    // its own last copy. Swapped, the other drive gets its copy. With neither, the
    // run can't write anything and says which drives it looked for.
    @Test func aRunWritesToTheDriveThatsHereAndSkipsTheOneAway() async throws {
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
        let dirA = base.appendingPathComponent("A"), dirB = base.appendingPathComponent("B")
        for d in [dirA, dirB] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let papers = ContentType.genericFolder(id: "papers", displayName: "Papers", path: .absolute(lib.path))
        let job = BackupJob(name: "Papers", libraries: [papers], targets: [drive("a", "T7 A", at: dirA), drive("b", "T7 B", at: dirB)],
                            format: .sealedZip, frequency: .daily(hour: 2, minute: 0), createdAt: start)
        let store = JobStore(url: base.appendingPathComponent("jobs.json"))
        store.upsert(job)
        func volumes(_ here: [(String, URL)]) -> FixedVolumeTable {
            FixedVolumeTable(here.map { MountedVolume(mountPoint: $0.1, uuid: "UUID-\($0.0)", name: "T7 \($0.0.uppercased())",
                                                      isInternal: false, isRemovable: true, isEjectable: true) })
        }
        func executor(_ table: FixedVolumeTable) -> JobExecutor {
            JobExecutor(helper: FakePrivilegedHelper(), detector: FakeProcessDetector(),
                        scratchBase: base.appendingPathComponent("scratch"), jobStore: store, volumes: table)
        }

        let first = start.addingTimeInterval(day)
        let a = try await executor(volumes([("a", dirA)])).run(job, ownerUID: getuid(), now: first)
        guard case .finished(let results, _) = a else { Issue.record("\(a)"); return }
        #expect(summarizeRun(results).kind == .completed, "\(results)")
        #expect(results.allSatisfy { if case .completed(_, "T7 A", _, _, _) = $0 { return true }; return false }, "\(results)")
        #expect(RestoreDiscovery.scan(dirA).count == 1 && RestoreDiscovery.scan(dirB).isEmpty)
        #expect(store.load().lastCopy[job.id] == ["a": first])

        let second = start.addingTimeInterval(8 * day)
        let b = try await executor(volumes([("b", dirB)])).run(job, ownerUID: getuid(), now: second)
        guard case .finished(let results2, _) = b else { Issue.record("\(b)"); return }
        #expect(summarizeRun(results2).kind == .completed, "\(results2)")
        #expect(store.load().lastCopy[job.id] == ["a": first, "b": second])

        do {
            _ = try await executor(volumes([])).run(job, ownerUID: getuid(), now: second.addingTimeInterval(day))
            Issue.record("ran with neither drive connected")
        } catch let TargetError.unavailable(why) {
            #expect(why == "none of T7 A or T7 B is connected")
        }
    }

    // A different drive with a destination's name: never written to.
    @Test func anotherDriveOfTheSameNameIsNeverWrittenTo() async throws {
        let base = folder("wrong"); defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.appendingPathComponent("T7")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let papers = ContentType.genericFolder(id: "papers", displayName: "Papers", path: .absolute(base.path))
        let job = BackupJob(name: "Papers", libraries: [papers], target: drive("a", "T7", at: dir, group: nil),
                            format: .sealedZip, frequency: .manual, createdAt: start)
        let table = FixedVolumeTable([MountedVolume(mountPoint: dir, uuid: "SOMEONE-ELSES", name: "T7", isInternal: false)])
        let exec = JobExecutor(helper: FakePrivilegedHelper(), detector: FakeProcessDetector(),
                               scratchBase: base.appendingPathComponent("scratch"), volumes: table)
        do {
            _ = try await exec.run(job, ownerUID: getuid(), now: start)
            Issue.record("wrote to another drive")
        } catch let TargetError.unavailable(why) {
            #expect(why.contains("a different drive named “T7”"), "\(why)")
        }
        #expect((try FileManager.default.contentsOfDirectory(atPath: dir.path)).isEmpty)
    }
    // Destinations of one name are told apart by their drives; the rest keep their
    // names. Drives whose UUIDs start alike get more of it; one with none recorded,
    // its place.
    @Test func destinationsOfOneNameAreLabeledByTheirDrive() {
        func t(_ id: String, _ name: String, _ uuid: String?) -> Target {
            var t = Target.externalDrive(id: id, name: name, dir: URL(fileURLWithPath: "/Volumes/\(id)/Backups"))
            t.volume = uuid.map { VolumeIdentity(uuid: $0, name: "T7", relativePath: "Backups") }
            return t
        }
        let a = t("a", "Backups on T7", "4f2a19c0-0000-0000-0000-000000000001")
        let b = t("b", "Backups on T7", "9C1E0000-0000-0000-0000-000000000002")
        let nas = t("n", "Backups on NAS", nil)
        let job = BackupJob(name: "J", libraries: [.photos], targets: [a, b, nas], format: .sealedDMG,
                            frequency: .manual, createdAt: Date(timeIntervalSince1970: 0))
        #expect(job.destinationLabels == ["a": "Backups on T7 (drive 4F2A)", "b": "Backups on T7 (drive 9C1E)", "n": "Backups on NAS"])
        let alike = BackupJob(name: "J", libraries: [.photos], targets: [a, t("c", "Backups on T7", "4F2A19C1"), t("d", "Backups on T7", nil)],
                              format: .sealedDMG, frequency: .manual, createdAt: Date(timeIntervalSince1970: 0))
        #expect(alike.destinationLabels == ["a": "Backups on T7 (1 of 3)", "c": "Backups on T7 (2 of 3)", "d": "Backups on T7 (3 of 3)"])
        let two = BackupJob(name: "J", libraries: [.photos], targets: [a, t("c", "Backups on T7", "4F2A19C1")],
                            format: .sealedDMG, frequency: .manual, createdAt: Date(timeIntervalSince1970: 0))
        #expect(two.destinationLabels == ["a": "Backups on T7 (drive 4F2A19C0)", "c": "Backups on T7 (drive 4F2A19C1)"])
    }
}
