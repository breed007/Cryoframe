//
//  DriveRenameTests.swift
//  CryoframeKitTests
//
//  Rename this drive (see DriveRename), on disk images this test makes and ejects:
//  the drive is renamed by its UUID and found again by it under the new name, the
//  job's folder on it is untouched, and the job is changed once, to two drives
//  taking turns. Anything in use, a bad or taken name, or a rename that can't be
//  confirmed leaves the drive and the job as they were.
//

import Testing
import Foundation
@testable import CryoframeKit

private let hdiutil = "/usr/bin/hdiutil"
private let start = Date(timeIntervalSince1970: 1_790_000_000)

private func scratch(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-drivename-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return TempTracker.track(d) }
    defer { free(real) }
    return TempTracker.track(URL(fileURLWithPath: String(cString: real), isDirectory: true))
}

/// A drive: a disk image of `fs` named `name`, attached where macOS mounts it (under
/// /Volumes, as a real drive), holding a job's 1.5 folder with one version.
private struct TestDrive {
    let image: URL
    let uuid: String
    var mount: URL

    static func make(_ fs: String, name: String, in base: URL) throws -> TestDrive {
        let image = base.appendingPathComponent("\(fs.filter(\.isLetter)).dmg")
        let made = try ProcessCommandRunner().run(hdiutil, ["create", "-quiet", "-size", "40m", "-fs", fs, "-volname", name,
                                                            "-layout", "GPTSPUD", image.path])
        try #require(made.ok, "\(made.stderr)")
        let attached = try DiskImageGate.serialized { try ProcessCommandRunner().runRetryingBusy(hdiutil, ["attach", "-nobrowse", image.path]) }
        try #require(attached.ok, "\(attached.stderr)")
        let mountPath = try #require(attached.stdout.split(separator: "\n").compactMap { line -> String? in
            guard let r = line.range(of: "/Volumes/") else { return nil }
            return String(line[r.lowerBound...]).trimmingCharacters(in: .whitespaces)
        }.last)
        let mount = URL(fileURLWithPath: mountPath, isDirectory: true)
        let uuid = try #require((try? mount.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString)
        let v = mount.appendingPathComponent("Backups/Papers/2026-09-01-020000")
        try FileManager.default.createDirectory(at: v, withIntermediateDirectories: true)
        try Data("zip".utf8).write(to: v.appendingPathComponent("Papers.zip"))
        return TestDrive(image: image, uuid: uuid, mount: mount)
    }

    func eject() {
        let current = DriveRename.drive(uuid)?.mountPoint ?? mount
        _ = try? ProcessCommandRunner().run(hdiutil, ["detach", current.path, "-force"])
    }
}

/// a runner that does what the real one does, and on `diskutil rename` whatever else
/// the test asks
private struct Meddling: CommandRunner {
    var onRename: @Sendable () -> Void = {}
    var failRename = false
    func run(_ launchPath: String, _ args: [String], stdin: Data?) throws -> CommandResult {
        if launchPath.hasSuffix("diskutil"), args.first == "rename" {
            if failRename { return CommandResult(status: 1, stdout: "", stderr: "Couldn't rename (simulated)") }
            let r = try ProcessCommandRunner().run(launchPath, args, stdin: stdin)
            onRename()
            return r
        }
        return try ProcessCommandRunner().run(launchPath, args, stdin: stdin)
    }
}

private func setup(_ drive: TestDrive, name: String, base: URL) -> (store: JobStore, job: BackupJob) {
    var t = Target.externalDrive(id: "/Volumes/\(name)/Backups", name: "Backups on \(name)",
                                 dir: URL(fileURLWithPath: "/Volumes/\(name)/Backups"))
    t.volume = VolumeIdentity(uuid: "DRIVE-A-\(name)", name: name, relativePath: "Backups", learnedAt: start)
    t.otherVolumes = [VolumeIdentity(uuid: drive.uuid, name: name, relativePath: "Backups", learnedAt: start)]
    let job = BackupJob(id: "job-\(name)", name: "Papers",
                        libraries: [.genericFolder(id: "papers", displayName: "Papers", path: .absolute("/Users/me/Papers"))],
                        target: t, format: .liveMirror(sizeGB: 1), frequency: .manual, createdAt: start)
    let store = JobStore(url: base.appendingPathComponent("jobs.json"))
    store.upsert(job)
    return (store, job)
}

