//
//  M5bAdoptionEdgeTests.swift
//  CryoframeKitTests
//
//  The go-ahead for adopted versions (see AdoptedVersions.swift), checked against
//  what a later run actually deletes: the count a person says yes to has to cover
//  what goes.
//

import Testing
import Foundation
@testable import CryoframeKit

private let start = Date(timeIntervalSince1970: 1_790_000_000)
private let day: TimeInterval = 86_400

private func scratch(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-adoptedge-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return TempTracker.track(d) }
    defer { free(real) }
    return TempTracker.track(URL(fileURLWithPath: String(cString: real), isDirectory: true))
}

private let papers = ContentType.genericFolder(id: "papers", displayName: "Papers", path: .absolute("/Users/me/Papers"))

private func job(_ dests: [URL], id: String = "job-1", library: ContentType = papers,
                 format: FormatChoice = .sealedZip, retention: RetentionPolicy) -> BackupJob {
    BackupJob(id: id, name: "Papers", libraries: [library],
              targets: dests.map { Target.localVolume(id: $0.path, name: $0.lastPathComponent, dir: $0) },
              format: format, frequency: .manual, retention: retention, createdAt: start)
}

private func version(in dir: URL, _ date: Date) throws {
    let at = dir.appendingPathComponent(VersionStamp.string(date))
    try FileManager.default.createDirectory(at: at, withIntermediateDirectories: true)
    let f = at.appendingPathComponent("Papers.zip")
    try Data("zip \(date)".utf8).write(to: f)
    _ = try ArchiveManifest.write(try ArchiveManifest.build(for: ArchiveResult(artifacts: [f], format: .sealedZip)), toDir: at)
}

/// a folder 1.5 wrote, "Papers", with a version on each of `days` (after `start`)
private func legacyFolder(in dest: URL, days: [Double]) throws -> URL {
    let legacy = dest.appendingPathComponent("Papers", isDirectory: true)
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    for d in days { try version(in: legacy, start.addingTimeInterval(d * day)) }
    return legacy
}

/// a small HFS+ volume at `<base>/vol` holding "Papers" (read live: no snapshot)
private func sourceVolume(in base: URL) throws -> (mnt: URL, papers: URL) {
    let mnt = base.appendingPathComponent("vol")
    try FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)
    let dmg = base.appendingPathComponent("src.dmg")
    let made = try ProcessCommandRunner().run("/usr/bin/hdiutil", ["create", "-size", "20m", "-fs", "HFS+", "-volname", "Src", dmg.path])
    try #require(made.ok, "\(made.stderr)")
    let attached = try DiskImageGate.serialized {
        try ProcessCommandRunner().runRetryingBusy("/usr/bin/hdiutil", ["attach", dmg.path, "-mountpoint", mnt.path, "-nobrowse", "-owners", "on"])
    }
    try #require(attached.ok && MountPoint.isMounted(mnt), "\(attached.stderr)")
    let papers = mnt.appendingPathComponent("Papers")
    try FileManager.default.createDirectory(at: papers, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: papers.appendingPathComponent("a.txt"))
    return (mnt, papers)
}

