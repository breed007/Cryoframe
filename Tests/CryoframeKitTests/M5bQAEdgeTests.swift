//
//  M5bQAEdgeTests.swift
//  CryoframeKitTests
//
//  Independent QA of 1.6 M5b: Rename this drive, the editor's vocabulary, and an
//  interrupted upload's parts. Each test states what should hold; where the build
//  doesn't, the test fails until it does.
//

import Testing
import Foundation
@testable import CryoframeKit

private let hdiutil = "/usr/bin/hdiutil"
private let start = Date(timeIntervalSince1970: 1_790_000_000)

private func scratch(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-m5bqa-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return TempTracker.track(d) }
    defer { free(real) }
    return TempTracker.track(URL(fileURLWithPath: String(cString: real), isDirectory: true))
}

private func unique() -> String { "CQ" + UUID().uuidString.filter(\.isHexDigit).prefix(4) }

/// a drive: an APFS disk image named `name`, attached under /Volumes like a real drive
private struct QADrive {
    let uuid: String
    let mount: URL

    static func make(name: String, in base: URL) throws -> QADrive {
        let image = base.appendingPathComponent("drive.dmg")
        let made = try ProcessCommandRunner().run(hdiutil, ["create", "-quiet", "-size", "40m", "-fs", "APFS", "-volname", name,
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
        return QADrive(uuid: uuid, mount: mount)
    }

    func eject() {
        let current = DriveRename.drive(uuid)?.mountPoint ?? mount
        _ = try? ProcessCommandRunner().run(hdiutil, ["detach", current.path, "-force"])
    }
}

/// a job whose destination is on drive A (not connected), at /Volumes/<name>/Backups:
/// the drive connected there now is "a different drive of its name"
private func jobOnDriveA(_ name: String, base: URL) -> (JobStore, BackupJob) {
    var t = Target.externalDrive(id: "/Volumes/\(name)/Backups", name: "Backups on \(name)",
                                 dir: URL(fileURLWithPath: "/Volumes/\(name)/Backups"))
    t.volume = VolumeIdentity(uuid: "DRIVE-A-\(name)", name: name, relativePath: "Backups", learnedAt: start)
    let job = BackupJob(id: "job-\(name)", name: "Papers",
                        libraries: [.genericFolder(id: "papers", displayName: "Papers", path: .absolute("/Users/me/Papers"))],
                        target: t, format: .sealedZip, frequency: .manual, retention: .keepLast(2), createdAt: start)
    let store = JobStore(url: base.appendingPathComponent("jobs.json"))
    store.upsert(job)
    return (store, job)
}

private struct FailingHdiutil: CommandRunner {
    func run(_ launchPath: String, _ args: [String], stdin: Data?) throws -> CommandResult {
        CommandResult(status: 1, stdout: "", stderr: "hdiutil: info failed - Resource temporarily unavailable")
    }
}

@Suite(.serialized) struct M5bQAEdgeTests {

    // The design: a drive holding another job's backups "isn't offered at all: it is
    // some other drive, however it's named" (DrivePairing). The row menu offers Rename
    // this drive for any `.otherDrive` destination without asking DrivePairing, and
    // DriveRename doesn't look at identity files: someone else's "T7" (another Mac's,
    // a deleted job's) is renamed and made this job's rotation drive.
    @Test func aDriveHoldingAnotherJobsBackupsIsNotRenamedIntoThisJob() throws {
        let base = scratch("foreign")
        let name = unique()
        let drive = try QADrive.make(name: name, in: base)
        defer { drive.eject() }
        let theirs = drive.mount.appendingPathComponent("Backups/Mail")
        try FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)
        try LibraryIdentity(jobID: "someone-else", libraryID: "mail", name: "Mail", jobName: "Old Mac").write(in: theirs)
        let (store, job) = jobOnDriveA(name, base: base)
        let before = try Data(contentsOf: base.appendingPathComponent("jobs.json"))

        var renamed = false
        do {
            _ = try DriveRename.rename(drive.uuid, to: name + " B", targetID: job.targets[0].id, jobID: job.id, store: store,
                                       locks: RunLocks(directory: base.appendingPathComponent("locks")),
                                       pending: PendingTransferStore(url: base.appendingPathComponent("p.json")),
                                       isOpen: { _ in false })
            renamed = true
        } catch {}
        #expect(!renamed, "another job's drive was renamed and made this job's")
        #expect(DriveRename.drive(drive.uuid)?.name == name)
        #expect(try Data(contentsOf: base.appendingPathComponent("jobs.json")) == before)
    }

    // The existing refusal test injects isOpen. With the real check: a disk image
    // stored on the drive and attached (a Restore browsing a version, say) stops it.
    @Test func aDiskImageOnTheDriveReallyAttachedStopsTheRename() throws {
        let base = scratch("attached")
        let name = unique()
        let drive = try QADrive.make(name: name, in: base)
        defer { drive.eject() }
        let inner = drive.mount.appendingPathComponent("Backups/Papers/2026-09-01-020000/Papers.dmg")
        try FileManager.default.createDirectory(at: inner.deletingLastPathComponent(), withIntermediateDirectories: true)
        let made = try ProcessCommandRunner().run(hdiutil, ["create", "-quiet", "-size", "2m", "-fs", "HFS+", "-volname", "In", inner.path])
        try #require(made.ok, "\(made.stderr)")
        let att = try DiskImageGate.serialized {
            try ProcessCommandRunner().runRetryingBusy(hdiutil, ["attach", "-nobrowse", "-nomount", "-readonly", inner.path])
        }
        try #require(att.ok, "\(att.stderr)")
        let dev = try #require(att.stdout.split(separator: "\n").first.map { String($0.split(separator: "\t").first ?? "").trimmingCharacters(in: .whitespaces) })
        defer { _ = try? ProcessCommandRunner().run(hdiutil, ["detach", dev, "-force"]) }
        let (store, job) = jobOnDriveA(name, base: base)

        do {
            _ = try DriveRename.rename(drive.uuid, to: name + " B", targetID: job.targets[0].id, jobID: job.id, store: store,
                                       locks: RunLocks(directory: base.appendingPathComponent("locks")),
                                       pending: PendingTransferStore(url: base.appendingPathComponent("p.json")))
            Issue.record("renamed with an image on it attached")
        } catch DriveRename.Refusal.imageAttached {
        } catch {
            Issue.record("refused, but not for the image: \(error)")
        }
        #expect(DriveRename.drive(drive.uuid)?.name == name)
    }

    // DriveRename refuses whatever it can't tell (a lock it can't read, whether it's a
    // Time Machine drive). Whether an image is attached is the exception: when hdiutil
    // can't be asked, anyImageAttached says "none" (attachedImages `?? []`), and the
    // drive is renamed from under the image. attachedImagesIfKnown already exists.
    @Test func anImageListThatCantBeReadIsNotTakenAsNoneAttached() throws {
        let dir = scratch("unknown")
        #expect(LibraryFolders.anyImageAttached(under: dir, runner: FailingHdiutil()) == true,
                "hdiutil info failed and the folder was treated as having nothing attached")
    }

