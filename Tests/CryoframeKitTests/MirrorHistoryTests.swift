//
//  MirrorHistoryTests.swift
//  CryoframeKitTests
//
//  A live mirror keeps earlier copies of itself as APFS clones (see MirrorHistory):
//  what goes when, where it can be kept, and, on a small APFS drive made for the
//  test, the whole round: runs that save history, a restore of an earlier copy,
//  history removed to make room for the mirror, and an entry a crash left half made.
//  Also that 1.7's ways of reading a destination pass the new folder by.
//

import Testing
import Foundation
@testable import CryoframeKit

private func tempDir(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-mh-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private let day: TimeInterval = 86_400
private let start = Date(timeIntervalSince1970: 1_789_948_800)      // 2026-09-21 00:00 UTC

private func fakeEntry(_ dir: URL, _ date: Date, written: UInt64?) throws -> MirrorHistory.Entry {
    let e = MirrorHistory.folder(in: dir).appendingPathComponent(VersionStamp.string(date), isDirectory: true)
    try FileManager.default.createDirectory(at: e.appendingPathComponent("Lib.sparsebundle"), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: e.appendingPathComponent(ArchiveManifest.sidecarName))
    if let written { try MirrorHistory.record(written: written, in: e) }
    return MirrorHistory.Entry(dir: e, date: date, written: written)
}

/// a small APFS drive in the temporary folder, attached the way external drives are
private func scratchDrive(_ size: String, in dir: URL) throws -> URL {
    let made = try TestDiskImages.run(["create", "-size", size, "-fs", "APFS", "-volname", "HistoryDrive",
                                       "-type", "SPARSE", dir.appendingPathComponent("drive").path])
    try #require(made.ok, "\(made.stderr)")
    let mnt = dir.appendingPathComponent("mnt")
    try FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)
    let r = try DiskImageGate.serialized {
        try TestDiskImages.run(["attach", dir.appendingPathComponent("drive.sparseimage").path, "-mountpoint", mnt.path, "-nobrowse"])
    }
    try #require(r.ok, "\(r.stderr)")
    return mnt
}

/// `entry` as if made `days` days ago: a night keeps only its last entry, and a test
/// can't wait for the next one
private func backdate(_ entry: MirrorHistory.Entry, days: Double) throws -> MirrorHistory.Entry {
    let date = entry.date.addingTimeInterval(-days * day)
    let moved = entry.dir.deletingLastPathComponent().appendingPathComponent(VersionStamp.string(date), isDirectory: true)
    try FileManager.default.moveItem(at: entry.dir, to: moved)
    return MirrorHistory.Entry(dir: moved, date: VersionStamp.date(moved.lastPathComponent)!, written: entry.written)
}

/// `bytes` of a byte that isn't zero, which the mirror would store as a hole
private func fill(_ url: URL, mb: Int, byte: UInt8) throws {
    try Data(repeating: byte, count: mb << 20).write(to: url)
}

@Suite struct MirrorHistoryTests {

    // MARK: what goes

    // The newest entry of each of the last N days a run made one; several runs a day
    // keep only that day's last. The newest entry is never removed.
    @Test func historyKeepsTheLastEntryOfEachNight() {
        var dates: [Date] = []
        for d in 0..<10 { for h in [2.0, 14.0] { dates.append(start.addingTimeInterval(Double(d) * day + h * 3600)) } }
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let going = MirrorHistory.doomed(dates, nights: 7, calendar: utc)
        let kept = Set(dates).subtracting(going)
        #expect(kept.count == 7)
        #expect(kept == Set((3..<10).map { start.addingTimeInterval(Double($0) * day + 14 * 3600) }))
        #expect(MirrorHistory.doomed(dates, nights: 30, calendar: utc).count == 10, "each night's earlier run")
        #expect(MirrorHistory.doomed(dates, nights: 0, calendar: utc).isEmpty, "off removes nothing")
        #expect(MirrorHistory.doomed([start], nights: 7).isEmpty)
    }