@Suite(.serialized) struct M5bAdoptionEdgeTests {
    // Under a GFS rule, the dashboard's count is worked out right after a run, with
    // the next backup placed at that same moment: it shares a day with the version
    // the run just made. The real next backup is tomorrow's, and takes a day of its
    // own, so one more adopted version falls out of the daily window than was said.
    @Test func aGFSYesOnTheDashboardDeletesNoMoreThanItSaid() async throws {
        let base = scratch("gfs-run")
        let (mnt, src) = try sourceVolume(in: base)
        defer { MountPoint.detach(mnt, runner: ProcessCommandRunner()) }
        let dest = base.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let legacy = try legacyFolder(in: dest, days: [7, 8, 9])
        let lib = ContentType.genericFolder(id: "papers", displayName: "Papers", path: .absolute(src.path))
        let store = JobStore(url: base.appendingPathComponent("jobs.json"))
        store.upsert(job([dest], library: lib, retention: .gfs(daily: 3, weekly: 0, monthly: 0)))
        let exec = JobExecutor(helper: FakePrivilegedHelper(), detector: FakeProcessDetector(),
                               scratchBase: base.appendingPathComponent("scratch"), jobStore: store, volumes: FixedVolumeTable([]))

        let first = try await exec.run(try #require(store.load().jobs.first), ownerUID: getuid(), now: start.addingTimeInterval(10 * day))
        guard case .finished = first else { Issue.record("\(first)"); return }
        let review = try #require(store.load().adoptionReviews["job-1"]?.first)
        let shown = review.deletes + review.unfinished
        #expect(store.confirm(review, at: start.addingTimeInterval(10 * day)))

        let before = LibraryFolders.versionNames(in: legacy)
        let second = try await exec.run(try #require(store.load().jobs.first), ownerUID: getuid(), now: start.addingTimeInterval(11 * day))
        guard case .finished = second else { Issue.record("\(second)"); return }
        let gone = before.subtracting(LibraryFolders.versionNames(in: legacy)).intersection(review.versions)
        #expect(gone.count <= shown, "the card said \(shown) deleted; tomorrow's backup deleted \(gone.count): \(gone.sorted())")
    }

    // The same, in the save summary of a job that took a 1.5 folder over at a run no
    // one said yes to: saved later the same day, it counts the next backup as if it
    // ran at the moment of saving.
    @Test func aGFSSaveSummaryCountsWhatTomorrowsBackupDeletes() throws {
        let dest = scratch("gfs-save")
        let legacy = try legacyFolder(in: dest, days: [7, 8, 9])
        let saved = job([dest], retention: .gfs(daily: 3, weekly: 0, monthly: 0))
        // the first run, with the drive away when the job was made: taken over, its own version made
        let folder = try LibraryFolders.prepare(job: saved, library: papers, in: dest, jobs: [saved], isOpen: { _ in false }).folder
        #expect(folder.path == legacy.path)
        try version(in: folder, start.addingTimeInterval(10 * day))
        // later that day the person edits the job, and the summary asks for the yes
        var draft = saved; draft.name = "Papers (renamed)"
        let impact = JobEditImpact.of(draft: draft, base: saved, jobs: [saved], volumes: FixedVolumeTable([]),
                                      now: start.addingTimeInterval(10 * day + 3 * 3600))
        let consent = try #require(impact.consents.first)
        let stored = draft.adding(impact.consents)
        let t = stored.targets[0]

        let before = LibraryFolders.versionNames(in: folder)
        try version(in: folder, start.addingTimeInterval(11 * day))      // tomorrow's backup
        JobExecutor.pruneVersions(folders: [(papers, folder)], policy: stored.retention,
                                  confirmed: { _, v in stored.confirmsAdoption(of: v, target: t.id, library: papers.id) })
        let gone = before.subtracting(LibraryFolders.versionNames(in: folder)).intersection(consent.versions)
        #expect(gone.count <= impact.deletes, "the summary said \(impact.deletes) deleted; tomorrow's backup deleted \(gone.count): \(gone.sorted())")
    }

    // A dashboard card is the count under the Keep rule of the run that made it. The
    // person lowers the Keep rule while the drive is away (the summary can't count
    // there, so it asks for nothing), then says yes on the card: it still says none
    // are deleted.
    @Test func aCardFromBeforeTheKeepRuleWasLoweredIsNotTakenAsAYesToTheNewRule() throws {
        let base = scratch("stale")
        let dest = base.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        _ = try legacyFolder(in: dest, days: [0, 1, 2, 3])
        let store = JobStore(url: base.appendingPathComponent("jobs.json"))
        let generous = job([dest], retention: .keepLast(10))
        store.upsert(generous)
        let t = generous.targets[0]
        // a run: takes the folder over, makes its version, leaves the four for the card
        let folder = try LibraryFolders.prepare(job: generous, library: papers, in: dest, jobs: [generous], isOpen: { _ in false }).folder
        try version(in: folder, start.addingTimeInterval(10 * day))
        let made = JobExecutor.adoptionReviews(generous, [t.id: [papers.id: folder]], checks: [], transferring: { _ in false },
                                               confirmed: { _, _ in false }, now: start.addingTimeInterval(10 * day))
        store.recordAdoptionReviews(jobID: generous.id, made, reached: [t.id])
        let card = try #require(store.load().adoptionReviews[generous.id]?.first)
        #expect(card.deletes + card.unfinished == 0)

        // Keep lowered to 1 with the drive away: nothing to count, nothing asked
        let away = base.appendingPathComponent("dest-away")
        try FileManager.default.moveItem(at: dest, to: away)
        var lowered = generous; lowered.retention = .keepLast(1)
        let impact = JobEditImpact.of(draft: lowered, base: generous, jobs: [generous], volumes: FixedVolumeTable([]),
                                      now: start.addingTimeInterval(10 * day + 3600))
        try FileManager.default.moveItem(at: away, to: dest)
        try #require(impact.consents.isEmpty)
        store.upsert(try #require(JobEdit.merge(draft: lowered, base: generous, stored: store.load().jobs.first)))

        // the card is still there, still saying none go; the person says yes to it
        let still = try #require(store.load().adoptionReviews[generous.id]?.first)
        let said = still.deletes + still.unfinished
        let confirmed = store.confirm(still)
        let now = try #require(store.load().jobs.first)
        let before = LibraryFolders.versionNames(in: folder)
        try version(in: folder, start.addingTimeInterval(11 * day))
        JobExecutor.pruneVersions(folders: [(papers, folder)], policy: now.retention,
                                  confirmed: { _, v in now.confirmsAdoption(of: v, target: t.id, library: papers.id) })
        let gone = before.subtracting(LibraryFolders.versionNames(in: folder)).intersection(still.versions)
        #expect(!confirmed || gone.count <= said, "the card said \(said) deleted under keepLast(10); the yes deleted \(gone.count) under keepLast(1)")
    }

    // A yes covers the versions it named, no others: one moved in after it (a 1.5.6
    // run into the folder it shares with a mirror job, say) is left alone until asked.
    @Test func aVersionMovedInAfterTheYesIsLeftAloneUntilAsked() throws {
        let dest = scratch("later")
        let shared = dest.appendingPathComponent("Papers", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        for d in [0.0, 1] { try version(in: shared, start.addingTimeInterval(d * day)) }
        let mirror = job([dest], id: "mirror-job", format: .liveMirror(sizeGB: 1), retention: .keepAll)
        try LibraryIdentity(job: mirror, library: papers).write(in: shared)
        let draft = job([dest], retention: .keepLast(1))
        let impact = JobEditImpact.of(draft: draft, base: nil, jobs: [mirror], volumes: FixedVolumeTable([]), now: start.addingTimeInterval(10 * day))
        #expect(impact.consents.first?.versions.count == 2)
        let saved = draft.adding(impact.consents)
        let t = saved.targets[0]
        let confirmed: (URL, String) -> Bool = { _, v in saved.confirmsAdoption(of: v, target: t.id, library: papers.id) }

        let folder = try LibraryFolders.prepare(job: saved, library: papers, in: dest, jobs: [saved, mirror], isOpen: { _ in false }).folder
        try version(in: folder, start.addingTimeInterval(10 * day))
        JobExecutor.pruneVersions(folders: [(papers, folder)], policy: saved.retention, confirmed: confirmed)
        #expect(LibraryFolders.versionNames(in: folder) == [VersionStamp.string(start.addingTimeInterval(10 * day))])

        // a later version lands in the shared folder, and the next run moves it in
        let late = start.addingTimeInterval(5 * day)
        try version(in: shared, late)
        _ = try LibraryFolders.prepare(job: saved, library: papers, in: dest, jobs: [saved, mirror], isOpen: { _ in false })
        #expect(LibraryIdentity.read(in: folder)?.adopted(VersionStamp.string(late)) == true)
        try version(in: folder, start.addingTimeInterval(11 * day))
        JobExecutor.pruneVersions(folders: [(papers, folder)], policy: saved.retention, confirmed: confirmed)
        #expect(LibraryFolders.versionNames(in: folder).contains(VersionStamp.string(late)),
                "a version moved in after the yes was deleted without being asked about")
    }
}
