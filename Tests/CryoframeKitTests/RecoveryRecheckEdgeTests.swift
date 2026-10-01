//
//  RecoveryRecheckEdgeTests.swift
//  CryoframeKitTests
//
//  The milestone 4 fixes at their edges: the key check against every way a disk
//  can already be open (a no-mount attach, a Finder-style mount, a mirror opened
//  read-only, a disk whose attacher is gone), damaged images, sparse files kept
//  sparse in the mirror and coming back byte for byte, the startup disk's room
//  for a zip of many small files, and the report's word list against names in
//  other scripts and numbers that identify someone.
//

import Testing
import Foundation
@testable import CryoframeKit

private let hdiutil = "/usr/bin/hdiutil"

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-recheck-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

private func encryptedDMG(passphrase: String, base: URL) throws -> RestorableArchive {
    let lib = base.appendingPathComponent("src/Documents")
    try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
    try Data("inside".utf8).write(to: lib.appendingPathComponent("a.txt"))
    let dir = base.appendingPathComponent("dest/Documents")
    let result = try SealedArchiveEngine(.dmg, passphrase: passphrase).archive(ArchiveSource(name: "Documents", root: lib), to: dir)
    try ArchiveManifest.write(try ArchiveManifest.build(for: result, encrypted: true), toDir: dir)
    return try #require(RestoreDiscovery.archive(at: dir))
}

/// the first device of an attach's output
private func device(_ r: CommandResult) -> String? {
    r.stdout.split(whereSeparator: \.isWhitespace).first(where: { $0.hasPrefix("/dev/disk") }).map(String.init)
}

private func sha(_ url: URL) -> String? { try? Checksum.sha256(of: url) }

private func report(error: String) -> String {
    let dest = Target.localVolume(id: "t7", name: "Backups", dir: URL(fileURLWithPath: "/Volumes/T7/Backups"))
    let work = ContentType.genericFolder(id: "w", displayName: "Work", path: .absolute("/Users/jdoe/Work"))
    let job = BackupJob(name: "Nightly", libraries: [work], target: dest, format: .liveMirror(sizeGB: 1),
                        frequency: .daily(hour: 2, minute: 0), createdAt: Date(timeIntervalSince1970: 0))
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let run = RunRecord(id: "r", jobID: job.id, jobName: job.name, startedAt: now.addingTimeInterval(-60), finishedAt: now,
                        trigger: "scheduled", outcome: .failed, summary: "Work failed",
                        libraries: [LibraryOutcome(from: .failed(library: "Work", destination: "Backups", error: error))],
                        bytes: 0, warning: nil)
    let input = DiagnosticsReport.Input(appVersion: "1.6.0 (160)", helperVersion: "1.6.0", agentState: "on", macOS: "26.7",
                                        hardware: "Mac14,2", jobs: [job], runs: [run], health: [], settings: [], now: now)
    return DiagnosticsReport.build(input, redactor: DiagnosticsReport.redactor(for: input, home: "/Users/jdoe", userName: "jdoe",
                                                                               fullName: "Jane Doe", hostName: "Jane's MacBook Pro"))
}

@Suite(.serialized) struct RecoveryRecheckEdgeTests {

    // MARK: the key check and disks already open

