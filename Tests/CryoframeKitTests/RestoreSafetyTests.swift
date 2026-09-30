//
//  RestoreSafetyTests.swift
//  CryoframeKitTests
//
//  Restores that can't fill a drive or stop at a name clash: the room check before
//  anything is read and again once the archive is open, restoring alongside an item
//  already there, and a download's quarantine coming back as the archive holds it.
//

import Testing
import Foundation
@testable import CryoframeKit

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-rsafe-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

private func sealed(_ kind: SealedArchiveEngine.Sealed, _ lib: URL, to dir: URL) throws -> RestorableArchive {
    let result = try SealedArchiveEngine(kind).archive(ArchiveSource(name: lib.lastPathComponent, root: lib), to: dir)
    try ArchiveManifest.write(try ArchiveManifest.build(for: result), toDir: dir)
    return try #require(RestoreDiscovery.archive(at: dir))
}

private final class Stages: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [RestoreStage] = []
    func add(_ s: RestoreStage) { lock.lock(); seen.append(s); lock.unlock() }
    var all: [RestoreStage] { lock.lock(); defer { lock.unlock() }; return seen }
}

private func attachedImages() -> String {
    (try? ProcessCommandRunner().run("/usr/bin/hdiutil", ["info"]).stdout) ?? ""
}

@Suite(.serialized) struct RestoreSafetyTests {

    // MARK: room

