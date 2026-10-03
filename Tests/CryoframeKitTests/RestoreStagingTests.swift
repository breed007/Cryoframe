//
//  RestoreStagingTests.swift
//  CryoframeKitTests
//
//  Restores cut off part way (see RestoreStaging): a restore beside the library
//  takes the library's name only once whole, and what one cut off leaves is removed
//  by the next; a restore in place cut off between moving the library to the Trash
//  and moving the copy in is finished at the next launch, or its copy put where it
//  shows, and nothing is deleted.
//

import Testing
import Foundation
@testable import CryoframeKit

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-rstage-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

private func write(_ url: URL, _ text: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

private func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

/// a zip of a "Papers" folder holding a.txt ("restored"), and the live "Papers" it
/// restores over (a.txt: "live")
private func fixture(_ base: URL) throws -> (archive: RestorableArchive, live: URL) {
    let lib = base.appendingPathComponent("made/Papers")
    try write(lib.appendingPathComponent("a.txt"), "restored")
    try write(lib.appendingPathComponent("sub/b.txt"), "b")
    let dir = base.appendingPathComponent("backup/Papers/2026-10-01-020000")
    let result = try SealedArchiveEngine(.zip).archive(ArchiveSource(name: "Papers", root: lib), to: dir)
    try ArchiveManifest.write(try ArchiveManifest.build(for: result), toDir: dir)
    let archive = try #require(RestoreDiscovery.archive(at: dir))
    let live = base.appendingPathComponent("home/Papers")
    try write(live.appendingPathComponent("a.txt"), "live")
    return (archive, live)
}

private func staging(in parent: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []).filter { $0.hasPrefix(RestoreStaging.prefix) }
}

private struct CutOff: Error {}

/// a leftover as paths: a folder's URL may or may not end in "/"
private func said(_ l: RestoreStaging.Leftover) -> String {
    "\(l.what) \(l.live.path) \(l.copy.path) \(l.trashed?.path ?? "-")"
}

@Suite(.serialized) struct RestoreStagingTests {

    // MARK: beside