private func unique() -> String { "CF" + UUID().uuidString.filter(\.isHexDigit).prefix(4) }

@Suite(.serialized) struct DriveRenameTests {
    @Test(arguments: ["APFS", "HFS+", "ExFAT", "MS-DOS FAT32"])
    func aDriveIsRenamedByItsUUIDAndTheJobTakesTurnsBetweenBoth(fs: String) throws {
        let base = scratch("ok")
        let name = unique()
        let drive = try TestDrive.make(fs, name: name, in: base)
        defer { drive.eject() }
        let (store, job) = setup(drive, name: name, base: base)
        let before = DriveRename.fingerprint(drive.mount.appendingPathComponent("Backups"))
        let now = start.addingTimeInterval(86_400)
        let newName = DriveRename.suggestedName(for: name, taken: [])
        let pending = PendingTransferStore(url: base.appendingPathComponent("pending.json"))
        let out = try DriveRename.rename(drive.uuid, to: newName, targetID: job.targets[0].id, jobID: job.id, store: store,
                                         locks: RunLocks(directory: base.appendingPathComponent("locks")), pending: pending,
                                         isOpen: { _ in false }, now: now)
        // the same drive, found by its UUID under its new name, nothing in it moved
        let after = try #require(DriveRename.drive(drive.uuid))
        #expect(after.name == newName)
        #expect(after.mountPoint.path != drive.mount.path)
        #expect(DriveRename.fingerprint(after.mountPoint.appendingPathComponent("Backups")) == before)
        // the job, once: the destination keeps its own drive; a new one on this drive takes turns with it
        let saved = try #require(store.load().jobs.first)
        #expect(saved == out.job)
        #expect(saved.targets.count == 2)
        #expect(saved.targets[0].volume?.uuid == "DRIVE-A-\(name)")
        #expect(saved.targets[0].otherVolumes == nil)
        #expect(saved.targets[1].volume?.uuid == drive.uuid && saved.targets[1].volume?.name == newName)
        #expect(saved.targets[1].destinationDir.path == after.mountPoint.appendingPathComponent("Backups").path)
        #expect(saved.targets[0].rotation?.group != nil && saved.targets[0].rotation?.group == saved.targets[1].rotation?.group)
        #expect(saved.targets[1].rotation?.addedAt == now)
        #expect(saved.places.count == 1)
        #expect(DestinationResolver().locate(saved.targets[1]).url?.path == saved.targets[1].destinationDir.path)
    }