    // The editor's words: no "target". A new job with nothing chosen yet (the state
    // the editor opens in when no destination is remembered) prompts its name as
    // "Libraries → Target" (JobDraftState.defaultName), shown as the Name field's
    // prompt. The vocabulary test only reads literals with a space or passed to Text/Button.
    @Test func aNewJobsNamePromptSpeaksTheEditorsVocabulary() {
        let draft = JobDraftState(libraries: [], targets: [], now: start)
        let words = draft.defaultName.lowercased().split { !$0.isLetter }.map(String.init)
        let banned = ["target", "volume", "primary", "sealed", "mirror", "held", "archive", "resumable", "snapshot"]
        #expect(!words.contains { banned.contains($0) }, "the Name prompt reads “\(draft.defaultName)”")
    }

    // An interrupted upload resumed into a folder whose earlier parts are gone (swept,
    // or the folder remade) ships the remaining parts and writes the manifest over
    // parts that aren't there: a version that says it is complete and can't restore,
    // which retention then counts as a version.
    @Test func aResumeWhoseEarlierPartsAreGoneIsNotMarkedComplete() throws {
        let base = scratch("parts")
        let src = base.appendingPathComponent("scratch/Lib.zip")
        try FileManager.default.createDirectory(at: src.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 200).write(to: src)
        let dest = base.appendingPathComponent("Backups/Lib/2026-09-29-020000")
        let part0 = ChunkedShipper.partName("Lib.zip", 0)
        let p = PendingTransfer(jobID: "job:d:lib", sourceFile: src.path, baseName: "Lib.zip", totalBytes: 200, chunkSize: 100,
                                targetDir: dest.path, format: .sealedZip,
                                completed: [ArtifactDigest(name: part0, size: 100, sha256: "")])
        // part 0 was shipped by an earlier pass, then its folder was swept
        var wroteManifest = false
        do {
            let m = try ChunkedShipper().ship(p, persist: { _ in })
            wroteManifest = true
            for a in m.artifacts {
                #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent(a.name).path),
                        "the manifest lists \(a.name), which isn't there")
            }
        } catch {}
        if !wroteManifest {
            #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent(ArchiveManifest.sidecarName).path))
        }
    }
}

