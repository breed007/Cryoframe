//
//  MirrorSparseTests.swift
//  CryoframeKitTests
//
//  A live mirror of a library holding a sparse file (a virtual machine's disk).
//  Measured on macOS 26.7: rsync without -S writes a 1 GiB sparse file out whole
//  into the mirror's image, 1 GB of bands for 4 KB of data, where the room check
//  and the image's cap counted only what the file takes on disk.
//
//  With -S, the openrsync of macOS 15 leaves a file that ends in zeros short: the
//  zeros are skipped over as a hole, and the file is never extended to its size
//  (CI's macOS 15 runner: every all-zero and zero-tailed file read back "has the
//  wrong size or date"; macOS 26's openrsync gets it right). A copier that does the
//  same stands in for it here.
//

import Testing
import Foundation
@testable import CryoframeKit

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-msparse-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

/// the last byte of `path` that isn't zero, plus one (0 for a file of zeros)
private func dataEnd(_ path: String) -> Int {
    guard let d = FileManager.default.contents(atPath: path) else { return 0 }
    return (d.lastIndex { $0 != 0 }).map { $0 + 1 } ?? 0
}

/// rsync as the openrsync of macOS 15 runs it with -S: every file it writes that ends
/// in zeros is left ending at its last byte of data, dated when that happened
private func syncLikeMacOS15(_ src: URL, into next: URL) throws {
    let runner = ProcessCommandRunner()
    try MirrorCopy.sync(src, into: next, runner: runner) { cmd in
        let r = try runner.run(cmd.tool, cmd.args, stdin: nil)
        guard r.ok else { throw ArchiveError.toolFailed(tool: cmd.tool, status: r.status, stderr: r.stderr) }
        guard let walker = FileManager.default.enumerator(atPath: next.path) else { return }
        while let rel = walker.nextObject() as? String {
            let path = next.appendingPathComponent(rel).path
            var st = stat()
            guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size > 0 else { continue }
            let end = dataEnd(path)
            guard end < Int(st.st_size) else { continue }
            chmod(path, (st.st_mode & 0o7777) | S_IWUSR)
            _ = truncate(path, off_t(end))
            chmod(path, st.st_mode & 0o7777)
        }
    }
}

@Suite(.serialized) struct MirrorSparseTests {

    // Files that end in zeros, or are nothing but zeros, come out of a copier that
    // leaves their zero tails off (macOS 15's openrsync) at their full size and date,
    // byte for byte, and still sparse. Each way the sync runs: nothing read-only, a
    // read-only file (a second pass), and one whose name holds a backslash.
    @Test(arguments: ["plain", "readonly", "backslash"])
    func filesEndingInZerosAreWholeWhateverTheCopierLeftOff(_ variant: String) throws {
        let base = folder("tail-\(variant)")
        defer {
            _ = try? ProcessCommandRunner().run("/bin/chmod", ["-R", "u+rwx", base.path])
            try? FileManager.default.removeItem(at: base)
        }
        let lib = base.appendingPathComponent("Lib"), next = base.appendingPathComponent("copy")
        for d in [lib.appendingPathComponent("disks"), next] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        func random(_ n: Int) -> Data { var d = Data(count: n); d.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, n) }; return d }
        try (random(65_536) + Data(count: 1 << 20)).write(to: lib.appendingPathComponent("tail-zeros.bin"))
        try Data(count: (1 << 20) + 17).write(to: lib.appendingPathComponent("all-zeros.bin"))
        try random(100_000).write(to: lib.appendingPathComponent("dense.bin"))
        let vm = lib.appendingPathComponent("disks/disk.img")
        try #require(FileManager.default.createFile(atPath: vm.path, contents: Data("boot".utf8)))
        let fh = try FileHandle(forWritingTo: vm); try fh.truncate(atOffset: 64 << 20); try fh.close()
        if variant != "plain" {
            let name = variant == "backslash" ? "old\\key.bin" : "locked.bin"
            let locked = lib.appendingPathComponent(name)
            try (random(4096) + Data(count: 200_000)).write(to: locked)
            #expect(chmod(locked.path, 0o444) == 0)
        }
        try syncLikeMacOS15(lib, into: next)
        let found = try MirrorCopy.structure(of: next, against: lib, previous: nil, control: nil)
        #expect(found.count == 0, "\(variant): \(found.examples)")
        for rel in ["tail-zeros.bin", "all-zeros.bin", "dense.bin", "disks/disk.img"] {
            #expect(FileManager.default.contents(atPath: lib.appendingPathComponent(rel).path)
                    == FileManager.default.contents(atPath: next.appendingPathComponent(rel).path), "\(variant): \(rel) differs")
        }
        var st = stat()
        #expect(lstat(next.appendingPathComponent("disks/disk.img").path, &st) == 0 && st.st_blocks * 512 < 8 << 20,
                "\(variant): the disk's hole was written out")
    }

    @Test func aSparseFileStaysSparseInTheMirror() throws {
        let base = folder("vm")
        defer { try? FileManager.default.removeItem(at: base) }
        let lib = base.appendingPathComponent("VMs")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        let disk = lib.appendingPathComponent("disk.img")
        try #require(FileManager.default.createFile(atPath: disk.path, contents: Data("boot".utf8)))
        let fh = try FileHandle(forWritingTo: disk)
        try fh.truncate(atOffset: 1 << 30)
        try fh.close()
        let out = base.appendingPathComponent("mirror")
        let engine = SparseBundleMirrorEngine(sizeGB: 4, mountBase: base)
        _ = try engine.archive(ArchiveSource(name: "VMs", root: lib), to: out)
        // the VM writes a little, far into its disk
        let w = try FileHandle(forWritingTo: disk)
        try w.seek(toOffset: 700 << 20)
        try w.write(contentsOf: Data("written".utf8))
        try w.close()
        _ = try engine.archive(ArchiveSource(name: "VMs", root: lib), to: out)
        let held = Checksum.byteSize(of: out.appendingPathComponent("VMs.sparsebundle"))
        #expect(held < 200 << 20, "the mirror's image holds \(held >> 20) MB for a 1 GiB file with 8 KB in it")
        let got = try RestoreEngine().restore(try #require(RestoreDiscovery.archive(at: out)), to: base.appendingPathComponent("dest"))
        let back = try FileHandle(forReadingFrom: got.appendingPathComponent("disk.img"))
        defer { try? back.close() }
        #expect(try back.read(upToCount: 4) == Data("boot".utf8))
        try back.seek(toOffset: 700 << 20)
        #expect(try back.read(upToCount: 7) == Data("written".utf8))
        #expect(try back.seekToEnd() == 1 << 30)
    }
}