    // Room is made oldest first, one entry at a time, and only as far as needed.
    @Test func roomIsMadeOldestFirstAndNoFurtherThanNeeded() {
        let dir = URL(fileURLWithPath: "/nowhere")
        let entries = (0..<5).map { MirrorHistory.Entry(dir: dir.appendingPathComponent("\($0)"), date: start.addingTimeInterval(Double($0) * day), written: 100) }
        var freed = 0
        var removed: [Int] = []
        let gone = MirrorHistory.makeRoom(entries.shuffled(), fits: { freed >= 250 }, remove: { e in
            removed.append(Int(e.dir.lastPathComponent)!); freed += 100; return true
        })
        #expect(removed == [0, 1, 2] && gone.map(\.date) == entries.prefix(3).map(\.date))
        // already fits: nothing goes
        #expect(MirrorHistory.makeRoom(entries, fits: { true }, remove: { _ in Issue.record("removed"); return true }).isEmpty)
        // one that won't go ends it: the next is newer and frees no more
        var tried = 0
        let stuck = MirrorHistory.makeRoom(entries, fits: { false }, remove: { _ in tried += 1; return tried > 1 })
        #expect(stuck.isEmpty && tried == 1)
        // out of history, the mirror is still refused
        #expect(MirrorHistory.makeRoom(entries, fits: { false }, remove: { _ in true }).count == 5)
        #expect(MirrorHistory.roomNote(Array(entries.prefix(2)))?.contains("to make room for the mirror itself") == true)
        #expect(MirrorHistory.roomNote([]) == nil)
    }

