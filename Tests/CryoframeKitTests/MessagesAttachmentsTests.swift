//
//  MessagesAttachmentsTests.swift
//  CryoframeKitTests
//
//  Messages attachments as a library of their own: what the editor says of them,
//  what every format leaves out (link previews, property lists, Finder's files),
//  and what each one-copy format keeps of what was deleted in Messages. All on a
//  made-up Attachments folder in a temporary folder; never the real one.
//

import Testing
import Foundation
@testable import CryoframeKit

private func tempDir(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-att-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@discardableResult
private func put(_ root: URL, _ rel: String, _ text: String, date: TimeInterval = 1_700_000_000) throws -> URL {
    let url = root.appendingPathComponent(rel)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
    var times = [timespec(tv_sec: Int(date), tv_nsec: 0), timespec(tv_sec: Int(date), tv_nsec: 0)]
    _ = utimensat(AT_FDCWD, url.path, &times, 0)
    return url
}

/// an Attachments folder laid out as Messages lays it out: <2 hex>/<2 digits>/<GUID>/<name>
private func attachments() throws -> URL {
    let root = tempDir("src").appendingPathComponent("Attachments")
    try put(root, "0a/01/AAAA-1111/IMG_0001.HEIC", "photo 1")
    try put(root, "0a/01/AAAA-1111/IMG_0001.MOV", "live photo 1")
    try put(root, "0a/02/BBBB-2222/IMG_0002.JPG", "photo 2")
    try put(root, "1f/03/CCCC-3333/Trip.pdf", "a document")
    try put(root, "1f/03/DDDD-4444/link.pluginPayloadAttachment", "a link preview")
    try put(root, "1f/04/EEEE-5555/Preview.pluginPayloadAttachment/payload.bin", "a link preview kept as a folder")
    try put(root, "2b/05/FFFF-6666/Info.plist", "a property list")
    try put(root, ".DS_Store", "Finder")
    return root
}

private let junk = ["1f/03/DDDD-4444/link.pluginPayloadAttachment", "1f/04/EEEE-5555/Preview.pluginPayloadAttachment",
                    "2b/05/FFFF-6666/Info.plist", ".DS_Store"]

/// every path under `root`, sorted
private func tree(_ root: URL) -> [String] {
    var out: [String] = []
    func walk(_ rel: String) {
        for name in PlainCopy.list(rel.isEmpty ? root.path : root.appendingPathComponent(rel).path).sorted() {
            let r = rel.isEmpty ? name : rel + "/" + name
            out.append(r)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: root.appendingPathComponent(r).path, isDirectory: &isDir), isDir.boolValue { walk(r) }
        }
    }
    walk("")
    return out
}

private func files(_ root: URL) -> [String] {
    tree(root).filter { rel in
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.appendingPathComponent(rel).path, isDirectory: &isDir) && !isDir.boolValue
    }
}

private let wanted = ["0a/01/AAAA-1111/IMG_0001.HEIC", "0a/01/AAAA-1111/IMG_0001.MOV", "0a/02/BBBB-2222/IMG_0002.JPG",
                      "1f/03/CCCC-3333/Trip.pdf"]

@Suite struct MessagesAttachmentsEditorTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let docs = ContentType(id: "docs", displayName: "Documents", paths: [.absolute("/tmp/docs")], owningProcess: nil, kind: .staticContent)
    private let card = Target.externalDrive(id: "card", name: "Card", dir: URL(fileURLWithPath: "/Volumes/Card/Backups", isDirectory: true))

    // The unencrypted warning names messages only when the job keeps them; the
    // attachments are kept as plain files on any drive (they open in no app); and
    // chosen with Messages, the editor says they are kept twice.
    @Test func theEditorSaysWhatTheAttachmentsLibraryMeans() {
        var d = JobDraftState(editing: nil, libraries: [.messages, .messagesAttachments, docs], targets: [card], now: now)
        d.formatKind = "plain"
        d.selectedTargetIDs = ["card"]
        d.selectedLibraryIDs = [ContentType.messagesAttachments.id]
        let notice = d.plainFilesNotice(encrypted: { _ in false }) ?? ""
        #expect(notice.contains("including photos and files from your messages"))
        #expect(!(d.plainFilesNotice(encrypted: { _ in true }) ?? "").contains("messages"))
        #expect(d.plainFilesIssues(profile: { _ in .make(fsType: "exfat") }).isEmpty)
        #expect(d.libraryOverlaps.isEmpty)

        d.selectedLibraryIDs = ["docs"]
        #expect(!(d.plainFilesNotice(encrypted: { _ in false }) ?? "").contains("messages"))

        d.selectedLibraryIDs = [ContentType.messages.id, ContentType.messagesAttachments.id]
        #expect(d.libraryOverlaps == ["Messages already includes Messages attachments, so this job keeps them twice. To keep only the photos, videos and files, choose Messages attachments alone."])
    }
}

