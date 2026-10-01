//
//  M5bConsentEdgeTests.swift
//  CryoframeKitTests
//
//  The go-ahead that names what it lets go (see AdoptedVersions.swift), over a run of
//  backups: what it asks again, what it never lets go, and a yes given while a run
//  is already going.
//

import Testing
import Foundation
@testable import CryoframeKit

private let start = Date(timeIntervalSince1970: 1_790_000_000)
private let day: TimeInterval = 86_400

private func scratch(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-consentedge-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return TempTracker.track(d) }
    defer { free(real) }
    return TempTracker.track(URL(fileURLWithPath: String(cString: real), isDirectory: true))
}

private let papers = ContentType.genericFolder(id: "papers", displayName: "Papers", path: .absolute("/Users/me/Papers"))

private func job(_ dests: [URL], library: ContentType = papers, retention: RetentionPolicy) -> BackupJob {
    BackupJob(id: "job-1", name: "Papers", libraries: [library],
              targets: dests.map { Target.localVolume(id: $0.path, name: $0.lastPathComponent, dir: $0) },
              format: .sealedZip, frequency: .manual, retention: retention, createdAt: start)
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

/// One backup of `stored` into `folder` at `date`, pruned and counted as a run does
/// (JobExecutor.run: confirmed and shown from the job as saved, then the cards).
@discardableResult
private func backUp(_ stored: BackupJob, into folder: URL, at date: Date, store: JobStore) throws -> [AdoptionReview] {
    let t = stored.targets[0]
    try version(in: folder, date)
    let confirmed: (URL, String) -> Bool = { _, v in stored.confirmsAdoption(of: v, target: t.id, library: papers.id) }
    let shown: (URL, String) -> Bool = { _, v in stored.hasShownAdoption(of: v, target: t.id, library: papers.id) }
    JobExecutor.pruneVersions(folders: [(papers, folder)], policy: stored.retention, confirmed: confirmed, shown: shown)
    let reviews = JobExecutor.adoptionReviews(stored, [t.id: [papers.id: folder]], checks: [], transferring: { _ in false },
                                              confirmed: confirmed, shown: shown, now: date)
    store.recordAdoptionReviews(jobID: stored.id, reviews, reached: [t.id])
    return reviews
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

@Suite(.serialized) struct M5bConsentEdgeTests {
    // Under keepLast the adopted versions are the oldest there, and they leave in date
    // order as new backups come in: nothing about which goes next is unknown when the
    // person says yes. Yet a yes lets go only what the next backup deletes, so each
    // backup after it ages out one more, finds it not named, and asks again: a card
    // and a run warning at every backup, keepLast - 2 times over (8 days of them for
    // keepLast(10) run daily). People told the same thing every day stop reading.
    @Test func aYesUnderKeepLastIsNotAskedForAgainAsEachVersionAgesOut() throws {
        let base = scratch("nag")
        let dest = base.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        _ = try legacyFolder(in: dest, days: [0, 1, 2, 3, 4, 5])
        let store = JobStore(url: base.appendingPathComponent("jobs.json"))
        store.upsert(job([dest], retention: .keepLast(4)))
        let first = try #require(store.load().jobs.first)
        let folder = try LibraryFolders.prepare(job: first, library: papers, in: dest, jobs: [first], isOpen: { _ in false }).folder

        var askedAgain: [String] = []
        var said = false
        for n in 0..<6 {
            let stored = try #require(store.load().jobs.first)
            let cards = try backUp(stored, into: folder, at: start.addingTimeInterval(Double(10 + n) * day), store: store)
            if let card = cards.first {
                if said { askedAgain.append("backup \(n + 1): \(card.versions.count) kept for now, \(card.deletes) deleted next") }
                #expect(store.confirm(try #require(store.load().adoptionReviews[stored.id]?.first)))
                said = true
            }
        }
        #expect(said)
        #expect(askedAgain.isEmpty, "after one yes under keepLast(4), asked again \(askedAgain.count) times: \(askedAgain)")
        #expect(LibraryFolders.versionNames(in: folder).count == 4)
    }

    // A card left unanswered blocks only the versions it asks about: the job's own
    // versions go on being pruned to the Keep rule, and the waiting ones stay.
    //
    // Under a day/week/month rule a yes covers only the next backup (which goes later
    // depends on when backups run), so the versions later backups push out are asked
    // about again. Under keepLast one yes now names every adopted version the rule
    // pushes out (3e0f793), so there is nothing left for a later card to block there;
    // this ran under keepLast(3) until then.
    @Test func anUnansweredCardBlocksOnlyTheVersionItAsksAbout() throws {
        let base = scratch("unanswered")
        let dest = base.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        _ = try legacyFolder(in: dest, days: [0, 1, 2])
        let store = JobStore(url: base.appendingPathComponent("jobs.json"))
        store.upsert(job([dest], retention: .gfs(daily: 3, weekly: 0, monthly: 0)))
        let first = try #require(store.load().jobs.first)
        let folder = try LibraryFolders.prepare(job: first, library: papers, in: dest, jobs: [first], isOpen: { _ in false }).folder
        let stamp = { (d: Double) in VersionStamp.string(start.addingTimeInterval(d * day)) }
        // the first card answered: it names day 0 alone, the one the next backup deletes
        let asked = try backUp(first, into: folder, at: start.addingTimeInterval(10 * day), store: store)
        let card = try #require(store.load().adoptionReviews[first.id]?.first)
        #expect(asked.count == 1 && card.allows == [stamp(0)] && card.later == 0, "\(card.allows) later \(card.later): \(card.effect)")
        #expect(store.confirm(card))
        // the later ones left alone
        for n in 1..<6 {
            try backUp(try #require(store.load().jobs.first), into: folder, at: start.addingTimeInterval(Double(10 + n) * day), store: store)
        }
        let left = LibraryFolders.versionNames(in: folder)
        let own = (0..<6).map { stamp(Double(10 + $0)) }
        #expect(left.isSuperset(of: own.suffix(3)), "the job's newest three were deleted: \(left.sorted())")
        #expect(left.intersection(own.prefix(3)).isEmpty, "the job's own older versions weren't pruned: \(left.sorted())")
        #expect(!left.contains(stamp(0)), "the version the yes named wasn't deleted: \(left.sorted())")
        #expect(left.isSuperset(of: [stamp(1), stamp(2)]), "a waiting version was deleted unasked: \(left.sorted())")
        let waiting = store.load().adoptionReviews[first.id]?.first
        #expect(waiting?.versions == [stamp(1), stamp(2)], "\(String(describing: waiting?.versions))")
        #expect(waiting?.deletes == 2, "the card doesn't say the Keep rule deletes them: \(waiting?.effect ?? "no card")")
    }

    // What a yes under keepLast says, backup by backup: the next backup deletes the
    // number it said, then each backup after it deletes one more of those it named,
    // oldest first, until the "more" it said are gone, and no card or warning comes
    // back. Nothing it didn't name goes.
    @Test func whatAKeepLastYesSaysIsWhatEachBackupDeletes() throws {
        let base = scratch("wording")
        let dest = base.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        _ = try legacyFolder(in: dest, days: [0, 1, 2, 3, 4, 5])
        let store = JobStore(url: base.appendingPathComponent("jobs.json"))
        store.upsert(job([dest], retention: .keepLast(4)))
        let first = try #require(store.load().jobs.first)
        let folder = try LibraryFolders.prepare(job: first, library: papers, in: dest, jobs: [first], isOpen: { _ in false }).folder
        let adopted = Set((0..<6).map { VersionStamp.string(start.addingTimeInterval(Double($0) * day)) })

        try backUp(first, into: folder, at: start.addingTimeInterval(10 * day), store: store)
        let card = try #require(store.load().adoptionReviews[first.id]?.first)
        #expect(LibraryFolders.versionNames(in: folder).isSuperset(of: adopted), "deleted before the yes")
        #expect(card.effect == "Keep last 4 then applies to them: 4 are deleted at the next backup; 2 more are deleted one at a time as new backups are made.",
                "\(card.effect)")
        #expect(Set(card.allows) == adopted)
        #expect(store.confirm(card))

        var gone: [[String]] = []
        var before = LibraryFolders.versionNames(in: folder)
        for n in 1..<6 {
            let cards = try backUp(try #require(store.load().jobs.first), into: folder, at: start.addingTimeInterval(Double(10 + n) * day), store: store)
            #expect(cards.isEmpty, "asked again at backup \(n + 1): \(cards.first?.effect ?? "")")
            let now = LibraryFolders.versionNames(in: folder)
            gone.append(before.subtracting(now).intersection(adopted).sorted())
            before = now
        }
        let said = gone.map(\.count)
        #expect(said == [4, 1, 1, 0, 0], "adopted versions deleted per backup: \(said)")
        #expect(gone.flatMap { $0 } == adopted.sorted(), "not oldest first: \(gone)")
        #expect(LibraryFolders.versionNames(in: folder).count == 4)
    }

    // Two destinations holding the same 1.5 run (1.5 stamped each version once, the
    // same name at every destination): a yes for one of them lets nothing go at the
    // other, which is still asked about.
    @Test func aYesForOneDestinationLetsNothingGoAtTheOther() throws {
        let base = scratch("two")
        let a = base.appendingPathComponent("A"), b = base.appendingPathComponent("B")
        for d in [a, b] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            _ = try legacyFolder(in: d, days: [0, 1, 2, 3])
        }
        let store = JobStore(url: base.appendingPathComponent("jobs.json"))
        let saved = job([a, b], retention: .keepLast(1))
        store.upsert(saved)
        let (ta, tb) = (saved.targets[0], saved.targets[1])
        let fa = try LibraryFolders.prepare(job: saved, library: papers, in: a, jobs: [saved], isOpen: { _ in false }).folder
        let fb = try LibraryFolders.prepare(job: saved, library: papers, in: b, jobs: [saved], isOpen: { _ in false }).folder
        let now = start.addingTimeInterval(10 * day)
        for f in [fa, fb] { try version(in: f, now) }
        let cards = JobExecutor.adoptionReviews(saved, [ta.id: [papers.id: fa], tb.id: [papers.id: fb]], checks: [],
                                                transferring: { _ in false }, confirmed: { _, _ in false }, now: now)
        store.recordAdoptionReviews(jobID: saved.id, cards, reached: [ta.id, tb.id])
        #expect(cards.count == 2)
        let cardA = try #require(store.load().adoptionReviews[saved.id]?.first { $0.targetID == ta.id })
        #expect(store.confirm(cardA))
        #expect(store.load().adoptionReviews[saved.id]?.map(\.targetID) == [tb.id], "B's card went with A's yes")

        let stored = try #require(store.load().jobs.first)
        let beforeB = LibraryFolders.versionNames(in: fb)
        let later = start.addingTimeInterval(11 * day)
        for (t, f) in [(ta, fa), (tb, fb)] {
            try version(in: f, later)
            JobExecutor.pruneVersions(folders: [(papers, f)], policy: stored.retention,
                                      confirmed: { _, v in stored.confirmsAdoption(of: v, target: t.id, library: papers.id) },
                                      shown: { _, v in stored.hasShownAdoption(of: v, target: t.id, library: papers.id) })
        }
        #expect(LibraryFolders.versionNames(in: fa) == [VersionStamp.string(later)])
        #expect(LibraryFolders.versionNames(in: fb).isSuperset(of: beforeB.subtracting([VersionStamp.string(now)])),
                "A's yes deleted adopted versions at B")
    }

    // A yes given on the dashboard while a run is already going: the run counts with
    // the job as it was when it started (no yes), and at its end records that count
    // as the card again, so the card just answered comes back, and the run's warning
    // says the versions are kept for now. Nothing is deleted that shouldn't be; the
    // person is asked again for what they already said yes to.
    @Test func aYesGivenDuringARunIsNotAskedForAgainByThatRun() async throws {
        let base = scratch("midrun")
        let (mnt, src) = try sourceVolume(in: base)
        defer { MountPoint.detach(mnt, runner: ProcessCommandRunner()) }
        let dest = base.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        _ = try legacyFolder(in: dest, days: [0, 1, 2])
        let lib = ContentType.genericFolder(id: "papers", displayName: "Papers", path: .absolute(src.path))
        let store = JobStore(url: base.appendingPathComponent("jobs.json"))
        store.upsert(job([dest], library: lib, retention: .keepLast(1)))
        let exec = JobExecutor(helper: FakePrivilegedHelper(), detector: FakeProcessDetector(),
                               scratchBase: base.appendingPathComponent("scratch"), jobStore: store, volumes: FixedVolumeTable([]))

        let first = try await exec.run(try #require(store.load().jobs.first), ownerUID: getuid(), now: start.addingTimeInterval(10 * day))
        guard case .finished = first else { Issue.record("\(first)"); return }
        let card = try #require(store.load().adoptionReviews["job-1"]?.first)

        // the next run starts; while it backs up, the person says yes to the card
        let yes = Confirmed()
        let second = try await exec.run(try #require(store.load().jobs.first), ownerUID: getuid(), now: start.addingTimeInterval(11 * day),
                                        onStage: { stage in if stage == .archiving { yes.set(store.confirm(card)) } })
        guard case .finished(_, let warning) = second else { Issue.record("\(second)"); return }
        try #require(yes.value == true, "the yes wasn't taken")
        #expect(store.load().adoptionReviews["job-1"] == nil,
                "the card answered during the run is back: \(store.load().adoptionReviews["job-1"]?.first?.effect ?? "")")
        #expect(warning?.contains("kept for now") != true, "the run's warning asks again: \(warning ?? "")")
    }
}

/// what a yes given from a run's stage callback returned
private final class Confirmed: @unchecked Sendable {
    private let lock = NSLock()
    private var v: Bool?
    func set(_ b: Bool) { lock.lock(); v = b; lock.unlock() }
    var value: Bool? { lock.lock(); defer { lock.unlock() }; return v }
}
