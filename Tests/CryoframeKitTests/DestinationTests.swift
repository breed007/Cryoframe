//
//  DestinationTests.swift
//  CryoframeKitTests
//
//  Destinations and sources as places: found by their volume's UUID (a renamed or
//  remounted drive is still itself, another drive of the same name isn't), their
//  kind and friendly name worked out from the volume, and the rules a folder has to
//  pass to become one.
//

import Testing
import Foundation
@testable import CryoframeKit

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-dest-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

private func vol(_ mount: String, _ uuid: String?, _ name: String, onMac: Bool = false, local: Bool = true,
                 root: Bool = false, remount: String? = nil) -> MountedVolume {
    MountedVolume(mountPoint: URL(fileURLWithPath: mount, isDirectory: true), uuid: uuid, name: name, isLocal: local,
                  isInternal: onMac, isRemovable: !onMac, isEjectable: !onMac, isRoot: root,
                  remountURL: remount.flatMap(URL.init(string:)))
}

private let boot = vol("/System/Volumes/Data", "DATA-UUID", "Macintosh HD", onMac: true, root: true)

@Suite struct DestinationTests {

    // MARK: finding a destination again

    @Test func aRenamedDriveIsFoundByItsUUID() {
        let resolver = DestinationResolver(volumes: FixedVolumeTable([boot, vol("/Volumes/T7 Backup", "T7-UUID", "T7 Backup")]))
        var t = Target.externalDrive(id: "t7", name: "Backups on T7", dir: URL(fileURLWithPath: "/Volumes/T7/Backups"))
        t.volume = VolumeIdentity(uuid: "T7-UUID", name: "T7", relativePath: "Backups")
        #expect(resolver.locate(t) == .present(URL(fileURLWithPath: "/Volumes/T7 Backup/Backups", isDirectory: true)))
        let job = BackupJob(name: "J", libraries: [.photos], target: t, format: .sealedZip, frequency: .manual, createdAt: Date())
        #expect(resolver.resolve(job).job.target.destinationDir.path == "/Volumes/T7 Backup/Backups")
    }

    // Plugged in second, a drive mounts as "T7 1"; the other "T7" isn't this one.
    @Test func anotherDriveWithTheSameNameIsNotTheDestination() {
        var t = Target.externalDrive(id: "t7", name: "Backups on T7", dir: URL(fileURLWithPath: "/Volumes/T7/Backups"))
        t.volume = VolumeIdentity(uuid: "T7-UUID", name: "T7", relativePath: "Backups")
        let other = DestinationResolver(volumes: FixedVolumeTable([boot, vol("/Volumes/T7", "OTHER-UUID", "T7")]))
        guard case .otherDrive(let why) = other.locate(t) else { Issue.record("\(other.locate(t))"); return }
        #expect(why.contains("different drive named “T7”"))
        let both = DestinationResolver(volumes: FixedVolumeTable([boot, vol("/Volumes/T7", "OTHER-UUID", "T7"),
                                                                 vol("/Volumes/T7 1", "T7-UUID", "T7")]))
        #expect(both.locate(t).url?.path == "/Volumes/T7 1/Backups")
        let none = DestinationResolver(volumes: FixedVolumeTable([boot]))
        #expect(none.locate(t) == .away("T7 isn't connected"))
    }

    @Test func aShareIsFoundByItsAddress() {
        var t = Target.networkShare(id: "n", name: "Backups on nas", dir: URL(fileURLWithPath: "/Volumes/Backups/Mac"),
                                    mount: NetworkMountSpec(url: URL(string: "smb://nas.local/Backups")!, mountpoint: "/Volumes/Backups"))
        t.volume = VolumeIdentity(uuid: "smb://nas.local/backups", name: "Backups", relativePath: "Mac", isShare: true)
        let r = DestinationResolver(volumes: FixedVolumeTable([boot, vol("/Volumes/Backups-1", nil, "Backups", local: false,
                                                                        remount: "smb://jane@NAS.local/Backups")]))
        #expect(r.locate(t).url?.path == "/Volumes/Backups-1/Mac")
    }