    // Held three ways: attached without a mount (as a key check or a script does,
    // and left so when its attacher is gone), mounted read-only (a double-click in
    // Finder), and a mirror's image mounted read-only (a drill of a mirror). No
    // passphrase is called good while it is held, and the holder keeps its disk.
    @Test(arguments: ["no mount", "mounted", "mirror mounted"])
    func aDiskAlreadyOpenIsNeitherTrustedNorTakenAway(_ how: String) throws {
        let base = folder("held")
        let mnt = base.appendingPathComponent("finder")
        var held: String?
        var image: URL?
        defer {
            if let held { _ = try? ProcessCommandRunner().run(hdiutil, ["detach", "-force", held]) }
            // and whatever else attached this scratch image, so nothing outlives its folder
            if let image {
                for d in MirrorMounts.attachedDevices(of: image, runner: ProcessCommandRunner()).prefix(1) {
                    _ = try? ProcessCommandRunner().run(hdiutil, ["detach", "-force", d])
                }
            }
            try? FileManager.default.removeItem(at: base)
        }
        let a: RestorableArchive
        if how == "mirror mounted" {
            let lib = base.appendingPathComponent("src/Documents")
            try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
            try Data("inside".utf8).write(to: lib.appendingPathComponent("a.txt"))
            let out = base.appendingPathComponent("dest/Documents")
            _ = try SparseBundleMirrorEngine(sizeGB: 1, passphrase: "right", mountBase: base).archive(ArchiveSource(name: "Documents", root: lib), to: out)
            a = try #require(RestoreDiscovery.archive(at: out))
        } else {
            a = try encryptedDMG(passphrase: "right", base: base)
        }
        image = a.dir.appendingPathComponent(a.artifactNames[0])
        try FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)
        let args = how == "no mount" ? ["attach", "-readonly", "-nomount", "-stdinpass", image!.path]
                                     : ["attach", "-readonly", "-nobrowse", "-stdinpass", "-mountpoint", mnt.path, image!.path]
        // A system process sometimes attaches a freshly written image itself (writable,
        // no mount point, for minutes; seen in full-suite runs) and this attach then
        // says "Resource temporarily unavailable". Wait a bounded time for it.
        var attached = try ProcessCommandRunner().run(hdiutil, args, stdin: Data("right".utf8))
        let until = ProcessInfo.processInfo.systemUptime + 60
        while !attached.ok, attached.stderr.contains("temporarily unavailable"), ProcessInfo.processInfo.systemUptime < until {
            Thread.sleep(forTimeInterval: 2)
            attached = try ProcessCommandRunner().run(hdiutil, args, stdin: Data("right".utf8))
        }
        try #require(attached.ok, "\(attached.stderr)")
        held = device(attached)
        try #require(held != nil)

        for pass in ["wrong", "right"] {
            let proof = KeyCheck().check(a, passphrase: pass)
            #expect(proof != .opens, "\(how), \(pass): called good while it was open elsewhere")
            #expect(MirrorMounts.allDevices(runner: ProcessCommandRunner()).contains(held!), "\(how), \(pass): the holder's disk was taken away")
            if how != "no mount" { #expect(MountPoint.isMounted(mnt), "\(how), \(pass): the holder's mount went") }
        }
        #expect(KeyCheck().firstOpening(a, candidates: ["wrong", "right"]).proof != .opens)
    }

    // A header damaged so the image attaches raw with any passphrase: damaged, for
    // every candidate, and nothing left attached.
    @Test func aDamagedHeaderIsCalledDamaged() throws {
        let base = folder("header")
        defer { try? FileManager.default.removeItem(at: base) }
        let a = try encryptedDMG(passphrase: "right", base: base)
        let image = a.dir.appendingPathComponent(a.artifactNames[0])
        let fh = try FileHandle(forWritingTo: image)
        try fh.write(contentsOf: Data(count: 8))
        try fh.close()
        guard case .damaged = KeyCheck().firstOpening(a, candidates: ["wrong", "right"]).proof else {
            Issue.record("not called damaged"); return
        }
        #expect(MirrorMounts.attachedDevices(of: image, runner: ProcessCommandRunner()).isEmpty)
    }

    // MARK: sparse files in the mirror

