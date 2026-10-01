//
//  HeldVersionEdgeTests.swift
//  CryoframeKitTests
//
//  The M5a fix round at its edges. Versions held when a job changes between a
//  mirror and sealed versions: never pruned, still found by Restore, and still read
//  by the job they may belong to when the job changes back. The run history's
//  evidence of a rotation's other drive, for an hourly job keeping a few versions.
//  A sparse file the copier left alone isn't written again on the next run.
//

import Testing
import Foundation
@testable import CryoframeKit

private let start = Date(timeIntervalSince1970: 1_790_000_000)
private let hour: TimeInterval = 3600, day: TimeInterval = 86_400
private let v1 = "2026-09-01-020000", v2 = "2026-09-02-020000"
private let bundle = "Photos Library.photoslibrary"

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-held-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

@discardableResult
private func version(in dir: URL, _ name: String, bundle: String = bundle) throws -> URL {
    let at = dir.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: at, withIntermediateDirectories: true)
    let f = at.appendingPathComponent(bundle + ".zip")
    try Data("zip \(UUID())".utf8).write(to: f)
    _ = try ArchiveManifest.write(try ArchiveManifest.build(for: ArchiveResult(artifacts: [f], format: .sealedZip)), toDir: at)
    return at
}

private func mirrorTop(in dir: URL) throws {
    let sb = dir.appendingPathComponent(bundle + ".sparsebundle")
    try FileManager.default.createDirectory(at: sb.appendingPathComponent("bands"), withIntermediateDirectories: true)
    try Data("band".utf8).write(to: sb.appendingPathComponent("bands/0"))
    _ = try ArchiveManifest.write(try ArchiveManifest.build(for: ArchiveResult(artifacts: [sb], format: .liveMirror)), toDir: dir)
}

private func versions(_ dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { VersionStamp.date($0) != nil }.sorted()
}

private func random(_ n: Int) -> Data { var d = Data(count: n); d.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, n) }; return d }
private func blocks(_ url: URL) -> off_t { var st = stat(); return lstat(url.path, &st) == 0 ? off_t(st.st_blocks) * 512 : -1 }

private func syncWithRsync(_ lib: URL, into next: URL) throws {
    let runner = ProcessCommandRunner()
    try MirrorCopy.sync(lib, into: next, runner: runner) { cmd in
        let r = try runner.run(cmd.tool, cmd.args, stdin: nil)
        guard r.ok else { throw ArchiveError.toolFailed(tool: cmd.tool, status: r.status, stderr: r.stderr) }
    }
}

/// Two mirror runs of `lib`: the first into an empty copy, the second into a clone of
/// the first (as a run makes it). What the second run's read-back counts as written.
private func secondRunWrites(_ lib: URL, in base: URL, cloneByCp: Bool = false) throws -> [String] {
    let vol = base.appendingPathComponent("vol")
    let current = vol.appendingPathComponent("Lib"), staging = vol.appendingPathComponent(".cryoframe-staging")
    let next = staging.appendingPathComponent("Lib")
    for d in [current, staging] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
    try syncWithRsync(lib, into: current)
    if cloneByCp {
        let r = try ProcessCommandRunner().run("/bin/cp", ["-c", "-R", "-p", current.path, next.path], stdin: nil)
        try #require(r.ok, "\(r.stderr)")
    } else {
        try MirrorCopy.clone(current, to: next, runner: ProcessCommandRunner())
    }
    try syncWithRsync(lib, into: next)
    let found = try MirrorCopy.structure(of: next, against: lib, previous: current, control: nil)
    #expect(found.count == 0, "\(found.examples)")
    return found.written
}

@Suite(.serialized) struct HeldVersionEdgeTests {
    let photos = ContentType.genericFolder(id: "com.apple.photos", displayName: "Photos",
                                           path: .absolute("/Users/someone/Pictures/Photos Library.photoslibrary"))

    // MARK: held versions

    // A sealed job made a mirror job, then a sealed job again. The versions it made
    // before are held: never pruned, however many new ones it makes, and Restore
    // (which scans the destination) still lists them.
    @Test func aJobSwitchedTwiceKeepsItsOldVersionsAndRestoreFindsThem() throws {
        let dest = folder("twice"); defer { try? FileManager.default.removeItem(at: dest) }
        var a = BackupJob(id: "a", name: "Photos", libraries: [photos], target: .localVolume(id: "d", name: "Dest", dir: dest),
                          format: .sealedZip, frequency: .manual, retention: .keepLast(1), createdAt: start)
        let mine = try LibraryFolders.prepare(job: a, library: photos, in: dest, jobs: [a], isOpen: { _ in false }).folder
        for v in [v1, v2] { try version(in: mine, v) }
        a.format = .liveMirror(sizeGB: 1)
        _ = try LibraryFolders.prepare(job: a, library: photos, in: dest, jobs: [a], isOpen: { _ in false })
        try mirrorTop(in: mine)
        a.format = .sealedZip
        let at = { (d: Int) in VersionStamp.string(start.addingTimeInterval(Double(d) * day)) }
        for d in 1...3 {
            _ = try LibraryFolders.prepare(job: a, library: photos, in: dest, jobs: [a], isOpen: { _ in false })
            try version(in: mine, at(d))
            JobExecutor.pruneVersions(folders: JobExecutor.prunable(a, ["d": [photos.id: mine]]), policy: a.retention, confirmed: { _, _ in true })
        }
        #expect(versions(mine) == [v1, v2, at(3)], "held versions stay, the job's new ones are pruned")
        let found = Set(RestoreDiscovery.scan(dest).compactMap { $0.version.map(VersionStamp.string) })
        #expect(found.isSuperset(of: [v1, v2, at(3)]), "Restore lists them: \(found.sorted())")
    }