    @Test func theRoomNeededIsTheLibraryAndAMargin() {
        let gb: UInt64 = 1_000_000_000
        #expect(RestoreRoom.needed(for: 100 * gb) == 105 * gb)
        #expect(RestoreRoom.needed(for: 1_000) == 1_000 + 256 * 1024 * 1024)
        #expect(RestoreRoom.refusal(bytes: 100 * gb, free: 105 * gb, volume: "T7", inPlace: false) == nil)
        #expect(RestoreRoom.refusal(bytes: 100 * gb, free: nil, volume: "NAS", inPlace: false) == nil, "a share that doesn't say isn't refused")
        #expect(RestoreRoom.refusal(bytes: 100 * gb, free: 105 * gb - 1, volume: "T7", inPlace: true)
                == .notEnoughRoom(needed: 105 * gb, free: 105 * gb - 1, volume: "T7", inPlace: true))
    }

    @Test func theRefusalGivesTheNumbersAndSaysNothingWasWritten() {
        let gb: UInt64 = 1_000_000_000
        let beside = RestoreFailureText.restoreMessage(RestoreError.notEnoughRoom(needed: 105 * gb, free: 20 * gb, volume: "T7", inPlace: false), encrypted: false)
        #expect(beside.hasPrefix("not enough room on T7: this restore needs about 105 GB free and there is 20 GB."), "\(beside)")
        #expect(beside.contains("Nothing was written"))
        let inPlace = RestoreFailureText.restoreMessage(RestoreError.notEnoughRoom(needed: 105 * gb, free: 20 * gb, volume: "Macintosh HD", inPlace: true), encrypted: false)
        #expect(inPlace.contains("to restore in place") && inPlace.contains("Trash") && inPlace.contains("Nothing was changed"), "\(inPlace)")
        let recovery = RestoreFailureText.recoveryMessage(RestoreError.notEnoughRoom(needed: 105 * gb, free: 20 * gb, volume: "T7", inPlace: false), encrypted: false)
        #expect(recovery.contains("105 GB") && recovery.contains("20 GB"), "\(recovery)")
    }

    // A drive with less room than the archive itself is refused before a byte is
    // read: no checksum pass, no open, nothing written.
    @Test func aDriveSmallerThanTheArchiveIsRefusedUpFront() throws {
        let base = folder("upfront")
        defer { try? FileManager.default.removeItem(at: base) }
        let lib = base.appendingPathComponent("Lib")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: lib.appendingPathComponent("a.txt"))
        let a = try sealed(.zip, lib, to: base.appendingPathComponent("archive"))
        let dest = base.appendingPathComponent("dest")
        let stages = Stages()
        #expect(throws: RestoreError.notEnoughRoom(needed: RestoreRoom.needed(for: a.bytes), free: 1_000,
                                                   volume: RestoreRoom.volumeName(for: dest), inPlace: false)) {
            try RestoreEngine(freeSpace: { _ in 1_000 }).restore(a, to: dest, onStage: { stages.add($0) })
        }
        #expect(stages.all.isEmpty, "\(stages.all)")
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    // An archive compresses: the library inside can need far more than the archive
    // takes. Once it is open, the library itself is measured; the refusal comes
    // before the copy, and the archive is closed.
    @Test func aLibraryBiggerThanItsArchiveIsMeasuredOnceOpen() throws {
        let base = folder("measured")
        defer { try? FileManager.default.removeItem(at: base) }
        let lib = base.appendingPathComponent("Lib")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try Data(count: 8 * 1024 * 1024).write(to: lib.appendingPathComponent("zeros.bin"))   // compresses to almost nothing
        for kind in [SealedArchiveEngine.Sealed.dmg, .zip] {
            let a = try sealed(kind, lib, to: base.appendingPathComponent("archive-\(kind)"))
            #expect(a.bytes < 1024 * 1024)
            let dest = base.appendingPathComponent("dest-\(kind)")
            let free = RestoreRoom.needed(for: a.bytes)            // passes the check up front
            var thrown: Error?
            do { try RestoreEngine(freeSpace: { _ in free }).restore(a, to: dest) } catch { thrown = error }
            guard case .notEnoughRoom(let needed, let had, _, false)? = thrown as? RestoreError else {
                Issue.record("\(kind): expected a refusal, got \(String(describing: thrown))"); continue
            }
            #expect(needed >= RestoreRoom.needed(for: 8 * 1024 * 1024) && had == free, "\(kind): \(needed) \(had)")
            #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("Lib").path), "\(kind)")
            #expect(!attachedImages().contains(a.dir.path), "\(kind): the archive was left attached")
        }
    }

    @Test func enoughRoomRestoresAsBefore() throws {
        let base = folder("room")
        defer { try? FileManager.default.removeItem(at: base) }
        let lib = base.appendingPathComponent("Lib")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: lib.appendingPathComponent("a.txt"))
        let a = try sealed(.zip, lib, to: base.appendingPathComponent("archive"))
        let got = try RestoreEngine(freeSpace: { _ in RestoreRoom.needed(for: 64 * 1024 * 1024) })
            .restore(a, to: base.appendingPathComponent("dest"))
        #expect(try String(contentsOf: got.appendingPathComponent("a.txt"), encoding: .utf8) == "hello")
    }

    // MARK: alongside

    @Test func alongsideNamesKeepAPackageExtensionLast() throws {
        let dir = folder("names")
        defer { try? FileManager.default.removeItem(at: dir) }
        func make(_ name: String) throws { try FileManager.default.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: true) }
        #expect(RestoreNames.alongside("Photos Library.photoslibrary", in: dir).lastPathComponent == "Photos Library (2).photoslibrary")
        try make("Photos Library (2).photoslibrary")
        #expect(RestoreNames.alongside("Photos Library.photoslibrary", in: dir).lastPathComponent == "Photos Library (3).photoslibrary")
        #expect(RestoreNames.alongside("Thesis.v2", in: dir).lastPathComponent == "Thesis.v2 (2)")
        #expect(RestoreNames.alongside("Client Work, 2026", in: dir).lastPathComponent == "Client Work, 2026 (2)")
        // a broken link takes the name too
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("Music (2)").path, withDestinationPath: "/nowhere")
        #expect(RestoreNames.alongside("Music", in: dir).lastPathComponent == "Music (3)")
    }

    // Restored twice to the same folder: refused the second time unless asked to go
    // alongside, when it lands beside the first under a new name, whole.
    @Test(arguments: [SealedArchiveEngine.Sealed.dmg, .zip])
    func aClashCanBeRestoredAlongside(_ kind: SealedArchiveEngine.Sealed) throws {
        let base = folder("clash")
        defer { try? FileManager.default.removeItem(at: base) }
        let lib = base.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: lib.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("main".utf8).write(to: lib.appendingPathComponent("src/main.swift"))
        let a = try sealed(kind, lib, to: base.appendingPathComponent("archive"))
        let dest = base.appendingPathComponent("dest")
        let first = try RestoreEngine().restore(a, to: dest)
        try Data("mine".utf8).write(to: first.appendingPathComponent("src/main.swift"))      // the one there is changed
        #expect(throws: RestoreError.destinationExists(first.path)) { try RestoreEngine().restore(a, to: dest) }
        let second = try RestoreEngine().restore(a, to: dest, onClash: .alongside)
        #expect(second.lastPathComponent == "Projects (2)")
        #expect(try String(contentsOf: second.appendingPathComponent("src/main.swift"), encoding: .utf8) == "main")
        #expect(try String(contentsOf: first.appendingPathComponent("src/main.swift"), encoding: .utf8) == "mine", "the one there was touched")
    }
}
