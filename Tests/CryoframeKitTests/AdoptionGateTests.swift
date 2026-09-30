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
        #expect(consent.versions.count == 4 && consent.deletes == 3)

        let saved = draft.adding(impact.consents)
        let t = saved.targets[0]
        let folder = try LibraryFolders.prepare(job: saved, library: papers, in: dest, jobs: [saved], isOpen: { _ in false }).folder
        try version(in: folder, now)
        let before = LibraryFolders.versionNames(in: folder).count
        JobExecutor.pruneVersions(folders: [(papers, folder)], policy: saved.retention,
                                  confirmed: { _, v in saved.confirmsAdoption(of: v, target: t.id, library: papers.id) })
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

    // Saving an edit keeps every yes already given; a new one is added.
    @Test func saveKeepsTheYesesAlreadyGiven() {
        let dest = URL(fileURLWithPath: "/Volumes/T7/Backups")
        var stored = job([dest])
        stored.adoptionConsents = [AdoptionConsent(targetID: dest.path, libraryID: "papers", versions: ["a"], deletes: 1, confirmedAt: start)]
        let base = job([dest])
        var draft = base; draft.retention = .keepLast(3)
        let merged = JobEdit.merge(draft: draft, base: base, stored: stored)
        #expect(merged?.adoptionConsents == stored.adoptionConsents)
        let more = merged?.adding([AdoptionConsent(targetID: dest.path, libraryID: "papers", versions: ["b"], deletes: 0, confirmedAt: start)])
        #expect(more?.confirmsAdoption(of: "a", target: dest.path, library: "papers") == true)
        #expect(more?.confirmsAdoption(of: "b", target: dest.path, library: "papers") == true)
        #expect(more?.confirmsAdoption(of: "b", target: "other", library: "papers") == false)
    }
}