    // A mirror job made a sealed job holds the paused sealed job's versions, and that
    // job reads them (aMirrorJobMadeSealedHoldsWhatItsFolderHad). The job is then made
    // a mirror job again: the paused job's versions, still there, are no longer read
    // by it (no check or drill looks at them, and its storage doesn't count them), nor
    // moved home, as they are now "held" in a mirror job's folder.
    @Test func anotherJobsHeldVersionsStayReadAfterTheJobIsMadeAMirrorAgain() throws {
        let dest = folder("back"); defer { try? FileManager.default.removeItem(at: dest) }
        let legacy = dest.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try mirrorTop(in: legacy)
        for v in [v1, v2] { try version(in: legacy, v) }
        var m = BackupJob(id: "m", name: "Photos mirror", libraries: [photos], target: .localVolume(id: "d", name: "Dest", dir: dest),
                          format: .liveMirror(sizeGB: 1), frequency: .manual, createdAt: start)
        var s = BackupJob(id: "s", name: "Photos versions", libraries: [photos], target: .localVolume(id: "d", name: "Dest", dir: dest),
                          format: .sealedZip, frequency: .manual, createdAt: start)
        s.enabled = false
        _ = try LibraryFolders.prepare(job: m, library: photos, in: dest, jobs: [m, s], isOpen: { _ in false })
        m.format = .sealedZip
        _ = try LibraryFolders.prepare(job: m, library: photos, in: dest, jobs: [m, s], isOpen: { _ in false })
        let before = Set(LibraryFolders.archives(job: s, library: photos, in: dest).map(\.dir.lastPathComponent))
        #expect(before == [v1, v2])

        m.format = .liveMirror(sizeGB: 1)
        _ = try LibraryFolders.prepare(job: m, library: photos, in: dest, jobs: [m, s], isOpen: { _ in false })
        s.enabled = true
        _ = try LibraryFolders.prepare(job: s, library: photos, in: dest, jobs: [m, s], isOpen: { _ in false })
        #expect(versions(legacy) == [v1, v2] || versions(legacy).isEmpty, "\(versions(legacy))")
        let after = Set(LibraryFolders.archives(job: s, library: photos, in: dest).map(\.dir.lastPathComponent))
        #expect(after == [v1, v2], "the paused job no longer reads its versions: \(after.sorted())")
    }

    // 1.5.6 to 1.6: a 1.5 folder of a sealed job's versions, taken over. Nothing is
    // held, and retention prunes as before.
    @Test func anUpgradedSealedFolderHoldsNothing() throws {
        let dest = folder("upgrade"); defer { try? FileManager.default.removeItem(at: dest) }
        let legacy = dest.appendingPathComponent("Photos")
        for v in [v1, v2] { try version(in: legacy, v) }
        let s = BackupJob(id: "s", name: "Photos", libraries: [photos], target: .localVolume(id: "d", name: "Dest", dir: dest),
                          format: .sealedZip, frequency: .manual, retention: .keepLast(1), createdAt: start)
        let f = try LibraryFolders.prepare(job: s, library: photos, in: dest, jobs: [s], isOpen: { _ in false }).folder
        #expect(f.path == legacy.path)
        _ = try LibraryFolders.prepare(job: s, library: photos, in: dest, jobs: [s], isOpen: { _ in false })
        let id = try #require(LibraryIdentity.read(in: f))
        #expect(id.heldVersions == nil && id.mirror == nil)
        JobExecutor.pruneVersions(folders: JobExecutor.prunable(s, ["d": [photos.id: f]]), policy: s.retention, confirmed: { _, _ in true })
        #expect(versions(f) == [v2])
    }

    // MARK: the evidence of a rotation's other drive