    // The copy is made under a hidden name: a restore cut off part way (here, let go
    // of as a crash would) leaves nothing under the library's name, and the next
    // restore into the folder removes what it left and takes the name.
    @Test func aRestoreCutOffLeavesNoHalfLibraryUnderItsName() throws {
        let base = folder("beside")
        defer { try? FileManager.default.removeItem(at: base) }
        let (archive, _) = try fixture(base)
        let dest = base.appendingPathComponent("Desktop")
        let (held, staged) = try RestoreEngine().stage(archive, in: dest, verify: true, passphrase: nil, clash: .refuse,
                                                        inPlace: false, onStage: { _ in })
        #expect(text(staged.appendingPathComponent("a.txt")) == "restored")
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("Papers").path))
        #expect(staging(in: dest).count == 1)

        // a restore still running isn't swept by another
        let other = try RestoreStaging.begin(in: dest)
        #expect(staging(in: dest).count == 2)
        other.end()
        held.release()                                  // cut off

        let url = try RestoreEngine().restore(archive, to: dest)
        #expect(url.path == dest.appendingPathComponent("Papers").path)
        #expect(text(url.appendingPathComponent("sub/b.txt")) == "b")
        #expect(staging(in: dest).isEmpty, "\(staging(in: dest))")
    }

    // Alongside still finds a free name, and refuse still refuses, with nothing left behind.
    @Test func aRestoreBesideTakesTheNextFreeNameOrRefuses() throws {
        let base = folder("clash")
        defer { try? FileManager.default.removeItem(at: base) }
        let (archive, live) = try fixture(base)
        let parent = live.deletingLastPathComponent()
        #expect(throws: RestoreError.destinationExists(live.path)) { try RestoreEngine().restore(archive, to: parent) }
        let url = try RestoreEngine().restore(archive, to: parent, onClash: .alongside)
        #expect(url.lastPathComponent == "Papers (2)")
        #expect(text(live.appendingPathComponent("a.txt")) == "live")
        #expect(staging(in: parent).isEmpty)
    }

    // MARK: in place

    @Test func aRestoreInPlaceReplacesTheLibraryAndTrashesTheOld() throws {
        let base = folder("inplace")
        defer { try? FileManager.default.removeItem(at: base) }
        let (archive, live) = try fixture(base)
        let trash = base.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let outcome = try RestoreInPlace.run(archive, live: live, passphrase: nil, trash: { url in
            let to = trash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: to)
            return to
        })
        guard case .replaced(let trashed) = outcome else { Issue.record("\(outcome)"); return }
        #expect(trashed?.path == trash.appendingPathComponent("Papers").path)
        #expect(text(live.appendingPathComponent("a.txt")) == "restored")
        #expect(text(trash.appendingPathComponent("Papers/a.txt")) == "live")
        #expect(staging(in: live.deletingLastPathComponent()).isEmpty)
    }

    // The Trash refusing leaves the library as it was, and no copy behind.
    @Test func aRestoreInPlaceTheTrashRefusesTouchesNothing() throws {
        let base = folder("refused")
        defer { try? FileManager.default.removeItem(at: base) }
        let (archive, live) = try fixture(base)
        #expect(throws: CutOff.self) {
            try RestoreInPlace.run(archive, live: live, passphrase: nil, trash: { _ in throw CutOff() })
        }
        #expect(text(live.appendingPathComponent("a.txt")) == "live")
        #expect(staging(in: live.deletingLastPathComponent()).isEmpty)
        #expect(RestoreStaging.recover(lives: [live]).isEmpty)
    }

    // Cut off after the library went to the Trash and before the copy went in: the
    // library's place is empty, and the verified copy is in a hidden folder. At the
    // next launch the move is finished; the library in the Trash is left there.
    @Test func aRestoreInPlaceCutOffAfterTheTrashIsFinishedAtLaunch() throws {
        let base = folder("finish")
        defer { try? FileManager.default.removeItem(at: base) }
        let (archive, live) = try fixture(base)
        let trash = base.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let trashed = trash.appendingPathComponent("Papers 10.42.07")
        #expect(throws: CutOff.self) {
            try RestoreInPlace.run(archive, live: live, passphrase: nil, trash: { url in
                try FileManager.default.moveItem(at: url, to: trashed)
                return trashed
            }, afterTrash: { throw CutOff() })
        }
        let parent = live.deletingLastPathComponent()
        #expect(!FileManager.default.fileExists(atPath: live.path))
        #expect(staging(in: parent).count == 1, "the verified copy was removed")

        let found = RestoreStaging.recover(lives: [live])
        #expect(found.map(said) == [said(.init(what: .finished, live: live, copy: live, trashed: trashed))])
        #expect(text(live.appendingPathComponent("a.txt")) == "restored")
        #expect(text(live.appendingPathComponent("sub/b.txt")) == "b")
        #expect(text(trashed.appendingPathComponent("a.txt")) == "live")
        #expect(staging(in: parent).isEmpty)
        #expect(RestoreStaging.recover(lives: [live]).isEmpty)
    }

    // The same, with something put in the library's place meanwhile (the app made a
    // new, empty library): neither is replaced; the copy is put beside it where it
    // shows, and the app says where both are.
    @Test func aCutOffRestoreWhosePlaceIsTakenIsPutBeside() throws {
        let base = folder("taken")
        defer { try? FileManager.default.removeItem(at: base) }
        let (archive, live) = try fixture(base)
        let trash = base.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        #expect(throws: CutOff.self) {
            try RestoreInPlace.run(archive, live: live, passphrase: nil, trash: { url in
                try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent("Papers"))
                return nil                              // the Trash didn't say where
            }, afterTrash: { throw CutOff() })
        }
        try write(live.appendingPathComponent("new.txt"), "new")

        let found = RestoreStaging.recover(lives: [live])
        let beside = live.deletingLastPathComponent().appendingPathComponent("Papers (2)")
        #expect(found.map(said) == [said(.init(what: .verifiedBeside, live: live, copy: beside, trashed: nil))])
        #expect(text(beside.appendingPathComponent("a.txt")) == "restored")
        #expect(text(live.appendingPathComponent("new.txt")) == "new")
        #expect(text(trash.appendingPathComponent("Papers/a.txt")) == "live")
        #expect(staging(in: live.deletingLastPathComponent()).isEmpty)
    }

    // 1.6 kept no record of whether its hidden copy was whole: it is put beside the
    // library where it shows, to be checked, never in the library's place.
    @Test func anEarlierVersionsLeftoverIsPutBesideUnverified() throws {
        let base = folder("legacy")
        defer { try? FileManager.default.removeItem(at: base) }
        let live = base.appendingPathComponent("home/Papers")
        let old = base.appendingPathComponent("home/\(RestoreStaging.prefix)\(UUID().uuidString)")
        try write(old.appendingPathComponent("Papers/a.txt"), "old copy")

        let found = RestoreStaging.recover(lives: [live])
        let beside = base.appendingPathComponent("home/Papers (2)")
        #expect(found.map(said) == [said(.init(what: .unverifiedBeside, live: live, copy: beside, trashed: nil))])
        #expect(text(beside.appendingPathComponent("a.txt")) == "old copy")
        #expect(!FileManager.default.fileExists(atPath: live.path))
        #expect(staging(in: live.deletingLastPathComponent()).isEmpty)
    }

    // An unfinished copy this version made (never verified, the library never
    // touched) is removed; one a restore still holds is left alone.
    @Test func anUnfinishedCopyIsRemovedAndAHeldOneLeftAlone() throws {
        let base = folder("unfinished")
        defer { try? FileManager.default.removeItem(at: base) }
        let live = base.appendingPathComponent("home/Papers")
        try write(live.appendingPathComponent("a.txt"), "live")
        let cut = try RestoreStaging.begin(in: live.deletingLastPathComponent())
        try write(cut.dir.appendingPathComponent("Papers/a.txt"), "half")
        cut.release()
        let running = try RestoreStaging.begin(in: live.deletingLastPathComponent())
        try write(running.dir.appendingPathComponent("Papers/a.txt"), "copying")

        #expect(RestoreStaging.recover(lives: [live]).isEmpty)
        #expect(staging(in: live.deletingLastPathComponent()) == [running.dir.lastPathComponent])
        #expect(text(live.appendingPathComponent("a.txt")) == "live")
        running.end()
        #expect(staging(in: live.deletingLastPathComponent()).isEmpty)
    }
}