    // A destination set up before 1.6 has no volume recorded: found by its path, as before.
    @Test func aDestinationWithoutAVolumeIsFoundByItsPath() {
        let dir = folder("legacy"); defer { try? FileManager.default.removeItem(at: dir) }
        let r = DestinationResolver(volumes: FixedVolumeTable([boot]))
        #expect(r.locate(.localVolume(id: "l", name: "L", dir: dir)) == .present(dir))
        #expect(r.locate(.localVolume(id: "l", name: "Gone", dir: URL(fileURLWithPath: "/Volumes/Nope/At/All"))) == .away("Gone isn't connected"))
    }

    // MARK: kind and name, from the volume

    @Test func theKindAndNameComeFromTheVolume() {
        let home = "/Users/jdoe"
        let table = FixedVolumeTable([boot, vol("/Volumes/T7 Backup", "T7", "T7 Backup"),
                                      vol("/Volumes/Share", nil, "Share", local: false, remount: "smb://nas.local/Share")])
        let r = DestinationResolver(volumes: table)
        #expect(r.kind(of: URL(fileURLWithPath: "/Volumes/T7 Backup/Backups"), home: home) == .externalDrive)
        #expect(r.friendlyName(for: URL(fileURLWithPath: "/Volumes/T7 Backup/Backups"), home: home) == "Backups on T7 Backup")
        #expect(r.friendlyName(for: URL(fileURLWithPath: "/Volumes/T7 Backup"), home: home) == "T7 Backup")
        #expect(r.kind(of: URL(fileURLWithPath: "/System/Volumes/Data/Users/jdoe/Backups"), home: home) == .internalDisk)
        #expect(r.friendlyName(for: URL(fileURLWithPath: "/System/Volumes/Data/Users/jdoe/Backups"), home: home) == "Backups on this Mac")
        #expect(r.kind(of: URL(fileURLWithPath: "/Volumes/Share/Mac"), home: home) == .network)
        #expect(r.friendlyName(for: URL(fileURLWithPath: "/Volumes/Share/Mac"), home: home) == "Mac on Share (nas.local)")
        let icloud = URL(fileURLWithPath: home + "/Library/Mobile Documents/com~apple~CloudDocs/Backups")
        #expect(r.kind(of: icloud, home: home) == .cloud)
        // the kind isn't asked for: a destination made from the folder has it, and its volume
        let t = r.target(for: URL(fileURLWithPath: "/Volumes/T7 Backup/Backups"), home: home)
        #expect(t.constraints.resumableTransfer && t.displayName == "Backups on T7 Backup")
        #expect(t.volume == VolumeIdentity(uuid: "T7", name: "T7 Backup", relativePath: "Backups"))
    }

