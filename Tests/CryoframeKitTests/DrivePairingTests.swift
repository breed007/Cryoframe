//
//  DrivePairingTests.swift
//  CryoframeKitTests
//
//  "Is this one of your drives?" (see DrivePairing), and the editor's destination
//  operations: the main destination, taking turns, and pairing a drive of the same
//  name under one destination.
//

import Testing
import Foundation
@testable import CryoframeKit

private let start = Date(timeIntervalSince1970: 1_790_000_000)
private let day: TimeInterval = 86_400

private func scratch(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-pair-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return TempTracker.track(d) }
    defer { free(real) }
    return TempTracker.track(URL(fileURLWithPath: String(cString: real), isDirectory: true))
}

private let papers = ContentType.genericFolder(id: "papers", displayName: "Papers", path: .absolute("/Users/me/Papers"))

private func drive(_ mount: URL, uuid: String) -> MountedVolume {
    MountedVolume(mountPoint: mount, uuid: uuid, name: "T7", isInternal: false, isRemovable: true, isEjectable: true)
}

/// a destination learned on drive A (as a 1.6 run records a 1.5 one), at `dir`
private func target(_ dir: URL) -> Target {
    var t = Target.externalDrive(id: "t7", name: "Backups on T7", dir: dir)
    t.volume = VolumeIdentity(uuid: "DRIVE-A", name: "T7", relativePath: "Backups", learnedAt: start)
    return t
}

private func job(_ t: Target, format: FormatChoice, retention: RetentionPolicy = .keepAll) -> BackupJob {
    BackupJob(id: "job-1", name: "Papers", libraries: [papers], target: t, format: format, frequency: .manual,
              retention: retention, createdAt: start)
}

private func version(in dir: URL, _ date: Date) throws {
    let at = dir.appendingPathComponent(VersionStamp.string(date))
    try FileManager.default.createDirectory(at: at, withIntermediateDirectories: true)
    let f = at.appendingPathComponent("Papers.zip")
    try Data("zip \(date)".utf8).write(to: f)
    _ = try ArchiveManifest.write(try ArchiveManifest.build(for: ArchiveResult(artifacts: [f], format: .sealedZip)), toDir: at)
}

private func mirrorTop(in dir: URL) throws {
    let sb = dir.appendingPathComponent("Papers.sparsebundle")
    try FileManager.default.createDirectory(at: sb.appendingPathComponent("bands"), withIntermediateDirectories: true)
    try Data(repeating: 1, count: 5000).write(to: sb.appendingPathComponent("bands/0"))
    _ = try ArchiveManifest.write(try ArchiveManifest.build(for: ArchiveResult(artifacts: [sb], format: .liveMirror)), toDir: dir)
}

@Suite struct DrivePairingTests {
    @Test func aMirrorJobIsToldItsCopyThereIsReplaced() throws {
        let t7 = scratch("mirror"), dest = t7.appendingPathComponent("Backups")
        let legacy = dest.appendingPathComponent("Papers")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try mirrorTop(in: legacy)
        try version(in: legacy, start)
        let t = target(dest), j = job(t, format: .liveMirror(sizeGB: 1))
        let look = try #require(DrivePairing.look(t, job: j, jobs: [j], volumes: FixedVolumeTable([drive(t7, uuid: "DRIVE-B")])))
        #expect(look.refusal == nil)
        #expect(look.drive.uuid == "DRIVE-B" && look.drive.relativePath == "Backups")
        let lib = try #require(look.libraries.first)
        #expect(lib.copy != nil && (lib.copy?.bytes ?? 0) > 0)
        #expect(lib.versions == [start] && lib.deletes == 0)
        #expect(lib.effects.first?.hasPrefix("The next backup replaces the copy from") == true)
        #expect(lib.effects.last?.contains("stay as they are") == true)
    }

    @Test func aSealedJobIsToldHowManyVersionsItsKeepRuleDeletesAndThatIsWhatGoes() throws {
        let t7 = scratch("sealed"), dest = t7.appendingPathComponent("Backups")
        let legacy = dest.appendingPathComponent("Papers")
        for d in 0..<4 { try version(in: legacy, start.addingTimeInterval(Double(d) * day)) }
        let t = target(dest), j = job(t, format: .sealedZip, retention: .keepLast(2))
        let now = start.addingTimeInterval(10 * day)
        let look = try #require(DrivePairing.look(t, job: j, jobs: [j], volumes: FixedVolumeTable([drive(t7, uuid: "DRIVE-B")]), now: now))
        let lib = try #require(look.libraries.first)
        #expect(lib.versions.count == 4 && lib.deletes == 3)

        // what the next run does: take the folder over, add its version, prune
        let folder = try LibraryFolders.prepare(job: j, library: papers, in: dest, jobs: [j], isOpen: { _ in false }).folder
        #expect(folder.path == legacy.path)
        try version(in: folder, now)
        let before = LibraryFolders.versionNames(in: folder).count
        JobExecutor.pruneVersions(folders: [(papers, folder)], policy: j.retention)
        #expect(before - LibraryFolders.versionNames(in: folder).count == lib.deletes)
    }

    @Test func aDriveHoldingAnotherJobsBackupsIsNotOffered() throws {
        let t7 = scratch("foreign"), dest = t7.appendingPathComponent("Backups")
        let theirs = dest.appendingPathComponent("Mail")
        try FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)
        try LibraryIdentity(jobID: "someone-else", libraryID: "mail", name: "Mail", jobName: "Old Mac").write(in: theirs)
        let t = target(dest), j = job(t, format: .liveMirror(sizeGB: 1))
        let look = try #require(DrivePairing.look(t, job: j, jobs: [j], volumes: FixedVolumeTable([drive(t7, uuid: "DRIVE-B")])))
        #expect(look.refusal?.contains("isn't on this Mac") == true)
        #expect(look.libraries.isEmpty)