@Suite(.serialized) struct MessagesAttachmentsCopyTests {

    // The run's walk passes over what the library leaves out, what is in it too: not
    // counted, not listed, and named once for the formats to leave out.
    @Test func theWalkLeavesOutPreviewsAndPropertyLists() throws {
        let src = try attachments()
        defer { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }
        let listing = ContentsListing.Collector(binding: ContentsCrypto.Binding(jobID: "j", libraryID: "l", version: "v"))
        let stats = JobExecutor.directoryStats(src, forZip: true, listing: listing,
                                               leavesOut: ContentType.messagesAttachments.leavesOut)
        #expect(stats.excluded.sorted() == junk.sorted())
        #expect(stats.entries == wanted.count)
        #expect(listing.count == wanted.count + 14)          // and the 14 folders not left out
        #expect(JobExecutor.directoryStats(src).entries == wanted.count + 4)
        #expect(SealedReadPlan.of(stats.dmgBlockers, .zip, excluding: true).fromCopy)
        #expect(!SealedReadPlan.of(stats.dmgBlockers, .zip).fromCopy)
    }

    // A sealed build reads a copy without them.
    @Test func aSealedBuildLeavesThemOut() throws {
        let src = try attachments()
        let base = tempDir("sealed")
        defer { for d in [src.deletingLastPathComponent(), base] { try? FileManager.default.removeItem(at: d) } }
        let stats = JobExecutor.directoryStats(src, forZip: true, leavesOut: ContentType.messagesAttachments.leavesOut)
        let build = base.appendingPathComponent("build")
        let built = try FilteredCopy.sealedArchive(SealedArchiveEngine(.zip),
                                                   source: ArchiveSource(name: "Attachments", root: src, excluded: stats.excluded),
                                                   found: stats.dmgBlockers, plan: .of(stats.dmgBlockers, .zip, excluding: true),
                                                   buildDir: build, copyDir: build, library: "Messages attachments",
                                                   runner: ProcessCommandRunner())
        let out = base.appendingPathComponent("out")
        let r = try ProcessCommandRunner().run("/usr/bin/ditto", ["-x", "-k", built.archive.artifacts[0].path, out.path], stdin: nil)
        #expect(r.ok, "\(r.stderr)")
        #expect(files(out.appendingPathComponent("Attachments")) == wanted)
        #expect(!FileManager.default.fileExists(atPath: build.appendingPathComponent(FilteredCopy.folderName).path))
    }

    // Plain files: left out without a word; what Messages deleted moves to Removed items.
    @Test func plainFilesLeaveThemOutAndKeepWhatWasDeleted() throws {
        let src = try attachments()
        let folder = tempDir("plain")
        defer { for d in [src.deletingLastPathComponent(), folder] { try? FileManager.default.removeItem(at: d) } }
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let profile = FileSystemProfile(kind: .exfat, fsType: "exfat", foldsCase: true, cluster: 4096, companions: false)
        let copier = PlainCopy(profile: profile, runner: ProcessCommandRunner(), now: Date(timeIntervalSince1970: 1_800_000_000),
                               calendar: utc, freeSpace: { _ in .max }, companions: false, accepts: { _ in true })
        let excluded = JobExecutor.directoryStats(src, leavesOut: ContentType.messagesAttachments.leavesOut).excluded
        let first = try copier.run(src, in: folder, excluded: excluded)
        #expect(first.notes.isEmpty)
        #expect(files(first.copy) == wanted)

        try FileManager.default.removeItem(at: src.appendingPathComponent("0a/02/BBBB-2222"))
        let second = try copier.run(src, in: folder, excluded: excluded)
        #expect(second.removed == 1 && second.notes.isEmpty)
        let day = folder.appendingPathComponent("Removed items/2027-01-15")
        #expect(files(day) == ["0a/02/BBBB-2222/IMG_0002.JPG"])
    }

