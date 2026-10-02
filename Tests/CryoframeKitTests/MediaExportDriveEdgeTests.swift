//
//  MediaExportDriveEdgeTests.swift
//  CryoframeKitTests
//
//  Export Media onto real exFAT and FAT32 drives (disk images), not fakes: a Live
//  Photo whose video was saved in the next month, names that differ only in
//  capitals, the room 128 KiB clusters and `._` companions really take, FAT32's
//  4 GiB limit at its boundary, Stop in each phase followed by another export, a
//  file in the version that can't be read, and an encrypted version opened, stopped
//  and exported again.
//

import Testing
import Foundation
@testable import CryoframeKit

private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0, _ s: Int = 0) -> Date {
    utc.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))!
}

private func realTemp(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-mexedge-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(d.path, &buf) != nil else { return d }
    return URL(fileURLWithPath: String(cString: buf), isDirectory: true)
}

private func put(_ root: URL, _ path: String, _ data: Data, _ date: Date) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
}

/// every file under `root`, hidden ones (the drive's `._` companions) left out
private func listing(_ root: URL) -> [String] {
    var out: [String] = []
    let walk = FileManager.default.enumerator(atPath: root.path)
    while let p = walk?.nextObject() as? String {
        var dir: ObjCBool = false
        let name = (p as NSString).lastPathComponent
        if name.hasPrefix(".") { continue }
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(p).path, isDirectory: &dir), !dir.boolValue { out.append(p) }
    }
    return out.sorted()
}