        // a job of this Mac that already writes to this very drive doesn't count against it
        var other = BackupJob(id: "someone-else", name: "Old Mac", libraries: [papers], target: target(dest),
                              format: .sealedZip, frequency: .manual, createdAt: start)
        other.targets[0].volume = VolumeIdentity(uuid: "DRIVE-B", name: "T7", relativePath: "Backups")
        #expect(DrivePairing.look(t, job: j, jobs: [j, other], volumes: FixedVolumeTable([drive(t7, uuid: "DRIVE-B")]))?.refusal == nil)
    }

    @Test func onlyAnotherDriveOfTheNameIsAsked() throws {
        let t7 = scratch("same"), dest = t7.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let t = target(dest), j = job(t, format: .liveMirror(sizeGB: 1))
        #expect(DrivePairing.look(t, job: j, jobs: [j], volumes: FixedVolumeTable([drive(t7, uuid: "DRIVE-A")])) == nil)
        var paired = t
        paired.otherVolumes = [VolumeIdentity(uuid: "DRIVE-B", name: "T7", relativePath: "Backups")]
        #expect(DrivePairing.look(paired, job: j, jobs: [j], volumes: FixedVolumeTable([drive(t7, uuid: "DRIVE-B")])) == nil)
    }

    // MARK: the editor's operations

    private func draft(_ targets: [Target]) -> JobDraftState {
        var d = JobDraftState(libraries: [papers], targets: targets, now: start)
        d.selectedTargetIDs = targets.map(\.id)
        return d
    }

    @Test func pairingIsADraftEditThatSaveMergesAndCancelForgets() {
        let t = target(URL(fileURLWithPath: "/Volumes/T7/Backups"))
        let base = job(t, format: .liveMirror(sizeGB: 1))
        var d = JobDraftState(editing: base, libraries: [papers], targets: [], now: start)
        let b = VolumeIdentity(uuid: "DRIVE-B", name: "T7", relativePath: "Backups")
        let paired = d.pair("t7", with: b)
        #expect(paired)
        #expect(d.makeJob(now: start).targets[0].otherVolumes == [b])
        #expect(base.targets[0].otherVolumes == nil)                         // nothing saved yet
        let saved = JobEdit.merge(draft: d.makeJob(now: start), base: base, stored: base)
        #expect(saved?.targets[0].otherVolumes == [b])
        d.unpair("t7", uuid: "DRIVE-B")
        #expect(d.makeJob(now: start).targets[0].otherVolumes == nil)
        var share = Target.networkShare(id: "nas", name: "NAS", dir: URL(fileURLWithPath: "/Volumes/nas"),
                                        mount: NetworkMountSpec(url: URL(string: "smb://nas/x")!, mountpoint: "/Volumes/nas"))
        share.volume = VolumeIdentity(uuid: "smb://nas/x", name: "x", relativePath: "", isShare: true)
        var e = draft([share])
        let sharePaired = e.pair("nas", with: b)
        #expect(!sharePaired)
    }

    @Test func takingTurnsMakesOnePlaceAndLeavingItUndoesIt() {
        let a = Target.externalDrive(id: "a", name: "A", dir: URL(fileURLWithPath: "/Volumes/A/B"))
        let b = Target.externalDrive(id: "b", name: "B", dir: URL(fileURLWithPath: "/Volumes/B/B"))
        let c = Target.localVolume(id: "c", name: "C", dir: URL(fileURLWithPath: "/Volumes/C/B"))
        var d = draft([a, b, c])
        d.takeTurns("b", with: "a", now: start)
        var j = d.makeJob(now: start)
        #expect(j.places.map { $0.map(\.id) } == [["a", "b"], ["c"]])
        #expect(j.targets.first { $0.id == "b" }?.rotation?.addedAt == start)
        #expect(d.takesTurns("a").map(\.id) == ["b"])
        d.takeTurns("c", with: "b", now: start.addingTimeInterval(day))
        j = d.makeJob(now: start)
        #expect(j.places.map { $0.map(\.id) } == [["a", "b", "c"]])
        d.stopTakingTurns("a")
        d.stopTakingTurns("b")                                              // leaves one: no rotation
        j = d.makeJob(now: start)
        #expect(j.targets.allSatisfy { $0.rotation == nil })
    }

    @Test func aRotationWithOneChosenDriveIsSavedAsNone() {
        let a = Target.externalDrive(id: "a", name: "A", dir: URL(fileURLWithPath: "/Volumes/A/B"))
        let b = Target.externalDrive(id: "b", name: "B", dir: URL(fileURLWithPath: "/Volumes/B/B"))
        var d = draft([a, b])
        d.takeTurns("b", with: "a", now: start)
        d.toggleTarget("b")                                                 // unticked
        #expect(d.makeJob(now: start).targets.map { $0.rotation } == [nil])
    }

    @Test func theMainDestinationIsTheOneMovedFirst() {
        let a = Target.localVolume(id: "a", name: "A", dir: URL(fileURLWithPath: "/Volumes/A/B"))
        let b = Target.localVolume(id: "b", name: "B", dir: URL(fileURLWithPath: "/Volumes/B/B"))
        var d = draft([a, b])
        d.makeMain("b")
        #expect(d.makeJob(now: start).targets.map(\.id) == ["b", "a"])
        #expect(d.primaryTarget?.id == "b")
    }
}