    // What the previous copy holds and the new one doesn't, each the topmost item; an
    // item of another kind counts; a clone of each is kept, once.
    @Test func removedItemsAreFoundAndKeptOnce() throws {
        let base = tempDir("removed")
        defer { try? FileManager.default.removeItem(at: base) }
        let current = base.appendingPathComponent("current"), next = base.appendingPathComponent("next")
        for root in [current, next] {
            try put(root, "a/kept.jpg", "kept")
            try put(root, "b/c/kept.mov", "kept")
        }
        try put(current, "a/gone.jpg", "gone")
        try put(current, "d/e/gone.heic", "gone")
        try put(current, "d/e/also.heic", "gone")
        try put(current, "f", "a file that became a folder")
        try put(next, "f/new.txt", "new")
        let missing = try RemovedItems.missing(from: next, in: current, control: nil)
        #expect(missing == ["a/gone.jpg", "d", "f"])

        let folder = base.appendingPathComponent("volume")
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(try RemovedItems.keep(missing, from: current, in: folder, now: when, calendar: utc, runner: ProcessCommandRunner()) == 3)
        let day = folder.appendingPathComponent("Removed items/2027-01-15")
        #expect(files(day) == ["a/gone.jpg", "d/e/also.heic", "d/e/gone.heic", "f"])
        // a run that stopped after this keeps them again: nothing doubles
        #expect(try RemovedItems.keep(missing, from: current, in: folder, now: when, calendar: utc, runner: ProcessCommandRunner()) == 3)
        #expect(files(day) == ["a/gone.jpg", "d/e/also.heic", "d/e/gone.heic", "f"])
        // another item deleted under the same name the same day is kept beside it
        try put(current, "a/gone.jpg", "gone again, changed")
        #expect(try RemovedItems.keep(["a/gone.jpg"], from: current, in: folder, now: when, calendar: utc, runner: ProcessCommandRunner()) == 1)
        #expect(files(day) == ["a/gone (2).jpg", "a/gone.jpg", "d/e/also.heic", "d/e/gone.heic", "f"])
        // Stop ends it
        let control = RunControl(); control.cancel()
        #expect(throws: CancelledError.self) {
            try RemovedItems.keep(["x"], from: current, in: folder, now: when, runner: ProcessCommandRunner(control: control))
        }
    }
}

/// regular files in an image, through a read-only attach, relative to its top
private func filesInImage(_ bundle: URL) throws -> [String] {
    let mnt = tempDir("look")
    defer { MountPoint.detach(mnt, runner: ProcessCommandRunner()); try? FileManager.default.removeItem(at: mnt) }
    let r = try DiskImageGate.serialized {
        try ProcessCommandRunner().runRetryingBusy("/usr/bin/hdiutil", ["attach", bundle.path, "-mountpoint", mnt.path, "-nobrowse", "-readonly"])
    }
    try #require(r.ok, "couldn't attach the image: \(r.stderr)")
    return files(mnt).filter { !$0.hasPrefix(".") }
}

@Suite(.serialized) struct MessagesAttachmentsMirrorTests {

    // The up-to-date disk image: previews left out; what Messages deleted moves to
    // Removed items at the top of the image (the copy a restore reads stays exact);
    // a run with nothing deleted keeps nothing more. A library that doesn't keep what
    // is deleted gets no Removed items.
    @Test func theImageKeepsWhatWasDeletedInRemovedItems() throws {
        let src = try attachments()
        let out = tempDir("mirror"), base = tempDir("mnt")
        defer { for d in [src.deletingLastPathComponent(), out, base] { try? FileManager.default.removeItem(at: d) } }
        let leaves = ContentType.messagesAttachments.leavesOut
        func run(keeps: Bool = true) throws {
            let excluded = JobExecutor.directoryStats(src, leavesOut: leaves).excluded
            _ = try SparseBundleMirrorEngine(sizeGB: 1, mountBase: base)
                .archive(ArchiveSource(name: "Attachments", root: src, excluded: excluded, keepsRemoved: keeps), to: out)
        }
        let bundle = out.appendingPathComponent("Attachments.sparsebundle")
        try run()
        #expect(try filesInImage(bundle) == wanted.map { "Attachments/" + $0 })

        try FileManager.default.removeItem(at: src.appendingPathComponent("0a/01/AAAA-1111"))
        try FileManager.default.removeItem(at: src.appendingPathComponent("1f/03/CCCC-3333/Trip.pdf"))
        try run()
        var c = Calendar(identifier: .gregorian); c.timeZone = .current
        let parts = c.dateComponents([.year, .month, .day], from: Date())
        let day = String(format: "Removed items/%04d-%02d-%02d/", parts.year!, parts.month!, parts.day!)
        let expected = ["Attachments/0a/02/BBBB-2222/IMG_0002.JPG",
                        day + "0a/01/AAAA-1111/IMG_0001.HEIC", day + "0a/01/AAAA-1111/IMG_0001.MOV", day + "1f/03/CCCC-3333/Trip.pdf"]
        #expect(try filesInImage(bundle) == expected)
        try run()
        #expect(try filesInImage(bundle) == expected)

        try FileManager.default.removeItem(at: src.appendingPathComponent("0a/02/BBBB-2222"))
        try run(keeps: false)
        #expect(try filesInImage(bundle) == Array(expected.dropFirst()))
    }
}