    // What history takes is about what the runs after its oldest entry wrote; an entry
    // removed hands what its run wrote to the next newer one.
    @Test func aboutSizesFollowWhatRunsWroteAndSurviveARemoval() throws {
        let dir = tempDir("about")
        defer { try? FileManager.default.removeItem(at: dir) }
        let e1 = try fakeEntry(dir, start, written: 1000)
        let e2 = try fakeEntry(dir, start.addingTimeInterval(day), written: 30)
        let e3 = try fakeEntry(dir, start.addingTimeInterval(2 * day), written: 70)
        // a part-made entry and a stray folder aren't entries
        try FileManager.default.createDirectory(at: MirrorHistory.folder(in: dir).appendingPathComponent(VersionStamp.string(start.addingTimeInterval(3 * day)) + ".partial"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: MirrorHistory.folder(in: dir).appendingPathComponent("notes"), withIntermediateDirectories: true)
        let all = MirrorHistory.entries(in: dir)
        #expect(all.map(\.date) == [e3.date, e2.date, e1.date])
        #expect(MirrorHistory.aboutBytes(of: e1, among: all) == 30)
        #expect(MirrorHistory.aboutBytes(of: e2, among: all) == 70)
        #expect(MirrorHistory.aboutBytes(of: e3, among: all) == 0, "the newest shares everything with the mirror")
        #expect(MirrorHistory.aboutBytes(all) == 100)
        try MirrorHistory.remove(e2, in: dir)
        let left = MirrorHistory.entries(in: dir)
        #expect(left.map(\.date) == [e3.date, e1.date])
        #expect(MirrorHistory.aboutBytes(of: e1, among: left) == 100, "e1 now holds what e2's run wrote, too")
        MirrorHistory.sweepPartials(in: dir)
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: MirrorHistory.folder(in: dir).path)).contains { $0.hasSuffix(".partial") })
    }

    // MARK: where it can be kept

    @Test func historyIsKeptOnlyWhereADriveCanCloneIt() {
        func gate(_ fs: String, _ kind: TargetKind = .local, clones: Bool = true) -> MirrorHistory.Unavailable? {
            MirrorHistory.unavailable(FileSystemProfile.make(fsType: fs, target: kind), clones: clones)
        }
        #expect(gate("apfs") == nil)
        #expect(gate("apfs", clones: false) == .noClones(described: "an APFS drive"))
        #expect(gate("exfat") == .noClones(described: "an exFAT drive"))
        #expect(gate("msdos") == .noClones(described: "a FAT32 drive"))
        #expect(gate("hfs") == .noClones(described: "a Mac OS Extended drive"))
        #expect(gate("smbfs") == .network)
        #expect(gate("apfs", .networkShare) == .network)
        #expect(gate("apfs", .cloudSync) == .cloud, "a cloud folder on APFS still uploads each copy whole")
        // this Mac's temporary folder is on its APFS startup disk
        #expect(MirrorHistory.clones(FileManager.default.temporaryDirectory.appendingPathComponent("not-made-yet")))
    }

    // The editor offers history for one up-to-date copy kept as a disk image, and says
    // why each destination that can't keep it can't.
    @Test func theEditorSaysWhereHistoryIsNotKept() {
        let a = Target.localVolume(id: "a", name: "T7", dir: URL(fileURLWithPath: "/Volumes/T7/Backups"))
        let b = Target.localVolume(id: "b", name: "SD Card", dir: URL(fileURLWithPath: "/Volumes/SD/Backups"))
        var draft = JobDraftState(libraries: [], targets: [a, b])
        draft.selectedTargetIDs = ["a", "b"]
        let sd: (Target) -> MirrorHistory.Unavailable? = { $0.id == "b" ? .noClones(described: "an exFAT drive") : nil }
        let some = draft.historyIssues(unavailable: sd)
        #expect(some.issues == ["No history on SD Card: it is an exFAT drive, and only an APFS drive can share unchanged data between copies."])
        #expect(!some.allUnavailable)
        #expect(draft.historyIssues(unavailable: { _ in .cloud }).allUnavailable)
        draft.formatKind = "plain"
        #expect(draft.historyIssues(unavailable: { _ in .cloud }).issues.isEmpty, "plain files have no history setting")
        draft.formatKind = "zip"
        #expect(draft.historyIssues(unavailable: { _ in .network }).issues.isEmpty)

        // the setting: the default isn't written; off and other choices are
        draft.formatKind = "mirror"
        #expect(draft.makeJob().mirrorHistoryNights == nil && draft.makeJob().historyNights == 7)
        draft.historyNights = 0
        #expect(draft.makeJob().mirrorHistoryNights == 0 && draft.makeJob().historyNights == 0)
        draft.historyNights = 30
        let job = draft.makeJob()
        #expect(job.mirrorHistoryNights == 30)
        #expect(JobDraftState(editing: job, libraries: [], targets: [a, b]).historyNights == 30)
        draft.formatKind = "dmg"
        #expect(draft.makeJob().mirrorHistoryNights == nil, "only a disk-image copy keeps history")
    }

    // MARK: the job's setting

    // Saved and read back; a job 1.7 wrote has no setting, and keeps the default.
    @Test func theSettingRoundTripsThroughTheJobStore() throws {
        let dir = tempDir("store")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("jobs.json")
        let store = JobStore(url: url)
        let t = Target.localVolume(id: "t", name: "T7", dir: URL(fileURLWithPath: "/Volumes/T7/Backups"))
        var off = BackupJob(id: "off", name: "Off", libraries: [], target: t, format: .liveMirror(sizeGB: 500),
                            frequency: .manual, createdAt: start)
        off.mirrorHistoryNights = 0
        var long = BackupJob(id: "long", name: "Long", libraries: [], target: t, format: .liveMirror(sizeGB: 500), frequency: .manual, createdAt: start)
        long.mirrorHistoryNights = 14
        let plain = BackupJob(id: "plain", name: "Default", libraries: [], target: t, format: .liveMirror(sizeGB: 500),
                              frequency: .manual, createdAt: start)
        for j in [off, long, plain] { store.upsert(j) }
        let back = JobStore(url: url).load().jobs
        #expect(back.first { $0.id == "off" } == off && back.first { $0.id == "off" }?.historyNights == 0)
        #expect(back.first { $0.id == "long" } == long && back.first { $0.id == "long" }?.historyNights == 14)
        #expect(back.first { $0.id == "plain" }?.mirrorHistoryNights == nil && back.first { $0.id == "plain" }?.historyNights == 7)
        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(raw.contains("mirrorHistoryNights"))

        // as 1.7 writes it: no such key
        let encoded = try JSONEncoder().encode(plain)
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["mirrorHistoryNights"] == nil, "the default isn't written")
        object["mirrorHistoryNights"] = "fourteen"                       // and one that can't be read is the default
        let odd = try JSONDecoder().decode(BackupJob.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(odd.historyNights == MirrorHistory.defaultNights)
    }

    // MARK: 1.7

    // 1.7 lists a destination with RestoreDiscovery.scan and LibraryFolders.archives,
    // sweeps only dated version folders (JobExecutor.prunePlan), deletes a job by its
    // library folders (JobRemoval.plan), and measures a mirror's folder whole
    // (StorageReporter). None of those is changed for history (git diff v1.7.0 shows
    // only additions behind new arguments): run here as 1.7 runs them, over a mirror
    // folder with history.
    @Test func whatOneSevenDoesWithAFolderOfHistory() throws {
        let dest = tempDir("compat")
        defer { try? FileManager.default.removeItem(at: dest) }
        let lib = ContentType.genericFolder(id: "papers", displayName: "Papers", path: .absolute("/Users/someone/Papers"))
        let job = BackupJob(id: "job-1", name: "Papers", libraries: [lib],
                            target: .localVolume(id: "t", name: "T7", dir: dest), format: .liveMirror(sizeGB: 500),
                            frequency: .manual, createdAt: start)
        let folder = dest.appendingPathComponent("Papers", isDirectory: true)
        func p(_ urls: [URL]?) -> [String] { (urls ?? []).map { $0.resolvingSymlinksInPath().path } }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try LibraryIdentity(job: job, library: lib).write(in: folder)
        let bundle = folder.appendingPathComponent("Papers.sparsebundle")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("bands"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: bundle.appendingPathComponent("bands/0"))
        _ = try ArchiveManifest.write(try ArchiveManifest.build(for: ArchiveResult(artifacts: [bundle], format: .liveMirror)), toDir: folder)
        // two entries, each a manifest and an image like the mirror's
        for d in [start, start.addingTimeInterval(day)] {
            let e = MirrorHistory.folder(in: folder).appendingPathComponent(VersionStamp.string(d), isDirectory: true)
            try FileManager.default.createDirectory(at: e, withIntermediateDirectories: true)
            try MirrorHistory.clone(bundle, to: e.appendingPathComponent("Papers.sparsebundle"))
            try FileManager.default.copyItem(at: folder.appendingPathComponent(ArchiveManifest.sidecarName),
                                             to: e.appendingPathComponent(ArchiveManifest.sidecarName))
        }
        #expect(MirrorHistory.entries(in: folder).count == 2)

        // listing: the mirror alone, from the destination and from the folder
        for (root, depth) in [(dest, 2), (dest, 1), (folder, 1), (folder, 2)] {
            let found = RestoreDiscovery.scan(root, maxDepth: depth)
            #expect(p(found.map(\.dir)) == p([folder]), "\(root.lastPathComponent) at depth \(depth): \(found.map(\.dir.path))")
        }
        #expect(p(LibraryFolders.archives(job: job, library: lib, in: dest).map(\.dir)) == p([folder]))
        #expect(p(LibraryFolders.archives(job: job, library: lib, in: dest, downloading: false).map(\.dir)) == p([folder]))
        // the sweep: no husk, no version, in the mirror's folder
        let plan = JobExecutor.prunePlan(folders: [(lib, folder)], policy: .keepLast(1), confirmed: { _, _ in true })
        #expect(plan.husks.isEmpty && plan.versions.isEmpty)
        // deleting the job takes the library's folder, history and all
        let removal = JobRemoval.plan(for: job, pending: PendingTransferStore(url: dest.appendingPathComponent("pending.json")),
                                      scratchBase: dest.appendingPathComponent("scratch"))
        #expect(p(removal.places.first?.folders) == p([folder]))
        // 1.7 measures the folder whole: the clones count at the size they read as
        let whole = JobExecutor.directorySize(folder)
        let alone = JobExecutor.directorySize(folder, skipping: MirrorHistory.folderName)
        #expect(whole >= 3 * 4096 && alone < whole)
        // 1.8 measures the mirror alone, and its history by what runs wrote
        let row = try #require(StorageReporter.report([job]).first)
        #expect(row.archives.first { $0.history == nil }?.bytes == alone)
        #expect(row.archives.first { $0.history != nil }?.history?.count == 2)
        #expect(row.versionCount == 0)
        #expect(row.contentsSummary == "a current copy and 2 earlier copies")
        // and Restore, asked for it, lists the history after the mirror
        let restorable = RestoreDiscovery.scan(dest, history: true)
        #expect(restorable.map(\.mirrorHistory) == [false, true, true])
        #expect(restorable.dropFirst().map(\.version) == [start.addingTimeInterval(day), start])
        #expect(restorable.allSatisfy { $0.libraryName == "Papers" && p([$0.libraryFolder]) == p([folder]) })
    }

    // MARK: on an APFS drive

    // Run, change, run: two entries. The older restores what the library was then. A
    // run that wouldn't fit removes the oldest entry, which frees what only it held,
    // and says so. An entry a crash left half made is never listed, and the next run
    // sweeps it; a run with history off saves none and removes none.
    @Test func historyOnASmallAPFSDrive() throws {
        let scratch = tempDir("drive"), base = tempDir("base"), out = tempDir("restored")
        let drive = try scratchDrive("450m", in: scratch)
        let src = tempDir("lib").appendingPathComponent("Lib")
        defer {
            MountPoint.detach(drive, runner: ProcessCommandRunner())
            for d in [scratch, base, out, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) }
        }
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("first".utf8).write(to: src.appendingPathComponent("note.txt"))
        try fill(src.appendingPathComponent("big.bin"), mb: 80, byte: 0xA5)
        let dir = drive.appendingPathComponent("Lib")
        func run(history: Int? = 7) throws -> ArchiveResult {
            try SparseBundleMirrorEngine(mountBase: base, bandCheck: BandCheck.Settings(interval: day), history: history)
                .archive(ArchiveSource(name: "Lib", root: src, sizeHint: JobExecutor.directorySize(src)), to: dir)
        }

        let first = try run()
        #expect(first.notes.isEmpty, "\(first.notes)")
        let e1 = try backdate(try #require(MirrorHistory.entries(in: dir).first), days: 2)
        for name in ["Lib.sparsebundle", ArchiveManifest.sidecarName, BandTable.fileName, MirrorHistory.infoName] {
            #expect(FileManager.default.fileExists(atPath: e1.dir.appendingPathComponent(name).path), "\(name) not in the entry")
        }
        #expect((e1.written ?? 0) >= 80 << 20)

        // the library changes: the note, and the big file written over whole
        try Data("second".utf8).write(to: src.appendingPathComponent("note.txt"))
        try fill(src.appendingPathComponent("big.bin"), mb: 80, byte: 0x5A)
        let second = try run()
        #expect(second.notes.isEmpty, "\(second.notes)")
        _ = try backdate(try #require(MirrorHistory.entries(in: dir).first), days: 1)
        let two = MirrorHistory.entries(in: dir)
        #expect(two.count == 2 && two.last?.date == e1.date, "\(two.map(\.dir.lastPathComponent))")
        #expect(MirrorHistory.aboutBytes(two) >= 80 << 20, "the older entry holds the big file as it was")

        // the older entry restores the library as it was then, checksum and all
        let older = try #require(RestoreDiscovery.scan(drive, history: true).first { $0.mirrorHistory && $0.version == e1.date })
        #expect(try ChecksumVerifier().reverify(archiveDir: older.dir).passed)
        let got = try RestoreEngine().restore(older, to: out)
        #expect(try String(contentsOf: got.appendingPathComponent("note.txt"), encoding: .utf8) == "first")
        let head = try FileHandle(forReadingFrom: got.appendingPathComponent("big.bin"))
        #expect(try head.read(upToCount: 1) == Data([0xA5]))
        try head.close()
        // and the mirror itself is the library as it is now
        let now = try #require(RestoreDiscovery.scan(drive, history: true).first { !$0.mirrorHistory })
        let current = try RestoreEngine().restore(now, to: out.appendingPathComponent("now"))
        #expect(try String(contentsOf: current.appendingPathComponent("note.txt"), encoding: .utf8) == "second")

        // A file the drive has room for only once the oldest entry is gone. Sized by the
        // room check itself, from what the drive has now.
        let bundle = dir.appendingPathComponent("Lib.sparsebundle")
        let capacity = try #require(StorageReporter.volume(of: drive).total)
        let reserve = MirrorSizing.reserve(capacity: capacity)
        let freeBefore = try #require(JobExecutor.freeNow(for: drive))
        let held = Checksum.byteSize(of: bundle)
        let library = JobExecutor.directorySize(src)
        func refused(_ extraMB: Int, free: UInt64) -> Bool {
            SparseBundleMirrorEngine.roomVerdict(needs: library + UInt64(extraMB) << 20, held: held, imageBytes: .max,
                                                 freeNow: free, freeEventually: free, reserve: reserve) != nil
        }
        let extra = try #require((8...400).first { refused($0, free: freeBefore) }) + 4
        #expect(!refused(extra, free: freeBefore + (60 << 20)), "the drive is too small for this test: \(freeBefore >> 20) MB free")
        try fill(src.appendingPathComponent("more.bin"), mb: extra, byte: 0x3C)
        let third = try run()
        #expect(third.notes.contains { $0.contains("removed the mirror's history from") }, "\(third.notes)")
        let after = MirrorHistory.entries(in: dir)
        #expect(!after.contains { $0.date == e1.date }, "the oldest entry is still there")
        #expect(after.count == 2, "\(after.map(\.dir.lastPathComponent))")
        let freeAfter = try #require(JobExecutor.freeNow(for: drive))
        #expect(freeAfter + (UInt64(extra) << 20) > freeBefore + (50 << 20),
                "removing the entry freed too little: \(freeBefore >> 20) MB free before, \(freeAfter >> 20) MB after writing \(extra) MB")

        // a crash between the clone and the rename
        let partial = MirrorHistory.folder(in: dir).appendingPathComponent(VersionStamp.string(Date()) + MirrorHistory.partialSuffix, isDirectory: true)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try MirrorHistory.clone(bundle, to: partial.appendingPathComponent("Lib.sparsebundle"))
        try FileManager.default.copyItem(at: dir.appendingPathComponent(ArchiveManifest.sidecarName),
                                         to: partial.appendingPathComponent(ArchiveManifest.sidecarName))
        #expect(MirrorHistory.entries(in: dir).count == 2)
        #expect(!RestoreDiscovery.scan(drive, history: true).contains { $0.dir == partial })
        // the next run, with history turned off: swept, nothing saved, nothing removed
        _ = try run(history: nil)
        #expect(!FileManager.default.fileExists(atPath: partial.path), "the half-made entry is still there")
        #expect(MirrorHistory.entries(in: dir).map(\.date) == after.map(\.date))
        #expect(MirrorMounts.mountPoints(of: bundle, runner: ProcessCommandRunner()).isEmpty)
    }
}