/// A drive of `fs` ("ExFAT", "MS-DOS FAT32") in a disk image, mounted under `base`.
private func drive(_ fs: String, mb: Int, cluster: Int? = nil, in base: URL) throws -> (mount: URL, detach: () -> Void) {
    let image = base.appendingPathComponent("drive-\(UUID().uuidString).dmg")
    let mount = base.appendingPathComponent("vol-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
    var args = ["create", "-size", "\(mb)m", "-fs", fs, "-volname", "CARD", "-layout", "MBRSPUD", "-type", "UDIF"]
    if let cluster { args += ["-fsargs", "-b \(cluster)"] }
    let made = try ProcessCommandRunner().run("/usr/bin/hdiutil", args + [image.path], stdin: nil)
    try #require(made.ok, "couldn't make the drive: \(made.stderr)")
    let attached = try DiskImageGate.serialized {
        try ProcessCommandRunner().runRetryingBusy("/usr/bin/hdiutil", ["attach", image.path, "-mountpoint", mount.path, "-nobrowse"])
    }
    try #require(attached.ok, "couldn't attach the drive: \(attached.stderr)")
    return (mount, { MountPoint.detach(mount, runner: ProcessCommandRunner()) })
}

private func export(_ source: URL, _ dest: URL, _ filter: MediaExportFilter = MediaExportFilter(kinds: Set(MediaKind.allCases)),
                    control: RunControl = RunControl(),
                    progress: @escaping @Sendable (MediaExportProgress) -> Void = { _ in }) throws -> MediaExportOutcome {
    try MediaExport(calendar: utc, interval: 0).run(from: source, to: dest, filter: filter, control: control, progress: progress)
}

@Suite(.serialized) struct MediaExportDriveEdgeTests {

    // A Live Photo whose video was saved a few seconds into the next month (and next
    // year): both go into the photo's month, under one name, and a filter on months
    // takes or leaves them together. Exporting again copies nothing.
    @Test func aLivePhotoSplitAcrossMonthsStaysTogetherOnExFAT() throws {
        let base = realTemp("live")
        defer { try? FileManager.default.removeItem(at: base) }
        let (card, detach) = try drive("ExFAT", mb: 64, cluster: 131072, in: base)
        defer { detach() }
        let src = base.appendingPathComponent("src")
        try put(src, "A/IMG_0001.HEIC", Data("photo".utf8), at(2023, 12, 31, 23, 59, 58))
        try put(src, "A/IMG_0001.MOV", Data("motion".utf8), at(2024, 1, 1, 0, 0, 2))
        try put(src, "B/IMG_0001.HEIC", Data("another photo".utf8), at(2023, 12, 5))    // same name, same month

        let january = try export(src, card, MediaExportFilter(kinds: [.photos, .videos], from: MediaMonth(year: 2024, month: 1)))
        #expect(january.copied == 0 && january.matched == 0, "the pair split by a month filter: \(january)")

        let all = try export(src, card)
        #expect(all.copied == 3 && !all.stopped)
        let names = listing(card)
        // the pair shares one name; the other photo takes the next
        #expect(names == ["2023-12/IMG_0001 (2).HEIC", "2023-12/IMG_0001.HEIC", "2023-12/IMG_0001.MOV"]
                || names == ["2023-12/IMG_0001 (2).HEIC", "2023-12/IMG_0001 (2).MOV", "2023-12/IMG_0001.HEIC"], "\(names)")
        let photo = try String(contentsOf: card.appendingPathComponent("2023-12/IMG_0001.HEIC"), encoding: .utf8)
        let pairedName = photo == "photo" ? "2023-12/IMG_0001.MOV" : "2023-12/IMG_0001 (2).MOV"
        #expect(try String(contentsOf: card.appendingPathComponent(pairedName), encoding: .utf8) == "motion")
        let date = try FileManager.default.attributesOfItem(atPath: card.appendingPathComponent(pairedName).path)[.modificationDate] as? Date
        #expect(date == at(2024, 1, 1, 0, 0, 2), "the video's date on exFAT: \(String(describing: date))")

        let again = try export(src, card)
        #expect(again.copied == 0 && again.alreadyThere == 3, "\(again)")
    }

    // Names that differ only in capitals, from different folders, in one month, on a
    // drive that folds case: different bytes get two names, the same bytes one file.
    @Test func caseOnlyNamesOnExFATAndFAT32() throws {
        for fs in ["ExFAT", "MS-DOS FAT32"] {
            let base = realTemp("case")
            defer { try? FileManager.default.removeItem(at: base) }
            let (card, detach) = try drive(fs, mb: 64, in: base)
            defer { detach() }
            let src = base.appendingPathComponent("src")
            try put(src, "A/Beach.JPG", Data("one".utf8), at(2024, 5, 1))
            try put(src, "B/beach.jpg", Data("two".utf8), at(2024, 5, 2))
            try put(src, "C/BEACH.jpg", Data("one".utf8), at(2024, 5, 3))          // A's bytes again
            let first = try export(src, card)
            #expect(first.copied == 2 && first.alreadyThere == 1, "\(fs): \(first)")
            #expect(listing(card).count == 2, "\(fs): \(listing(card))")
            let again = try export(src, card)
            #expect(again.copied == 0 && again.alreadyThere == 3, "\(fs) again: \(again)")
        }
    }

    // FAT32 takes a file of 4 GiB less a byte and refuses one of 4 GiB, as read from a
    // real FAT32 drive.
    @Test func fat32LimitAtItsBoundary() throws {
        let base = realTemp("fat")
        defer { try? FileManager.default.removeItem(at: base) }
        let (card, detach) = try drive("MS-DOS FAT32", mb: 64, in: base)
        defer { detach() }
        let d = MediaExportDrive.of(card)
        #expect(d.maxFileSize == MediaExportDrive.fat32Limit && d.foldsCase && d.companions)
        let src = base.appendingPathComponent("src")
        try put(src, "big.mov", Data(), at(2024, 5, 1))
        try put(src, "almost.mov", Data(), at(2024, 5, 1))
        #expect(truncate(src.appendingPathComponent("big.mov").path, off_t(MediaExportDrive.fat32Limit)) == 0)
        #expect(truncate(src.appendingPathComponent("almost.mov").path, off_t(MediaExportDrive.fat32Limit - 1)) == 0)
        let control = RunControl()
        let files = try MediaExport.look(in: src, control: control) { _ in }
        let plan = try MediaExportPlanner.plan(MediaCatalog.entries(files), drive: d,
                                               probe: MediaExport.probe(source: src, destination: card, control: control), calendar: utc)
        #expect(plan.tooLarge == ["big.mov"] && plan.copies.map(\.name) == ["almost.mov"], "\(plan.tooLarge) \(plan.copies.map(\.name))")
        // and the run says there isn't room for the one it would copy, before writing anything
        #expect(throws: MediaExportError.self) { try export(src, card) }
        #expect(listing(card).isEmpty)
    }

    // On 128 KiB clusters, what the export really takes never exceeds what the room
    // check asked for: small files, their `._` companions, and the month folders.
    @Test func roomOn128KiBClustersCoversWhatIsReallyUsed() throws {
        let base = realTemp("room")
        defer { try? FileManager.default.removeItem(at: base) }
        let (card, detach) = try drive("ExFAT", mb: 200, cluster: 131072, in: base)
        defer { detach() }
        let src = base.appendingPathComponent("src")
        for i in 0..<300 {
            try put(src, "m\(i % 3)/IMG_\(i).JPG", Data(repeating: UInt8(i % 200), count: 1000 + i), at(2024, 1 + i % 6, 3))
        }
        let d = MediaExportDrive.of(card)
        #expect(d.cluster == 131072 && d.companions, "\(d)")
        let control = RunControl()
        let files = try MediaExport.look(in: src, control: control) { _ in }
        let plan = try MediaExportPlanner.plan(MediaCatalog.entries(files), drive: d,
                                               probe: MediaExport.probe(source: src, destination: card, control: control), calendar: utc)
        let needed = MediaExportRoom.needed(plan, drive: d)
        let before = try #require(JobExecutor.freeSpace(for: card))
        let out = try export(src, card)
        let after = try #require(JobExecutor.freeSpace(for: card))
        let used = before - after
        let companions = (FileManager.default.enumerator(atPath: card.path)?.allObjects as? [String] ?? [])
            .filter { ($0 as NSString).lastPathComponent.hasPrefix("._") }.count
        print("ROOM128 copied=\(out.copied) needed=\(needed) used=\(used) companions=\(companions)")
        #expect(out.copied == 300)
        #expect(used <= needed, "the export used \(used) bytes; the room check asked for \(needed)")
    }

    // Stop in each phase (looking, checking what an earlier export left, copying),
    // then export again: the folder ends exactly as one export without a Stop leaves
    // it, with no part-written file.
    @Test(arguments: [MediaExportProgress.Phase.looking, .checking, .copying])
    func stopInEachPhaseThenExportAgain(_ phase: MediaExportProgress.Phase) throws {
        let base = realTemp("stop")
        defer { try? FileManager.default.removeItem(at: base) }
        let (card, detach) = try drive("ExFAT", mb: 300, cluster: 131072, in: base)
        defer { detach() }
        let src = base.appendingPathComponent("src")
        for i in 0..<600 {
            // several files of one name in one month, some with the same bytes
            try put(src, "g\(i % 20)/IMG_\(i / 20).HEIC", Data(repeating: UInt8(i % 13), count: 20_000 + (i % 13)), at(2024, 1 + i % 3, 5))
        }
        try put(src, "g1/IMG_1.MOV", Data(repeating: 9, count: 30_000), at(2024, 2, 1))
        let clean = base.appendingPathComponent("clean")
        try FileManager.default.createDirectory(at: clean, withIntermediateDirectories: true)
        let reference = try export(src, clean)
        #expect(!reference.stopped && reference.copied > 0)

        // the checking phase only reads when an earlier export left something
        if phase == .checking {
            let partial = RunControl()
            _ = try export(src, card, control: partial) { p in
                if p.phase == .copying, p.detail.hasPrefix("Copying 100 of") { partial.cancel() }
            }
        }
        let control = RunControl()
        let stopped = try export(src, card, control: control) { p in
            if p.phase == phase, phase != .copying || p.detail.hasPrefix("Copying 50 of") { control.cancel() }
        }
        #expect(stopped.stopped, "\(phase): \(stopped)")
        let parts = (FileManager.default.enumerator(atPath: card.path)?.allObjects as? [String] ?? [])
            .filter { ($0 as NSString).lastPathComponent.contains(MediaExport.tempPrefix) }
        #expect(parts.isEmpty, "part files left: \(parts)")

        let finished = try export(src, card)
        #expect(!finished.stopped)
        #expect(listing(card) == listing(clean), "\(phase): the names differ from an export without a Stop")
        for name in listing(clean) {
            #expect(FileManager.default.contentsEqual(atPath: clean.appendingPathComponent(name).path,
                                                      andPath: card.appendingPathComponent(name).path), "\(name)")
        }
        #expect(try export(src, card).copied == 0)
    }

    // A file in the version that can't be read (a damaged image answers EIO; here, a
    // file nobody may read) is one file. The export says which, but the files after
    // it in the fixed order must still be reachable: otherwise every export stops at
    // the same file and the rest can never be exported.
    @Test func oneUnreadableFileDoesNotBlockTheRestForever() throws {
        let base = realTemp("unreadable")
        defer {
            chmod(base.appendingPathComponent("src/b/IMG_5.JPG").path, 0o644)
            try? FileManager.default.removeItem(at: base)
        }
        let src = base.appendingPathComponent("src"), dest = base.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        for i in 0..<10 { try put(src, "\(i < 5 ? "a" : "b")/IMG_\(i).JPG", Data("photo \(i)".utf8), at(2024, 5, 3)) }
        #expect(chmod(src.appendingPathComponent("b/IMG_5.JPG").path, 0) == 0)

        var outcomes: [String] = []
        for _ in 0..<2 {
            do { outcomes.append("copied \(try export(src, dest).copied)") } catch { outcomes.append("\(error)") }
        }
        print("UNREADABLE \(outcomes) exported=\(listing(dest))")
        #expect(listing(dest).count == 9, "after two exports, \(listing(dest).count) of the 9 readable files are out: \(outcomes)")
    }

    // An encrypted version: Stop mid-open leaves nothing attached; then opened, an
    // export stopped while copying, closed; opened again, the export finishes, and a
    // third copies nothing. Nothing stays attached.
    @Test func anEncryptedVersionStoppedMidOpenAndMidCopyThenExportedAgain() async throws {
        let base = realTemp("enc")
        defer { try? FileManager.default.removeItem(at: base) }
        let src = base.appendingPathComponent("src"), dest = base.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        for i in 0..<120 { try put(src, "Lib/g\(i % 6)/IMG_\(i).HEIC", Data(repeating: UInt8(i), count: 200_000), at(2024, 3, 1 + i % 20)) }
        let dmg = base.appendingPathComponent("v.dmg")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = ["create", "-srcfolder", src.path, "-encryption", "AES-256", "-stdinpass", "-format", "UDZO",
                       "-volname", "cfmexenc", "-ov", dmg.path]
        let inp = Pipe(); p.standardInput = inp; p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); inp.fileHandleForWriting.write(Data("pw".utf8)); try inp.fileHandleForWriting.close()
        #expect(waitBounded(p, seconds: 120) != nil)
        try #require(p.terminationStatus == 0)
        let result = ArchiveResult(artifacts: [dmg], format: .sealedDMG)
        let work = base.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        func open(_ o: ArchiveOpener) async -> ArchiveOpener.Outcome {
            await o.open(name: "v.dmg", passphrases: ["wrong", "pw"]) { pass, control in
                try ArchiveReader(runner: ProcessCommandRunner(control: control), workBase: work).open(result, passphrase: pass)
            }
        }
        func attached() -> Bool {
            let i = Process(); i.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil"); i.arguments = ["info"]
            let o = Pipe(); i.standardOutput = o; i.standardError = Pipe(); try? i.run()
            let t = String(decoding: o.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); i.waitUntilExit()
            return t.contains(base.lastPathComponent)
        }

        // Stop while it opens (the sheet's Stop before a control exists closes the opener)
        let first = ArchiveOpener()
        let opening = Task { await open(first) }
        try await Task.sleep(nanoseconds: 150_000_000)
        first.close()
        _ = await opening.value
        #expect(!attached(), "an open stopped part way left the version attached")

        // opened; Stop while copying; closed
        let second = ArchiveOpener()
        guard case .opened(let o) = await open(second) else { Issue.record("didn't open"); return }
        let control = RunControl()
        let stopped = try export(o.root.appendingPathComponent("Lib"), dest, control: control) { p in
            if p.phase == .copying, p.detail.hasPrefix("Copying 30 of") { control.cancel() }
        }
        await Task.detached { second.close() }.value
        #expect(stopped.stopped && stopped.copied == 29, "\(stopped)")
        #expect(!attached(), "closing after a stopped export left the version attached")

        // again: finishes; and once more: nothing to copy
        let third = ArchiveOpener()
        guard case .opened(let o3) = await open(third) else { Issue.record("didn't open again"); return }
        let rest = try export(o3.root.appendingPathComponent("Lib"), dest)
        let none = try export(o3.root.appendingPathComponent("Lib"), dest)
        await Task.detached { third.close() }.value
        #expect(rest.copied == 91 && rest.alreadyThere == 29, "\(rest)")
        #expect(none.copied == 0 && none.alreadyThere == 120, "\(none)")
        #expect(listing(dest).count == 120)
        #expect(!attached())
    }
}