    @Test func aRenameThatCantBeConfirmedIsUndoneAndTheJobIsLeftAlone() throws {
        let base = scratch("undo")
        let name = unique()
        let drive = try TestDrive.make("APFS", name: name, in: base)
        defer { drive.eject() }
        let (store, _) = setup(drive, name: name, base: base)
        let jobs = try Data(contentsOf: base.appendingPathComponent("jobs.json"))
        let uuid = drive.uuid
        // something writes into the folder while it's renamed
        let meddle = Meddling(onRename: {
            if let m = DriveRename.drive(uuid)?.mountPoint {
                try? Data("x".utf8).write(to: m.appendingPathComponent("Backups/Papers/new.txt"))
            }
        })
        #expect(throws: DriveRename.Refusal.self) {
            try DriveRename.rename(uuid, to: name + " B", targetID: "/Volumes/\(name)/Backups", jobID: "job-\(name)", store: store,
                                   locks: RunLocks(directory: base.appendingPathComponent("locks")),
                                   pending: PendingTransferStore(url: base.appendingPathComponent("p.json")),
                                   runner: meddle, isOpen: { _ in false })
        }
        #expect(DriveRename.drive(uuid)?.name == name)                           // put back
        #expect(try Data(contentsOf: base.appendingPathComponent("jobs.json")) == jobs)
    }

    @Test func aRenameDiskutilRefusesChangesNothing() throws {
        let base = scratch("fail")
        let name = unique()
        let drive = try TestDrive.make("APFS", name: name, in: base)
        defer { drive.eject() }
        let (store, _) = setup(drive, name: name, base: base)
        let jobs = try Data(contentsOf: base.appendingPathComponent("jobs.json"))
        do {
            _ = try DriveRename.rename(drive.uuid, to: name + " B", targetID: "/Volumes/\(name)/Backups", jobID: "job-\(name)",
                                       store: store, locks: RunLocks(directory: base.appendingPathComponent("locks")),
                                       pending: PendingTransferStore(url: base.appendingPathComponent("p.json")),
                                       runner: Meddling(failRename: true), isOpen: { _ in false })
            Issue.record("renamed")
        } catch DriveRename.Refusal.failed(let why) {
            #expect(why.contains("simulated"))
        }
        #expect(DriveRename.drive(drive.uuid)?.name == name)
        #expect(try Data(contentsOf: base.appendingPathComponent("jobs.json")) == jobs)
    }

    @Test func nothingIsRenamedWhileAnyJobOnTheDriveIsInUse() throws {
        let base = scratch("busy")
        let name = unique()
        let drive = try TestDrive.make("APFS", name: name, in: base)
        defer { drive.eject() }
        let (store, job) = setup(drive, name: name, base: base)
        let locks = RunLocks(directory: base.appendingPathComponent("locks"))
        let pending = PendingTransferStore(url: base.appendingPathComponent("p.json"))
        func attempt(queued: Bool = false) throws {
            _ = try DriveRename.rename(drive.uuid, to: name + " B", targetID: job.targets[0].id, jobID: job.id, store: store,
                                       locks: locks, pending: pending, isQueued: { _ in queued }, isOpen: { _ in false })
        }
        let lease = try locks.acquire(jobID: job.id, trigger: .resume)
        #expect(throws: DriveRename.Refusal.self) { try attempt() }
        lease.release()
        #expect(throws: DriveRename.Refusal.self) { try attempt(queued: true) }
        pending.save(PendingTransfer(jobID: "\(job.id):t:papers", sourceFile: "/s", baseName: "b", totalBytes: 1, chunkSize: 1,
                                     targetDir: "/Volumes/elsewhere", format: .sealedZip, volumeUUID: drive.uuid))
        do { try attempt(); Issue.record("renamed with a transfer to finish on it") }
        catch DriveRename.Refusal.transferPending { }
        pending.remove(jobID: "\(job.id):t:papers")
        do {
            _ = try DriveRename.rename(drive.uuid, to: name + " B", targetID: job.targets[0].id, jobID: job.id, store: store,
                                       locks: locks, pending: pending, isOpen: { _ in true })
            Issue.record("renamed with an image on it attached")
        } catch DriveRename.Refusal.imageAttached { }
        #expect(DriveRename.drive(drive.uuid)?.name == name)
        #expect(!locks.isBusy(job.id))                                           // every lock given back
    }

    // Its own name again: the new destination would have the same folder, and so
    // the same id, as the job's own, and replaced it.
    @Test func aDriveIsNotRenamedToTheNameItHas() throws {
        let base = scratch("same")
        let name = unique()
        let drive = try TestDrive.make("APFS", name: name, in: base)
        defer { drive.eject() }
        let store = JobStore(url: base.appendingPathComponent("jobs.json"))
        var t = Target.externalDrive(id: drive.mount.appendingPathComponent("Backups").path, name: "Backups on \(name)",
                                     dir: drive.mount.appendingPathComponent("Backups"))
        t.volume = VolumeIdentity(uuid: "DRIVE-A", name: "Old A", relativePath: "Backups", learnedAt: start)
        t.otherVolumes = [VolumeIdentity(uuid: drive.uuid, name: name, relativePath: "Backups")]
        let job = BackupJob(id: "job-same", name: "Papers",
                            libraries: [.genericFolder(id: "papers", displayName: "Papers", path: .absolute("/Users/me/Papers"))],
                            target: t, format: .liveMirror(sizeGB: 1), frequency: .manual, createdAt: start)
        store.upsert(job)
        do {
            _ = try DriveRename.rename(drive.uuid, to: name, targetID: t.id, jobID: job.id, store: store,
                                       locks: RunLocks(directory: base.appendingPathComponent("locks")),
                                       pending: PendingTransferStore(url: base.appendingPathComponent("p.json")), isOpen: { _ in false })
            Issue.record("renamed to its own name")
        } catch DriveRename.Refusal.invalidName { }
        #expect(store.load().jobs.first?.targets.map(\.id) == [t.id])
        #expect(store.load().jobs.first?.targets.first?.volume?.uuid == "DRIVE-A")
    }

    // MARK: without a drive

    private func drive(_ fs: String = "apfs", onBoard: Bool = false, writable: Bool = true) -> DriveRename.Drive {
        DriveRename.Drive(uuid: "U", name: "T7", mountPoint: URL(fileURLWithPath: "/Volumes/T7"), fileSystem: fs,
                          isInternal: onBoard, isWritable: writable)
    }

    private func check(_ d: DriveRename.Drive, _ name: String, jobs: [BackupJob] = [], mounted: [String] = [],
                       tm: String = "No destinations configured.") throws {
        let runner = ScriptedCommandRunner { launch, _ in
            launch.hasSuffix("tmutil") ? CommandResult(status: tm.hasPrefix("No") ? 1 : 0, stdout: tm, stderr: "")
                : CommandResult(status: 0, stdout: "<plist version=\"1.0\"><dict/></plist>", stderr: "")
        }
        try DriveRename.check(d, to: name, jobs: jobs, locks: RunLocks(directory: scratch("l")), pending: [],
                              volumes: FixedVolumeTable(mounted.map { MountedVolume(mountPoint: URL(fileURLWithPath: "/Volumes/\($0)"), uuid: $0, name: $0) }),
                              runner: runner, isOpen: { _ in false })
    }

    @Test func refusals() throws {
        #expect(throws: DriveRename.Refusal.notExternal("T7")) { try check(drive(onBoard: true), "T7 B") }
        #expect(throws: DriveRename.Refusal.readOnly("T7")) { try check(drive(writable: false), "T7 B") }
        #expect(throws: DriveRename.Refusal.nameTaken("Work")) { try check(drive(), "Work", mounted: ["Work"]) }
        var known = BackupJob(name: "J", libraries: [], target: .localVolume(id: "x", name: "x", dir: URL(fileURLWithPath: "/Volumes/Old/x")),
                              format: .sealedZip, frequency: .manual, createdAt: start)
        known.targets[0].volume = VolumeIdentity(uuid: "OTHER", name: "Old", relativePath: "x")
        #expect(throws: DriveRename.Refusal.nameTaken("old")) { try check(drive(), "old", jobs: [known]) }
        let tm = "====\nName          : T7\nKind          : Local\nMount Point   : /Volumes/T7\nID            : 1\n"
        #expect(throws: DriveRename.Refusal.timeMachine("T7")) { try check(drive(), "T7 B", tm: tm) }
        try check(drive(), "T7 B")
    }

    @Test func namesEachFormatTakes() {
        #expect(DriveRename.nameProblem("ABCDEFGHIJK", fileSystem: "exfat") == nil)
        #expect(DriveRename.nameProblem("ABCDEFGHIJKL", fileSystem: "exfat") != nil)          // measured: refused
        #expect(DriveRename.nameProblem("T7 B", fileSystem: "msdos") == nil)
        #expect(DriveRename.nameProblem("Tè", fileSystem: "msdos") != nil)
        #expect(DriveRename.nameProblem("Photos: old", fileSystem: "apfs") != nil)
        #expect(DriveRename.nameProblem(".hidden", fileSystem: "apfs") != nil)
        #expect(DriveRename.nameProblem(" T7", fileSystem: "apfs") != nil)
        #expect(DriveRename.nameProblem("", fileSystem: "apfs") != nil)
        #expect(DriveRename.nameProblem("Fotos del año", fileSystem: "apfs") == nil)
        #expect(DriveRename.suggestedName(for: "T7", taken: ["T7 B"]) == "T7 C")
    }
}
