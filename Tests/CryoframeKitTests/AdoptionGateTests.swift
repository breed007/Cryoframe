//
//  AdoptionGateTests.swift
//  CryoframeKitTests
//
//  Versions a job's folder adopts (a 1.5 folder taken over, versions moved in from a
//  folder shared with a mirror job) are deleted by its Keep rule only once the
//  person has seen what that deletes and said yes (see AdoptedVersions.swift).
//

import Testing
import Foundation
@testable import CryoframeKit

private let start = Date(timeIntervalSince1970: 1_790_000_000)
private let day: TimeInterval = 86_400
private let hdiutil = "/usr/bin/hdiutil"

private func scratch(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-adopt-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return TempTracker.track(d) }
    defer { free(real) }
    return TempTracker.track(URL(fileURLWithPath: String(cString: real), isDirectory: true))
}

private let papers = ContentType.genericFolder(id: "papers", displayName: "Papers", path: .absolute("/Users/me/Papers"))

private func job(_ dests: [URL], id: String = "job-1", library: ContentType = papers,
                 format: FormatChoice = .sealedZip, retention: RetentionPolicy = .keepLast(2)) -> BackupJob {
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

private func legacyFolder(in dest: URL, versions n: Int) throws -> URL {
    let legacy = dest.appendingPathComponent("Papers", isDirectory: true)
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    for d in 0..<n { try version(in: legacy, start.addingTimeInterval(Double(d) * day)) }
    return legacy
}

/// a small HFS+ volume at `<base>/vol` holding "Papers" (read live: no snapshot)
private func sourceVolume(in base: URL) throws -> (mnt: URL, papers: URL) {
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
    try Data("x".utf8).write(to: papers.appendingPathComponent("a.txt"))
    return (mnt, papers)
}

@Suite(.serialized) struct AdoptionGateTests {
    // The engine's guard, whatever the screens did or didn't show: the first run over
    // a 1.5 folder takes it over and deletes none of its versions, says so, and
    // records what saying yes deletes. Once said yes to, the next run deletes that.
    @Test func aRunLeavesAdoptedVersionsAloneUntilThePersonSaysYes() async throws {
        let base = scratch("run")
        let (mnt, src) = try sourceVolume(in: base)
        defer { MountPoint.detach(mnt, runner: ProcessCommandRunner()) }
        let dest = base.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let legacy = try legacyFolder(in: dest, versions: 4)
        let old = LibraryFolders.versionNames(in: legacy)
        let lib = ContentType.genericFolder(id: "papers", displayName: "Papers", path: .absolute(src.path))
        let store = JobStore(url: base.appendingPathComponent("jobs.json"))
        store.upsert(job([dest], library: lib))
        let exec = JobExecutor(helper: FakePrivilegedHelper(), detector: FakeProcessDetector(),
                               scratchBase: base.appendingPathComponent("scratch"), jobStore: store, volumes: FixedVolumeTable([]))

        let first = try await exec.run(try #require(store.load().jobs.first), ownerUID: getuid(), now: start.addingTimeInterval(10 * day))
        guard case .finished(_, let warning) = first else { Issue.record("\(first)"); return }
        #expect(old.isSubset(of: LibraryFolders.versionNames(in: legacy)), "a version it adopted was deleted before anyone said yes")
        #expect(LibraryIdentity.read(in: legacy)?.adoptedVersions.map(Set.init) == old)
        #expect(warning?.contains("4 earlier backups of Papers") == true, "\(warning ?? "no warning")")
        let review = try #require(store.load().adoptionReviews["job-1"]?.first)
        #expect(Set(review.versions) == old)
        #expect(review.deletes == 4)                         // its own version and the next take the two places

        #expect(store.confirm(review, at: start.addingTimeInterval(10 * day)))
        #expect(store.load().adoptionReviews["job-1"] == nil)
        let before = LibraryFolders.versionNames(in: legacy)
        let second = try await exec.run(try #require(store.load().jobs.first), ownerUID: getuid(), now: start.addingTimeInterval(11 * day))
        guard case .finished(_, let said) = second else { Issue.record("\(second)"); return }
        let gone = before.subtracting(LibraryFolders.versionNames(in: legacy))
        #expect(gone == old, "deleted \(gone.sorted()), said yes to \(review.deletes) of \(old.sorted())")
        #expect(said?.contains("kept for now") != true)
    }

    // Versions moved in out of a mirror job's folder are adopted before they move, and
    // the Keep rule leaves them alone until said yes to.
    @Test func versionsMovedInAreAdoptedBeforeTheyMove() throws {
        let dest = scratch("moved")
        let shared = dest.appendingPathComponent("Papers", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        for d in 0..<4 { try version(in: shared, start.addingTimeInterval(Double(d) * day)) }
        let mirror = job([dest], id: "mirror-job", format: .liveMirror(sizeGB: 1), retention: .keepAll)
        try LibraryIdentity(job: mirror, library: papers).write(in: shared)
        let sealed = job([dest])
        let next = LibraryFolders.next(job: sealed, library: papers, in: dest, jobs: [mirror])
        #expect(next.folder == nil && next.movesIn.count == 4)

        let folder = try LibraryFolders.prepare(job: sealed, library: papers, in: dest, jobs: [sealed, mirror], isOpen: { _ in false }).folder
        #expect(LibraryFolders.versionNames(in: folder).count == 4)
        #expect(Set(LibraryIdentity.read(in: folder)?.adoptedVersions ?? []) == Set(next.adopts))
        try version(in: folder, start.addingTimeInterval(10 * day))
        let failures = JobExecutor.pruneVersions(folders: [(papers, folder)], policy: sealed.retention,
                                                 confirmed: { _, _ in false })
        #expect(failures.isEmpty)
        #expect(LibraryFolders.versionNames(in: folder).count == 5, "adopted versions were deleted without a yes")
        // its own versions still follow the rule
        try version(in: folder, start.addingTimeInterval(11 * day))
        try version(in: folder, start.addingTimeInterval(12 * day))
        JobExecutor.pruneVersions(folders: [(papers, folder)], policy: sealed.retention, confirmed: { _, _ in false })
        #expect(LibraryFolders.versionNames(in: folder).count == 6)
    }

    // What the save summary asks for is exactly what then goes: saving records the
    // yes, and a run with it deletes the count shown, no more.
    @Test func theSaveSummarysYesCoversWhatTheRunDeletes() throws {
        let dest = scratch("save")
        _ = try legacyFolder(in: dest, versions: 4)
        let draft = job([dest])
        let now = start.addingTimeInterval(10 * day)
        let impact = JobEditImpact.of(draft: draft, base: nil, volumes: FixedVolumeTable([]), now: now)
        #expect(impact.deletes == 3)
        let consent = try #require(impact.consents.first)
        // three go at the next backup; under keepLast(2) the fourth is pushed out by
        // the one after, and the same yes names it, so no one is asked again then
        #expect(consent.versions.count == 4 && consent.deletes == 4)
        #expect(impact.lines.contains { $0.text.contains("3 are deleted at the next backup; 1 more is deleted one at a time") })

        let saved = draft.adding(impact.consents)
        let t = saved.targets[0]
        let folder = try LibraryFolders.prepare(job: saved, library: papers, in: dest, jobs: [saved], isOpen: { _ in false }).folder
        try version(in: folder, now)
        let before = LibraryFolders.versionNames(in: folder).count
        // as a run does: what was shown takes its place, and only what was said to go goes
        JobExecutor.pruneVersions(folders: [(papers, folder)], policy: saved.retention,
                                  confirmed: { _, v in saved.confirmsAdoption(of: v, target: t.id, library: papers.id) },
                                  shown: { _, v in saved.hasShownAdoption(of: v, target: t.id, library: papers.id) })
        #expect(before - LibraryFolders.versionNames(in: folder).count == 3)
        // without the yes, nothing it adopted goes
        let again = scratch("save-no")
        _ = try legacyFolder(in: again, versions: 4)
        let bare = job([again])
        let f2 = try LibraryFolders.prepare(job: bare, library: papers, in: again, jobs: [bare], isOpen: { _ in false }).folder
        try version(in: f2, now)
        JobExecutor.pruneVersions(folders: [(papers, f2)], policy: bare.retention,
                                  confirmed: { _, v in bare.confirmsAdoption(of: v, target: bare.targets[0].id, library: papers.id) })
        #expect(LibraryFolders.versionNames(in: f2).count == 5)
    }

    // Saving an edit keeps every yes already given that still holds. A yes lets go
    // only what it was told goes; a new one for the same folder replaces it; one
    // given under another Keep rule no longer holds.
    @Test func saveKeepsTheYesesThatStillHold() {
        let dest = URL(fileURLWithPath: "/Volumes/T7/Backups")
        let base = job([dest])
        var stored = base
        stored.adoptionConsents = [AdoptionConsent(targetID: dest.path, libraryID: "papers", versions: ["a", "b"], allows: ["a"],
                                                   rule: base.retention, confirmedAt: start)]
        var renamed = base; renamed.name = "Papers 2"
        let merged = JobEdit.merge(draft: renamed, base: base, stored: stored)
        #expect(merged?.adoptionConsents == stored.adoptionConsents)
        #expect(merged?.confirmsAdoption(of: "a", target: dest.path, library: "papers") == true)
        #expect(merged?.confirmsAdoption(of: "b", target: dest.path, library: "papers") == false, "a yes deletes only what it said")
        #expect(merged?.hasShownAdoption(of: "b", target: dest.path, library: "papers") == true)
        #expect(merged?.confirmsAdoption(of: "a", target: "other", library: "papers") == false)

        // a new yes for the same folder replaces the old; one for another is added
        let more = merged?.adding([AdoptionConsent(targetID: dest.path, libraryID: "papers", versions: ["b", "c"], allows: ["b"],
                                                   rule: base.retention, confirmedAt: start),
                                   AdoptionConsent(targetID: "other", libraryID: "papers", versions: ["x"], allows: ["x"],
                                                   rule: base.retention, confirmedAt: start)])
        #expect(more?.confirmsAdoption(of: "b", target: dest.path, library: "papers") == true)
        #expect(more?.confirmsAdoption(of: "a", target: dest.path, library: "papers") == false)
        #expect(more?.confirmsAdoption(of: "x", target: "other", library: "papers") == true)

        // another Keep rule: the yes given under the old one no longer holds
        var lowered = base; lowered.retention = .keepLast(1)
        let changed = JobEdit.merge(draft: lowered, base: base, stored: stored)
        #expect(changed?.adoptionConsents == nil)
        #expect(changed?.confirmsAdoption(of: "a", target: dest.path, library: "papers") == false)
        #expect(changed?.adding(stored.adoptionConsents ?? []).adoptionConsents == nil)
        var kept = stored; kept.retention = .keepLast(1)
        #expect(!kept.confirmsAdoption(of: "a", target: dest.path, library: "papers"), "a yes under keepLast(2) was used under keepLast(1)")
    }

    // The next backup is placed where the schedule puts it, not at the moment of
    // counting: one that runs only when asked, is paused, or is overdue runs now.
    @Test func theNextBackupIsWhenItsScheduled() {
        var daily = job([URL(fileURLWithPath: "/Volumes/T7/Backups")])
        daily.frequency = .everyHours(24)
        let ran = start.addingTimeInterval(10 * day)
        #expect(daily.nextBackup(lastRun: ran, now: ran) == ran.addingTimeInterval(day))
        #expect(daily.nextBackup(lastRun: ran, now: ran.addingTimeInterval(2 * day)) == ran.addingTimeInterval(2 * day))
        #expect(daily.nextBackup(lastRun: nil, now: start) == start.addingTimeInterval(day))
        var paused = daily; paused.enabled = false
        #expect(paused.nextBackup(lastRun: ran, now: ran) == ran)
        #expect(job([URL(fileURLWithPath: "/Volumes/T7/Backups")]).nextBackup(lastRun: ran, now: ran) == ran)     // manual
    }

    // A daily job's card under a GFS rule, counted right after a run, says what the
    // next day's backup deletes: no fewer (the person isn't asked again for nothing)
    // and no more.
    @Test func aGFSCardCountsTheNextScheduledBackup() throws {
        let base = scratch("gfs-card")
        let dest = base.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let legacy = dest.appendingPathComponent("Papers", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        for d in [7.0, 8, 9] { try version(in: legacy, start.addingTimeInterval(d * day)) }
        var daily = job([dest], retention: .gfs(daily: 3, weekly: 0, monthly: 0))
        daily.frequency = .everyHours(24)
        let store = JobStore(url: base.appendingPathComponent("jobs.json"))
        store.upsert(daily)
        let t = daily.targets[0]
        let ran = start.addingTimeInterval(10 * day)
        let folder = try LibraryFolders.prepare(job: daily, library: papers, in: dest, jobs: [daily], isOpen: { _ in false }).folder
        try version(in: folder, ran)
        let made = JobExecutor.adoptionReviews(daily, [t.id: [papers.id: folder]], checks: [], transferring: { _ in false },
                                               confirmed: { _, _ in false }, now: ran)
        store.recordAdoptionReviews(jobID: daily.id, made, reached: [t.id])
        let card = try #require(store.load().adoptionReviews[daily.id]?.first)
        #expect(card.deletes == 2, "counted as if the next backup shared the day of the one just made")
        #expect(store.confirm(card, at: ran))

        let now = try #require(store.load().jobs.first)
        let before = LibraryFolders.versionNames(in: folder)
        try version(in: folder, ran.addingTimeInterval(day))
        JobExecutor.pruneVersions(folders: [(papers, folder)], policy: now.retention,
                                  confirmed: { _, v in now.confirmsAdoption(of: v, target: t.id, library: papers.id) },
                                  shown: { _, v in now.hasShownAdoption(of: v, target: t.id, library: papers.id) })
        let gone = before.subtracting(LibraryFolders.versionNames(in: folder))
        #expect(gone == Set(card.allows), "said \(card.allows.sorted()), deleted \(gone.sorted())")
    }

    // A card counted under one Keep rule can't be said yes to under another, nor once
    // a run has counted again: nothing is recorded, and the card stays to be counted again.
    @Test func aCardThatNoLongerHoldsIsRefused() throws {
        let base = scratch("refused")
        let dest = base.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        _ = try legacyFolder(in: dest, versions: 3)
        let store = JobStore(url: base.appendingPathComponent("jobs.json"))
        let saved = job([dest], retention: .keepLast(5))
        store.upsert(saved)
        let t = saved.targets[0]
        let folder = try LibraryFolders.prepare(job: saved, library: papers, in: dest, jobs: [saved], isOpen: { _ in false }).folder
        let ran = start.addingTimeInterval(10 * day)
        try version(in: folder, ran)
        let made = JobExecutor.adoptionReviews(saved, [t.id: [papers.id: folder]], checks: [], transferring: { _ in false },
                                               confirmed: { _, _ in false }, now: ran)
        store.recordAdoptionReviews(jobID: saved.id, made, reached: [t.id])
        let card = try #require(store.load().adoptionReviews[saved.id]?.first)
        #expect(card.deletes == 0)

        // a run counted again: one more of its own, so one of them goes now
        try version(in: folder, ran.addingTimeInterval(day))
        let again = JobExecutor.adoptionReviews(saved, [t.id: [papers.id: folder]], checks: [], transferring: { _ in false },
                                                confirmed: { _, _ in false }, now: ran.addingTimeInterval(day))
        store.recordAdoptionReviews(jobID: saved.id, again, reached: [t.id])
        #expect(!store.confirm(card), "a yes to an older count was taken")

        // the Keep rule changed since
        let fresh = try #require(store.load().adoptionReviews[saved.id]?.first)
        store.update { s in s.jobs[0].retention = .keepLast(1) }
        #expect(!store.confirm(fresh), "a yes to a count under another Keep rule was taken")
        #expect(store.load().jobs.first?.adoptionConsents == nil)
        #expect(store.load().adoptionReviews[saved.id]?.isEmpty == false)
    }

    // Keeping the last so many, the order adopted versions leave in is known, so one
    // yes names every one the rule pushes out as backups arrive. Keeping so many a
    // day, week and month, which go depends on when the backups are made: the yes
    // names only what the next backup deletes, and each later one is asked about.
    @Test func aKeepLastYesNamesWhatLaterBackupsPushOutAndAGFSYesDoesNot() throws {
        let dest = scratch("later")
        let legacy = try legacyFolder(in: dest, versions: 6)
        let lib = papers
        let next = start.addingTimeInterval(10 * day)
        func question(_ rule: RetentionPolicy) throws -> AdoptionQuestion {
            let j = job([dest], retention: rule)
            let (shelf, _) = JobExecutor.nextShelf(job: j, library: lib, in: dest, jobs: [j])
            return try #require(JobExecutor.adoptionQuestion(shelf, policy: rule, upcoming: next, shown: { _ in false }, confirmed: { _ in false }))
        }
        let all = LibraryFolders.versionNames(in: legacy)
        let last = try question(.keepLast(4))
        #expect(last.deletes.count == 3 && last.later.count == 3, "\(last)")
        #expect(Set(last.allows) == all)
        let gfs = try question(.gfs(daily: 3, weekly: 0, monthly: 0))
        #expect(gfs.later.isEmpty && Set(gfs.allows) == Set(gfs.deletes))
        #expect(!gfs.deletes.isEmpty && gfs.deletes.count < all.count)
        // a card says both parts
        let review = AdoptionReview(jobID: "job-1", targetID: dest.path, libraryID: lib.id, destination: "dest", library: "Papers",
                                    question: last, rule: .keepLast(4), foundAt: next)
        #expect(review.later == 3)
        #expect(review.effect == "Keep last 4 then applies to them: 3 are deleted at the next backup; 3 more are deleted one at a time as new backups are made.")
    }

    // A Keep rule raised while a run goes on is the one that run prunes by: the
    // version the old rule would have deleted stays.
    @Test func keepRaisedDuringARunIsWhatThatRunPrunesBy() async throws {
        let base = scratch("raise")
        let (mnt, src) = try sourceVolume(in: base)
        defer { MountPoint.detach(mnt, runner: ProcessCommandRunner()) }
        let dest = base.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let lib = ContentType.genericFolder(id: "papers", displayName: "Papers", path: .absolute(src.path))
        let store = JobStore(url: base.appendingPathComponent("jobs.json"))
        store.upsert(job([dest], library: lib, retention: .keepLast(1)))
        let exec = JobExecutor(helper: FakePrivilegedHelper(), detector: FakeProcessDetector(),
                               scratchBase: base.appendingPathComponent("scratch"), jobStore: store, volumes: FixedVolumeTable([]))
        let first = try await exec.run(try #require(store.load().jobs.first), ownerUID: getuid(), now: start.addingTimeInterval(10 * day))
        guard case .finished = first else { Issue.record("\(first)"); return }
        let second = try await exec.run(try #require(store.load().jobs.first), ownerUID: getuid(), now: start.addingTimeInterval(11 * day),
                                        onStage: { stage in
                                            if stage == .archiving { store.update { s in s.jobs[0].retention = .keepLast(5) } }
                                        })
        guard case .finished = second else { Issue.record("\(second)"); return }
        let stored = try #require(store.load().jobs.first)
        let folder = try #require(LibraryFolders.folders(job: stored, library: lib, in: dest).first)
        #expect(LibraryFolders.versionNames(in: folder).count == 2, "pruned by the Keep rule the run began with")
    }

    // Once retention is told to stop, nothing more is deleted.
    @Test func pruningStopsWhenToldTo() throws {
        let dest = scratch("stop")
        let folder = dest.appendingPathComponent("Papers")
        for d in 0..<4 { try version(in: folder, start.addingTimeInterval(Double(d) * day)) }
        var asked = 0
        JobExecutor.pruneVersions(folders: [(papers, folder)], policy: .keepLast(1), confirmed: { _, _ in false },
                                  proceed: { asked += 1; return asked < 2 })
        #expect(LibraryFolders.versionNames(in: folder).count == 3)
    }
}