    // With -S, zeros become holes in the copy. Files that end in zeros, are all
    // zeros, or are mostly a hole with data here and there come back byte for byte,
    // also after a second run that changes and shortens them; the image stays small.
    @Test func sparseAndZeroFilledFilesMirrorAndRestoreExactly() throws {
        let base = folder("sparse")
        defer { try? FileManager.default.removeItem(at: base) }
        let lib = base.appendingPathComponent("VMs")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        func random(_ n: Int) -> Data { var d = Data(count: n); d.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, n) }; return d }
        try (random(3 * 1024 * 1024) + Data(count: 5 * 1024 * 1024)).write(to: lib.appendingPathComponent("tail-zeros.bin"))
        try Data(count: 4 * 1024 * 1024 + 17).write(to: lib.appendingPathComponent("all-zeros.bin"))
        try random(1_234_567).write(to: lib.appendingPathComponent("dense.bin"))
        let vm = lib.appendingPathComponent("disk.img")
        try #require(FileManager.default.createFile(atPath: vm.path, contents: Data("boot".utf8)))
        func poke(_ at: UInt64, _ bytes: Data) throws {
            let fh = try FileHandle(forWritingTo: vm); try fh.seek(toOffset: at); try fh.write(contentsOf: bytes); try fh.close()
        }
        try poke(300 << 20, random(8192)); try poke((1 << 30) - 5, Data("end!!".utf8))       // 1 GiB, 8 KB of it data
        let out = base.appendingPathComponent("mirror")
        let engine = SparseBundleMirrorEngine(sizeGB: 1, mountBase: base)
        _ = try engine.archive(ArchiveSource(name: "VMs", root: lib), to: out)
        // change them: new data inside the hole, the tail cut short, the zeros grown
        try poke(700 << 20, random(4096))
        let t = try FileHandle(forWritingTo: lib.appendingPathComponent("tail-zeros.bin")); try t.truncate(atOffset: 6 * 1024 * 1024 + 3); try t.close()
        try Data(count: 6 * 1024 * 1024).write(to: lib.appendingPathComponent("all-zeros.bin"))
        _ = try engine.archive(ArchiveSource(name: "VMs", root: lib), to: out)
        let a = try #require(RestoreDiscovery.archive(at: out))
        #expect(a.bytes < 256 * 1024 * 1024, "the image holds \(a.bytes) bytes for a library of about 20 MB of data")
        let got = try RestoreEngine().restore(a, to: base.appendingPathComponent("dest"))
        for name in ["tail-zeros.bin", "all-zeros.bin", "dense.bin", "disk.img"] {
            let x = sha(lib.appendingPathComponent(name)), y = sha(got.appendingPathComponent(name))
            #expect(x != nil && x == y, "\(name) came back different")
        }
    }

    // MARK: the startup disk's room for a zip

    // A zip's uncompressed total counts bytes; unpacked, every file takes at least a
    // 4 KB block. Measured: 72,000 files of 16 bytes (and ditto's 72,000 "._" files)
    // say 12.9 MB and take 288 MB unpacked, more than the check asks for (the total
    // and 256 MB). The room asked for should cover what unpacking takes.
    @Test func theRoomAskedToUnpackAZipCoversManySmallFiles() throws {
        let base = folder("tiny")
        defer { try? FileManager.default.removeItem(at: base) }
        let lib = base.appendingPathComponent("Notes")
        for d in 0..<100 {
            let dir = lib.appendingPathComponent("d\(d)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for i in 0..<720 { try Data("0123456789abcdef".utf8).write(to: dir.appendingPathComponent("f\(i).txt")) }
        }
        let result = try SealedArchiveEngine(.zip).archive(ArchiveSource(name: "Notes", root: lib), to: base.appendingPathComponent("out"))
        let asked = try #require(ArchiveReader.unpackedSize(of: result.artifacts[0]))
        let takes = RestoreRoom.bytes(of: [lib])
        #expect(RestoreRoom.needed(for: asked) >= takes, "asks for \(RestoreRoom.needed(for: asked)) bytes to unpack what takes \(takes)")
    }

    // MARK: the report's word list

    // A name in another script, or with an accent, is split into ASCII pieces for
    // the word list, and every single letter is on it: "Noël" is "no" and "l", both
    // Cryoframe's words, so the whole name was kept, accent and all.
    @Test func namesInOtherScriptsLeaveNothingOfThemselves() {
        let text = report(error: MirrorCopyError.readBackMismatch(count: 3, examples: [
            "Noël is missing", "Inês Lé Bé isn't in the library", "写真Mail has the wrong size or date"]).localizedDescription)
        let found = ["Noël", "Inês", "Lé", "Bé", "写真"].filter { text.contains($0) }
        #expect(found.isEmpty, "\(found) in the report:\n\(text)")
    }

    // Numbers are kept (sizes, counts, times, status codes), but a file named by a
    // social security, phone or card number is named by who it is about.
    @Test func numbersThatIdentifySomeoneAreRemoved() {
        let text = report(error: MirrorCopyError.readBackMismatch(count: 3, examples: [
            "123-45-6789 is missing", "404-555-1234 isn't in the library", "4111 1111 1111 1111 has the wrong size or date"]).localizedDescription)
        let found = ["123-45-6789", "404-555-1234", "4111 1111 1111 1111"].filter { text.contains($0) }
        #expect(found.isEmpty, "\(found) in the report:\n\(text)")
        #expect(text.contains("3 items"), "the count went too")
    }
}
