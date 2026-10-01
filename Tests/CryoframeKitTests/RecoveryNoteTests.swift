//
//  RecoveryNoteTests.swift
//  CryoframeKitTests
//
//  The note on how to restore without Cryoframe: what it says for each format,
//  that it holds no secrets or outside paths, that nothing mistakes it for a
//  library, that it is only rewritten when it changes, and that a note which
//  can't be written never fails a run.
//

import Testing
import Foundation
@testable import CryoframeKit

private let hdiutil = "/usr/bin/hdiutil"

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-note-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

private func archive(_ name: String, _ format: ArchiveFormat, version: Date?, parts: Int = 1, encrypted: Bool = false,
                     in dest: URL) throws -> URL {
    var dir = dest.appendingPathComponent(name)
    if let version { dir = dir.appendingPathComponent(VersionStamp.string(version)) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let ext = format == .sealedDMG ? "dmg" : format == .sealedZip ? "zip" : "sparsebundle"
    let names = parts == 1 ? ["\(name).\(ext)"] : (0..<parts).map { "\(name).\(ext).part.\(String(format: "%03d", $0))" }
    for n in names { try Data("x".utf8).write(to: dir.appendingPathComponent(n)) }
    let manifest = VerificationManifest(format: format, artifacts: names.map { ArtifactDigest(name: $0, size: 1, sha256: "00") },
                                        encrypted: encrypted ? true : nil)
    try ArchiveManifest.write(manifest, toDir: dir)
    return dir
}

@Suite(.serialized) struct RecoveryNoteTests {

    @Test func theNoteDescribesEachLibraryAndOnlyTheFormatsThere() throws {
        let dest = folder("text")
        defer { try? FileManager.default.removeItem(at: dest) }
        let d1 = Date(timeIntervalSince1970: 1_790_000_000), d2 = d1.addingTimeInterval(86_400)
        _ = try archive("Photos", .sealedDMG, version: d1, encrypted: true, in: dest)
        _ = try archive("Photos", .sealedDMG, version: d2, encrypted: true, in: dest)
        _ = try archive("Projects", .liveMirror, version: nil, in: dest)
        let text = RecoveryNote.text(for: RestoreDiscovery.scan(dest))
        #expect(text.contains("Photos - sealed disk image (.dmg), encrypted"), "\(text)")
        #expect(text.contains("2 versions") && text.contains("Photos/\(VersionStamp.string(d2))/"), "\(text)")
        #expect(text.contains("Projects - live mirror (.sparsebundle)") && text.contains("Projects.sparsebundle"))
        #expect(text.contains("TO OPEN A SEALED DISK IMAGE") && text.contains("TO OPEN A LIVE MIRROR"))
        #expect(!text.contains("TO OPEN A SEALED ZIP") && !text.contains("SPLIT ARCHIVES"))
        #expect(text.contains("shasum -a 256") && text.contains("cryoframe-manifest.json"))
        #expect(text.contains("ENCRYPTED BACKUPS") && text.contains("recovery file"))
        // nothing from outside the folder, and nothing but plain text
        #expect(!text.contains(dest.path) && !text.contains(NSHomeDirectory()))
        #expect(!text.replacingOccurrences(of: "github.com/breed007/Cryoframe", with: "").contains(NSUserName()))
        #expect(text.unicodeScalars.allSatisfy { $0.isASCII }, "not plain ASCII")
    }

    @Test func splitZipsAndAnEmptyFolderAreExplained() throws {
        let dest = folder("split")
        defer { try? FileManager.default.removeItem(at: dest) }
        #expect(RecoveryNote.text(for: []).contains("Nothing yet"))
        _ = try archive("Mail", .sealedZip, version: Date(timeIntervalSince1970: 1_790_000_000), parts: 3, in: dest)
        let text = RecoveryNote.text(for: RestoreDiscovery.scan(dest))
        #expect(text.contains("TO OPEN A SEALED ZIP") && text.contains("SPLIT ARCHIVES") && text.contains("split into 3 parts"), "\(text)")
        #expect(text.contains("ls \"NAME.zip.part.\"* | sort -V | while IFS= read -r p; do cat \"$p\"; done"), "\(text)")
    }

    // Discovery, retention and the checks look for folders with a manifest: the
    // note at the top is none of those, and a run's pruning leaves it be.
    @Test func nothingMistakesTheNoteForALibrary() throws {
        let dest = folder("ignored")
        defer { try? FileManager.default.removeItem(at: dest) }
        let d1 = Date(timeIntervalSince1970: 1_790_000_000)
        _ = try archive("Photos", .sealedDMG, version: d1, in: dest)
        #expect(RecoveryNote.write(in: dest) == nil)
        let note = dest.appendingPathComponent(RecoveryNote.fileName)
        #expect(FileManager.default.fileExists(atPath: note.path))
        let found = RestoreDiscovery.scan(dest)
        #expect(found.count == 1 && RestoreDiscovery.libraries(in: found) == ["Photos"])
        let photos = ContentType.genericFolder(id: "p", displayName: "Photos", path: .absolute("/nowhere"))
        #expect(JobExecutor.pruneVersions(target: dest, libraries: [photos], policy: .keepLast(1), confirmed: { _, _ in true }).isEmpty)
        #expect(FileManager.default.fileExists(atPath: note.path))
    }

    // Rewritten only when what it says changes; never written where the folder
    // isn't (a drive that's away leaves an empty mount point on the startup disk).
    @Test func theNoteIsWrittenOnlyWhenItChangesAndNeverMakesTheFolder() throws {
        let dest = folder("changes")
        defer { try? FileManager.default.removeItem(at: dest) }
        _ = try archive("Photos", .sealedDMG, version: Date(timeIntervalSince1970: 1_790_000_000), in: dest)
        #expect(RecoveryNote.write(in: dest) == nil)
        let note = dest.appendingPathComponent(RecoveryNote.fileName)
        let first = try FileManager.default.attributesOfItem(atPath: note.path)[.modificationDate] as? Date
        let inode = try FileManager.default.attributesOfItem(atPath: note.path)[.systemFileNumber] as? Int
        #expect(RecoveryNote.write(in: dest) == nil)
        #expect(try FileManager.default.attributesOfItem(atPath: note.path)[.modificationDate] as? Date == first)
        #expect(try FileManager.default.attributesOfItem(atPath: note.path)[.systemFileNumber] as? Int == inode, "rewritten with nothing changed")
        _ = try archive("Mail", .sealedZip, version: Date(timeIntervalSince1970: 1_790_000_000), in: dest)
        #expect(RecoveryNote.write(in: dest) == nil)
        #expect(try String(contentsOf: note, encoding: .utf8).contains("Mail - sealed zip"))
        let away = dest.appendingPathComponent("not-mounted")
        #expect(RecoveryNote.write(in: away) != nil)
        #expect(!FileManager.default.fileExists(atPath: away.path))
    }

    // A whole run writes the note in its destination; one that can't be written
    // (a folder sits where it goes) is logged and the run still succeeds.
    @Test(arguments: [false, true])
    func aRunWritesTheNoteAndNeverFailsOverIt(_ blocked: Bool) async throws {
        let base = folder("run")
        let mnt = base.appendingPathComponent("vol")
        try FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)
        let made = try ProcessCommandRunner().run(hdiutil, ["create", "-size", "20m", "-fs", "HFS+", "-volname", "Src",
                                                            base.appendingPathComponent("src.dmg").path])
        try #require(made.ok, "\(made.stderr)")
        let attached = try DiskImageGate.serialized {
            try ProcessCommandRunner().runRetryingBusy(hdiutil, ["attach", base.appendingPathComponent("src.dmg").path,
                                                                 "-mountpoint", mnt.path, "-nobrowse", "-owners", "on"])
        }
        try #require(attached.ok && MountPoint.isMounted(mnt), "\(attached.stderr)")
        defer {
            MountPoint.detach(mnt, runner: ProcessCommandRunner())
            try? FileManager.default.removeItem(at: base)
        }
        let lib = mnt.appendingPathComponent("Papers")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: lib.appendingPathComponent("a.txt"))
        let dest = base.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let note = dest.appendingPathComponent(RecoveryNote.fileName)
        if blocked { try FileManager.default.createDirectory(at: note, withIntermediateDirectories: true) }
        let papers = ContentType.genericFolder(id: "papers", displayName: "Papers", path: .absolute(lib.path))
        let job = BackupJob(name: "Papers", libraries: [papers], target: .localVolume(id: "d", name: "Dest", dir: dest),
                            format: .sealedZip, frequency: .manual, createdAt: Date(timeIntervalSince1970: 0))
        let exec = JobExecutor(helper: FakePrivilegedHelper(), detector: FakeProcessDetector(),
                               scratchBase: base.appendingPathComponent("scratch"))
        let outcome = try await exec.run(job, ownerUID: getuid(), now: Date())
        guard case .finished(let results, _) = outcome, case .completed? = results.first else {
            Issue.record("the run didn't succeed: \(outcome)"); return
        }
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: note.path, isDirectory: &isDir))
        if blocked {
            #expect(isDir.boolValue, "what stood in the way was replaced")
        } else {
            let text = (try? String(contentsOf: note, encoding: .utf8)) ?? ""
            #expect(!isDir.boolValue && text.contains("Papers - sealed zip"), "\(text)")
        }
    }
}

// Split parts are joined in the order they were made, past a thousand of them too,
// and the note's join step names the format the parts are.
@Test func partsJoinInTheOrderTheyWereSplit() {
    let numbered = (0..<1002).map { "L.dmg.part." + String(format: "%03d", $0) }
    #expect(numbered.shuffled().sorted(by: ArchiveReader.partOrder) == numbered)
    let lettered = ["L.zip.part.aa", "L.zip.part.ab", "L.zip.part.zz", "L.zip.part.aaa"]
    #expect(lettered.reversed().sorted(by: ArchiveReader.partOrder) == lettered)
    let zips = [RestorableArchive(dir: URL(fileURLWithPath: "/x/Mail/2026-01-01-000000"), libraryName: "Mail", format: .sealedZip,
                                  bytes: 3, artifactNames: ["Mail.zip.part.aa", "Mail.zip.part.ab"],
                                  version: Date(timeIntervalSince1970: 1_767_225_600))]
    let text = RecoveryNote.text(for: zips)
    #expect(text.contains(#"ls "NAME.zip.part."* | sort -V | while IFS= read -r p; do cat "$p"; done > ~/Desktop/"NAME.zip""#), "\(text)")
    #expect(!text.contains("NAME.dmg.part"))
}