    // A 1.5 job backs up Papers every hour to two drives named "T7" that take turns,
    // keeping its last 14 versions (the app's own preset, on an hourly schedule). Drive
    // B was at home until 17:00 on day 0, so it keeps the versions of 04:00 to 17:00.
    // The history keeps each day's first and last run that wrote: day 0's 00:00 (pruned
    // from B) and 23:00 (on drive A), and day -1's (both pruned from B). Once 200 newer
    // runs push out the rest, no run matches a version on B, and B is refused as "a
    // different drive" when it comes home.
    @Test func anHourlyRotationsOtherDriveKeepsItsEvidence() throws {
        let base = folder("hourly"); defer { try? FileManager.default.removeItem(at: base) }
        let driveB = base.appendingPathComponent("B/Backups")
        let papers = ContentType.genericFolder(id: "papers", displayName: "Papers", path: .absolute("/Users/someone/Papers"))
        let job = BackupJob(name: "Papers", libraries: [papers], target: .externalDrive(id: "t7", name: "T7", dir: driveB),
                            format: .sealedZip, frequency: .everyHours(1), retention: .keepLast(14), createdAt: start)
        let day0 = Calendar.current.startOfDay(for: start)
        let swap = day0.addingTimeInterval(17 * hour)
        let store = RunHistoryStore(url: base.appendingPathComponent("history.json"))
        var bytesAt: [Date: UInt64] = [:]
        var at = day0.addingTimeInterval(-2 * day)
        while at < day0.addingTimeInterval(10 * day) {
            var bytes: UInt64 = 1_000_000 + UInt64(bytesAt.count)
            if at <= swap {                                  // on drive B, pruned to its last 14
                let v = try version(in: driveB.appendingPathComponent("Papers"), VersionStamp.string(at), bundle: "Papers")
                bytes = try #require(RestoreDiscovery.archive(at: v)).bytes
                bytesAt[at] = bytes
                let all = versions(driveB.appendingPathComponent("Papers"))
                for old in all.dropLast(14) { try FileManager.default.removeItem(at: driveB.appendingPathComponent("Papers/\(old)")) }
            }
            store.append(RunRecord(id: UUID().uuidString, jobID: job.id, jobName: job.name, startedAt: at, finishedAt: at.addingTimeInterval(120),
                                   trigger: "scheduled", outcome: .completed, summary: "",
                                   libraries: [LibraryOutcome(from: .completed(library: "Papers", destination: "T7", parts: 1, bytes: bytes, verified: true))],
                                   bytes: bytes, warning: nil))
            at = at.addingTimeInterval(hour)
        }
        try #require(versions(driveB.appendingPathComponent("Papers")).count == 14)
        #expect(LibraryFolders.holdsBackups(of: job, in: driveB, runs: store.all()),
                "drive B's runs are gone from a history of \(store.all().count) runs")
    }

    // MARK: sparse files on the next run

    // A sparse VM disk whose date has a fraction of a second, unchanged since the last
    // run: the next run carries it (its clone is left alone), whichever way the copy
    // was cloned.
    @Test(arguments: [false, true]) func aSparseFileWithAFractionalDateIsCarried(cloneByCp: Bool) throws {
        let base = folder("frac"); defer { try? FileManager.default.removeItem(at: base) }
        let lib = base.appendingPathComponent("Lib")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        let vm = lib.appendingPathComponent("vm.img")
        try #require(FileManager.default.createFile(atPath: vm.path, contents: nil))
        let fh = try FileHandle(forWritingTo: vm)
        try fh.truncate(atOffset: 256 << 20)
        try fh.seek(toOffset: 128 << 20); try fh.write(contentsOf: random(65_536))
        try fh.close()
        var times = [timespec(tv_sec: 1_700_000_000, tv_nsec: 123_456_789), timespec(tv_sec: 1_700_000_000, tv_nsec: 987_654_321)]
        try #require(utimensat(AT_FDCWD, vm.path, &times, 0) == 0)
        try #require(blocks(vm) < 8 << 20)
        let written = try secondRunWrites(lib, in: base, cloneByCp: cloneByCp)
        #expect(!written.contains("vm.img"), "written again on a run where nothing changed")
    }

    // A 16 MiB sparse file (a disk image with a hole punched in it): the copier writes
    // its data ranges into a file of its length, and APFS fills a file that small in,
    // so the copy takes more room than the library's plus 1 MiB. Every run then finds
    // it "not current", writes it again, and reads it back.
    @Test func aSmallSparseFileIsNotWrittenAgainEveryRun() throws {
        let base = folder("small"); defer { try? FileManager.default.removeItem(at: base) }
        let lib = base.appendingPathComponent("Lib")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        let img = lib.appendingPathComponent("disk.img")
        try random(16 << 20).write(to: img)
        let fd = open(img.path, O_RDWR); defer { close(fd) }
        var hole = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: 1 << 20, fp_length: 14 << 20)
        try #require(fcntl(fd, F_PUNCHHOLE, &hole) == 0)
        fsync(fd)
        var st = stat(); lstat(img.path, &st)
        try #require(MirrorCopy.isSparse(img.path, st), "the library file isn't sparse: \(blocks(img))")
        let written = try secondRunWrites(lib, in: base)
        #expect(!written.contains("disk.img"), "written again (and read back) on a run where nothing changed")
    }
}