extension M5bQAEdgeTests {
    // afeed0a keeps an interrupted upload's folder by comparing the record's absolute
    // targetDir with the folder. The record keeps the path the drive had when the
    // upload began; a drive renamed in Finder, a share remounted as "Backups-1", or
    // "T7 1" while its twin is connected is found by the run somewhere else, and the
    // parts are swept as a failed run's leftover.
    @Test func anInterruptedUploadOnADriveNowMountedElsewhereIsNotSwept() async throws {
        let base = scratch("remount")
        let (mnt, _) = try qaSourceVolume(in: base)
        defer { MountPoint.detach(mnt, runner: ProcessCommandRunner()) }
        let dest = base.appendingPathComponent("Backups")          // where the drive is now
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let papers = ContentType.genericFolder(id: "papers", displayName: "Papers", path: .absolute(mnt.appendingPathComponent("Papers").path))
        let gone = ContentType.genericFolder(id: "notes", displayName: "Notes", path: .absolute(mnt.appendingPathComponent("Notes").path))
        let job = BackupJob(name: "Papers", libraries: [papers, gone], target: .localVolume(id: "d", name: "Backups", dir: dest),
                            format: .sealedZip, frequency: .manual, retention: .keepLast(3), createdAt: start)
        let folder = try LibraryFolders.prepare(job: job, library: gone, in: dest, jobs: [job], isOpen: { _ in false }).folder
        let partial = folder.appendingPathComponent("2026-09-29-020000")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data(repeating: 9, count: 64).write(to: partial.appendingPathComponent("Notes.zip.part.000"))
        let staged = base.appendingPathComponent("scratch/\(job.id)/build/notes/Notes.zip")
        try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 9, count: 128).write(to: staged)
        // recorded when the drive was mounted under its old name
        let oldPath = "/Volumes/cf-m5bqa-old-\(UUID().uuidString.prefix(6))/Backups/\(folder.lastPathComponent)/2026-09-29-020000"
        let store = PendingTransferStore(url: base.appendingPathComponent("pending.json"))
        store.save(PendingTransfer(jobID: "\(job.id):d:notes", sourceFile: staged.path, baseName: "Notes.zip", totalBytes: 128,
                                   chunkSize: 64, targetDir: oldPath, format: .sealedZip,
                                   completed: [ArtifactDigest(name: "Notes.zip.part.000", size: 64, sha256: "")]))

        let exec = JobExecutor(helper: FakePrivilegedHelper(), detector: FakeProcessDetector(),
                               scratchBase: base.appendingPathComponent("scratch"), pendingStore: store,
                               volumes: FixedVolumeTable([]))
        let outcome = try await exec.run(job, ownerUID: getuid(), now: start)
        guard case .finished = outcome else { Issue.record("\(outcome)"); return }
        #expect(FileManager.default.fileExists(atPath: partial.appendingPathComponent("Notes.zip.part.000").path),
                "the interrupted upload's parts were swept")
    }
}

/// a small HFS+ volume at `<base>/vol` holding "Papers" (read live: no snapshot)
private func qaSourceVolume(in base: URL) throws -> (mnt: URL, papers: URL) {
    let mnt = base.appendingPathComponent("vol")
    try FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)
    let dmg = base.appendingPathComponent("src.dmg")
    let made = try ProcessCommandRunner().run(hdiutil, ["create", "-size", "20m", "-fs", "HFS+", "-volname", "Src", dmg.path])
    try #require(made.ok, "\(made.stderr)")
    let attached = try DiskImageGate.serialized {
        try ProcessCommandRunner().runRetryingBusy(hdiutil, ["attach", dmg.path, "-mountpoint", mnt.path, "-nobrowse", "-owners", "on"])
    }
    try #require(attached.ok && MountPoint.isMounted(mnt), "\(attached.stderr)")
    let papers = mnt.appendingPathComponent("Papers")
    try FileManager.default.createDirectory(at: papers, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 4096).write(to: papers.appendingPathComponent("a.bin"))
    return (mnt, papers)
}