    // A real volume: an APFS disk image attached like a drive. Its UUID is what the
    // destination records; detached and attached again elsewhere, and renamed, it is
    // found at its new place.
    @Test func aRealVolumeIsFoundAgainAfterItMovesAndIsRenamed() throws {
        let base = folder("real"); defer { try? FileManager.default.removeItem(at: base) }
        let image = base.appendingPathComponent("drive.dmg")
        let made = try ProcessCommandRunner().run("/usr/bin/hdiutil", ["create", "-size", "20m", "-fs", "APFS", "-volname", "CF T7", image.path])
        try #require(made.ok, "\(made.stderr)")
        func attach(_ at: URL) throws {
            try FileManager.default.createDirectory(at: at, withIntermediateDirectories: true)
            let r = try DiskImageGate.serialized {
                try ProcessCommandRunner().runRetryingBusy("/usr/bin/hdiutil", ["attach", image.path, "-mountpoint", at.path, "-nobrowse"])
            }
            try #require(r.ok && MountPoint.isMounted(at), "\(r.stderr)")
        }
        let first = base.appendingPathComponent("m1"), second = base.appendingPathComponent("m2")
        defer {
            for m in [first, second] where MountPoint.isMounted(m) { MountPoint.detach(m, runner: ProcessCommandRunner()) }
            for d in MirrorMounts.attachedDevices(of: image, runner: ProcessCommandRunner()).prefix(1) {
                _ = try? ProcessCommandRunner().run("/usr/bin/hdiutil", ["detach", "-force", d])
            }
        }
        try attach(first)
        let dir = first.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let system = SystemVolumeTable()
        let seen = try #require(system.volume(containing: dir))
        #expect(seen.uuid != nil && seen.name == "CF T7")
        #expect(seen.kind == .externalDrive, "a disk image reads as \(seen)")
        let t = DestinationResolver(volumes: system).target(for: dir)
        #expect(t.volume?.relativePath == "Backups" && t.volume?.uuid == seen.uuid)
        #expect(t.displayName == "Backups on CF T7")

        _ = try ProcessCommandRunner().run("/usr/sbin/diskutil", ["rename", first.path, "CF T7 Renamed"])
        MountPoint.detach(first, runner: ProcessCommandRunner())
        try attach(second)
        #expect(DestinationResolver(volumes: system).locate(t).url.map(DestinationRules.canonical)
                == DestinationRules.canonical(second.appendingPathComponent("Backups")))
    }

    // MARK: rules for a destination

    @Test func aDestinationMustBeAFolderOutsideTheSourceThatCanBeWrittenTo() throws {
        let base = folder("rules"); defer {
            chmod(base.appendingPathComponent("locked").path, 0o755)
            try? FileManager.default.removeItem(at: base)
        }
        let src = base.appendingPathComponent("Projects"), inside = src.appendingPathComponent("Backups")
        let file = base.appendingPathComponent("note1.txt"), locked = base.appendingPathComponent("locked")
        let fine = base.appendingPathComponent("Backups")
        for d in [inside, locked, fine] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try Data("x".utf8).write(to: file)
        chmod(locked.path, 0o555)
        let table = FixedVolumeTable([vol(base.path, "B", "Scratch", onMac: true)])
        func refused(_ url: URL, _ sources: [URL] = [src]) -> [String] {
            DestinationRules.check(url, sources: sources, volumes: table, home: "/Users/nobody", systemRoots: [])
                .filter { $0.severity == .refusal }.map(\.message)
        }
        #expect(refused(file).first?.contains("is a file") == true)
        #expect(refused(src).first?.contains("is the folder being backed up") == true)
        #expect(refused(inside).first?.contains("is inside Projects") == true)
        #expect(refused(base).first?.contains("Projects, which is being backed up, is inside") == true)
        #expect(refused(locked).first?.contains("can't write") == true)
        #expect(refused(fine).isEmpty)
        // on the same disk as the source: allowed, with a word
        let warnings = DestinationRules.check(fine, sources: [src], volumes: table, home: "/Users/nobody", systemRoots: [])
        #expect(warnings.count == 1 && warnings[0].severity == .warning && warnings[0].message.contains("same disk"))
        #expect(DestinationRules.check(fine, sources: [src], volumes: FixedVolumeTable([vol(base.path, "B", "Scratch", onMac: true),
                                                                                         vol(src.path, "S", "Source")]),
                                       home: "/Users/nobody", systemRoots: []).isEmpty)
    }

    @Test func systemPlacesAndBackupsAreRefused() throws {
        let base = folder("sys"); defer { try? FileManager.default.removeItem(at: base) }
        #expect(DestinationRules.systemLocation(URL(fileURLWithPath: "/"), home: "/Users/j") != nil)
        #expect(DestinationRules.systemLocation(URL(fileURLWithPath: "/Volumes"), home: "/Users/j") != nil)
        #expect(DestinationRules.systemLocation(URL(fileURLWithPath: "/Library/Application Support"), home: "/Users/j") != nil)
        #expect(DestinationRules.systemLocation(URL(fileURLWithPath: "/Users/j/Library/Caches"), home: "/Users/j") != nil)
        #expect(DestinationRules.systemLocation(URL(fileURLWithPath: "/Users/j/Library/CloudStorage/Dropbox/Backups"), home: "/Users/j") == nil)
        #expect(DestinationRules.systemLocation(URL(fileURLWithPath: "/Users/j/Backups"), home: "/Users/j") == nil)
        #expect(DestinationRules.systemLocation(URL(fileURLWithPath: "/Volumes/T7/Backups"), home: "/Users/j") == nil)
        // inside a library folder a run made
        let lib = base.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: lib.appendingPathComponent("2026-09-01-020000"), withIntermediateDirectories: true)
        try LibraryIdentity(jobID: "j", libraryID: "p", name: "Photos", jobName: "J").write(in: lib)
        #expect(DestinationRules.insideBackup(lib.appendingPathComponent("2026-09-01-020000"))?.path == lib.path)
        #expect(DestinationRules.insideBackup(base) == nil)
    }

    // Before anything is made, what will be: one folder per library, the second of
    // two with one name told apart by its short id, and a folder already there kept.
    @Test func thePreviewSaysWhatWillBeCreatedWhere() throws {
        let dest = folder("preview"); defer { try? FileManager.default.removeItem(at: dest) }
        let work = ContentType.genericFolder(id: "w", displayName: "Projects", path: .absolute("/Users/j/Work/Projects"))
        let home = ContentType.genericFolder(id: "h", displayName: "Projects", path: .absolute("/Users/j/Home/Projects"))
        let job = BackupJob(id: "a", name: "J", libraries: [work, home], target: .localVolume(id: "d", name: "D", dir: dest),
                            format: .sealedZip, frequency: .manual, createdAt: Date())
        let before = DestinationRules.preview(dest, job: job)
        let a = try LibraryFolders.prepare(job: job, library: work, in: dest, jobs: [job], isOpen: { _ in false }).folder
        let b = try LibraryFolders.prepare(job: job, library: home, in: dest, jobs: [job], isOpen: { _ in false }).folder
        #expect(before[0] == "Projects: creates \(a.path), with a dated folder for each backup inside it", "\(before)")
        #expect(before[1].contains("creates \(b.path)"), "\(before)")
        #expect(DestinationRules.preview(dest, job: job) == ["Projects: keeps using \(a.path)", "Projects: keeps using \(b.path)"])
    }

    // MARK: rules for a source

    @Test func aSourceMustBeReadableAndApartFromTheDestinations() throws {
        let base = folder("src"); defer {
            chmod(base.appendingPathComponent("Secret").path, 0o755)
            try? FileManager.default.removeItem(at: base)
        }
        let dest = base.appendingPathComponent("Backups"), projects = base.appendingPathComponent("Projects")
        let secret = base.appendingPathComponent("Secret"), backup = dest.appendingPathComponent("Photos")
        for d in [dest, projects, secret, backup] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try LibraryIdentity(jobID: "j", libraryID: "p", name: "Photos", jobName: "J").write(in: backup)
        chmod(secret.path, 0o000)
        func refused(_ u: URL) -> [String] {
            SourceRules.check(u, destinations: [dest], systemRoots: []).filter { $0.severity == .refusal }.map(\.message)
        }
        #expect(refused(projects).isEmpty)
        #expect(refused(base.appendingPathComponent("Missing")).first?.contains("doesn't exist") == true)
        #expect(refused(secret).first?.contains("can't read") == true)
        #expect(refused(dest).first?.contains("where this job's backups go") == true)
        #expect(refused(backup).contains { $0.contains("a Cryoframe backup") })
        #expect(refused(base).first?.contains("Backups, where this job's backups go, is inside") == true)
    }

    @Test func aSourceHasAFriendlyName() {
        let table = FixedVolumeTable([boot, vol("/Volumes/Work SSD", "W", "Work SSD")])
        #expect(SourceRules.friendlyName(for: URL(fileURLWithPath: "/Users/jdoe/Projects"), volumes: table, home: "/Users/jdoe") == "Projects in your home folder")
        #expect(SourceRules.friendlyName(for: URL(fileURLWithPath: "/Volumes/Work SSD/Projects"), volumes: table, home: "/Users/jdoe") == "Projects on Work SSD")
    }

    // A custom folder on a drive since renamed: its library is found on the drive by
    // the drive's UUID.
    @Test func aSourceOnARenamedDriveIsFoundAgain() {
        var lib = ContentType.genericFolder(id: "p", displayName: "Projects", path: .absolute("/Volumes/Work/Projects"))
        lib.volume = VolumeIdentity(uuid: "W", name: "Work", relativePath: "Projects")
        let table = FixedVolumeTable([boot, vol("/Volumes/Work SSD", "W", "Work SSD")])
        #expect(lib.located(volumes: table, home: "/Users/j").paths == [.absolute("/Volumes/Work SSD/Projects")])
        let gone = FixedVolumeTable([boot])
        #expect(lib.located(volumes: gone, home: "/Users/j").paths == lib.paths)
    }

    // A folder at a source's path on another volume isn't the source: on another
    // drive of its drive's name it's refused and said so; on the startup disk (a
    // folder left where the drive mounted), the drive isn't connected.
    @Test func aFolderAtASourcesPathOnAnotherVolumeIsntTheSource() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cf-src-\(UUID().uuidString.prefix(8))")
        let papers = base.appendingPathComponent("T7/Papers")
        try FileManager.default.createDirectory(at: papers, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        var lib = ContentType.genericFolder(id: "p", displayName: "Papers", path: .absolute(papers.path))
        lib.volume = VolumeIdentity(uuid: "REAL", name: "T7", relativePath: "Papers")
        let mount = base.appendingPathComponent("T7")
        let same = FixedVolumeTable([MountedVolume(mountPoint: mount, uuid: "REAL", name: "T7", isInternal: false)])
        #expect(lib.whereabouts(volumes: same, home: "/Users/j") == .here(lib))
        let impostor = FixedVolumeTable([MountedVolume(mountPoint: mount, uuid: "OTHER", name: "T7", isInternal: false)])
        guard case .otherDrive(let why) = lib.whereabouts(volumes: impostor, home: "/Users/j") else {
            Issue.record("another drive of its name was taken for it"); return
        }
        #expect(why.contains("different drive named “T7”"), "\(why)")
        let leftover = FixedVolumeTable([MountedVolume(mountPoint: URL(fileURLWithPath: "/"), uuid: "DATA", name: "Macintosh HD", isRoot: true)])
        guard case .away = lib.whereabouts(volumes: leftover, home: "/Users/j") else {
            Issue.record("a folder on the startup disk was taken for the drive's"); return
        }
    }
    // A destination that takes turns between two drives of one name (how 1.5 rotated)
    // is found on either, and another drive of that name is still not it.
    @Test func aDestinationIsFoundOnEitherOfTheDrivesItTakesTurnsOn() {
        var t = Target.externalDrive(id: "t7", name: "T7", dir: URL(fileURLWithPath: "/Volumes/T7/Backups"))
        t.volume = VolumeIdentity(uuid: "A", name: "T7", relativePath: "Backups", learnedAt: Date(timeIntervalSince1970: 0))
        t.otherVolumes = [VolumeIdentity(uuid: "B", name: "T7", relativePath: "Backups", learnedAt: Date(timeIntervalSince1970: 0))]
        func on(_ uuid: String, at mount: String = "/Volumes/T7") -> DestinationPresence {
            DestinationResolver(volumes: FixedVolumeTable([boot, vol(mount, uuid, "T7")])).locate(t)
        }
        #expect(on("A").url?.path == "/Volumes/T7/Backups")
        #expect(on("B").url?.path == "/Volumes/T7/Backups")
        #expect(on("B", at: "/Volumes/T7 1").url?.path == "/Volumes/T7 1/Backups")
        guard case .otherDrive = on("C") else { Issue.record("a third drive of the name was taken for it"); return }
    }

    // A destination whose drive a run learned meets another drive of its name that
    // holds nothing of the job's: refused, and nothing is written to it.
    @Test func aLearnedDestinationStillRefusesASameNamedDriveWithoutTheJobsBackups() async throws {
        let base = folder("learned")
        defer { try? FileManager.default.removeItem(at: base) }
        let dest = base.appendingPathComponent("T7/Backups"), src = base.appendingPathComponent("Papers")
        for d in [dest, src] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try Data("x".utf8).write(to: src.appendingPathComponent("a.txt"))
        var t = Target.externalDrive(id: "t7", name: "T7", dir: dest)
        t.volume = VolumeIdentity(uuid: "A", name: "T7", relativePath: "Backups", learnedAt: Date(timeIntervalSince1970: 0))
        let job = BackupJob(name: "Papers", libraries: [.genericFolder(id: "p", displayName: "Papers", path: .absolute(src.path))],
                            target: t, format: .sealedZip, frequency: .manual, createdAt: Date(timeIntervalSince1970: 0))
        let exec = JobExecutor(helper: FakePrivilegedHelper(), detector: FakeProcessDetector(),
                               scratchBase: base.appendingPathComponent("scratch"),
                               volumes: FixedVolumeTable([vol(base.appendingPathComponent("T7").path, "B", "T7")]))
        do {
            _ = try await exec.run(job, ownerUID: getuid(), now: Date())
            Issue.record("wrote to a drive of its name with nothing of the job's on it")
        } catch let TargetError.unavailable(why) {
            #expect(why.contains("different drive"), "\(why)")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dest.path).isEmpty)
    }
    // A 1.5 folder on a drive is this job's only by what only this job can have made:
    // a version stamped when one of its runs started, the exact size that run recorded
    // for the library. Not its name and bundle name, and not the time alone (two Macs
    // on the default schedule stamp versions in the same second).
    @Test func a15FolderIsThisJobsOnlyIfAVersionMatchesOneOfItsRuns() throws {
        let dest = folder("evidence")
        defer { try? FileManager.default.removeItem(at: dest) }
        let stamp = "2026-09-01-020000", made = try #require(VersionStamp.date(stamp))
        let v = dest.appendingPathComponent("Papers/\(stamp)")
        try FileManager.default.createDirectory(at: v, withIntermediateDirectories: true)
        try Data(count: 12_345).write(to: v.appendingPathComponent("Papers.zip"))
        _ = try ArchiveManifest.write(try ArchiveManifest.build(for: ArchiveResult(artifacts: [v.appendingPathComponent("Papers.zip")],
                                                                                   format: .sealedZip)), toDir: v)
        let job = BackupJob(id: "mine", name: "Papers", libraries: [.genericFolder(id: "p", displayName: "Papers", path: .absolute("/Users/j/Papers"))],
                            target: .externalDrive(id: "t7", name: "T7", dir: dest), format: .sealedZip, frequency: .manual,
                            createdAt: Date(timeIntervalSince1970: 0))
        func run(_ jobID: String, at start: Date, bytes: UInt64) -> RunRecord {
            RunRecord(id: UUID().uuidString, jobID: jobID, jobName: "Papers", startedAt: start, finishedAt: start.addingTimeInterval(60),
                      trigger: "scheduled", outcome: .completed, summary: "",
                      libraries: [LibraryOutcome(from: .completed(library: "Papers", destination: "T7", parts: 1, bytes: bytes, verified: nil))],
                      bytes: bytes, warning: nil)
        }
        #expect(LibraryFolders.holdsBackups(of: job, in: dest, runs: [run("mine", at: made.addingTimeInterval(-0.4), bytes: 12_345)]))
        #expect(!LibraryFolders.holdsBackups(of: job, in: dest, runs: []), "a name and a bundle name")
        #expect(!LibraryFolders.holdsBackups(of: job, in: dest, runs: [run("mine", at: made, bytes: 12_346)]), "the time alone")
        #expect(!LibraryFolders.holdsBackups(of: job, in: dest, runs: [run("mine", at: made.addingTimeInterval(-86_400), bytes: 12_345)]))
        #expect(!LibraryFolders.holdsBackups(of: job, in: dest, runs: [run("theirs", at: made, bytes: 12_345)]))
    }
}
