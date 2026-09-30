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

/// rsync as the openrsync of macOS 15 also runs it with -S: every file with holes it
/// writes lands dense (CI's runner: a 1 GiB file holding 8 KB took 937 MB of the image)
private func syncWritingSparseFilesDense(_ src: URL, into next: URL) throws {
    let runner = ProcessCommandRunner()
    try MirrorCopy.sync(src, into: next, runner: runner) { cmd in
        let r = try runner.run(cmd.tool, cmd.args, stdin: nil)
        guard r.ok else { throw ArchiveError.toolFailed(tool: cmd.tool, status: r.status, stderr: r.stderr) }
        guard let walker = FileManager.default.enumerator(atPath: next.path) else { return }
        while let rel = walker.nextObject() as? String {
            let path = next.appendingPathComponent(rel).path
            var st = stat()
            guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, off_t(st.st_blocks) * 512 < st.st_size,
                  let data = FileManager.default.contents(atPath: path) else { continue }
            chmod(path, (st.st_mode & 0o7777) | S_IWUSR)
            let fd = open(path, O_WRONLY)
            _ = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, data.count, 0) }
            var times = [st.st_atimespec, st.st_mtimespec]
            _ = futimens(fd, &times)
            close(fd)
            chmod(path, st.st_mode & 0o7777)
        }
    }
}

@Suite(.serialized) struct MirrorSparseTests {

    // Sparse files come out of a copier that writes them dense (macOS 15's openrsync)
    // still sparse, whole and dated right, and a dense copy an earlier run left is
    // made sparse again. Each way the sync runs: nothing read-only, a read-only file
    // (a second pass), and a read-only file whose name holds a backslash.
    @Test(arguments: ["plain", "readonly", "backslash"])
    func sparseFilesStaySparseWhateverTheCopierWrites(_ variant: String) throws {
        let base = folder("dense-\(variant)")
        defer {
            _ = try? ProcessCommandRunner().run("/bin/chmod", ["-R", "u+rwx", base.path])
            try? FileManager.default.removeItem(at: base)
        }
        let lib = base.appendingPathComponent("Lib"), next = base.appendingPathComponent("copy")
        for d in [lib.appendingPathComponent("disks"), next] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        func sparseFile(_ url: URL, _ length: UInt64, data: [(UInt64, String)]) throws {
            try #require(FileManager.default.createFile(atPath: url.path, contents: nil))
            let fh = try FileHandle(forWritingTo: url)
            try fh.truncate(atOffset: length)
            for (at, text) in data { try fh.seek(toOffset: at); try fh.write(contentsOf: Data(text.utf8)) }
            try fh.close()
        }
        let vm = lib.appendingPathComponent("disks/disk.img")
        try sparseFile(vm, 256 << 20, data: [(0, "boot"), (100 << 20, "middle")])                 // ends in a hole
        try sparseFile(lib.appendingPathComponent("tail.img"), 64 << 20, data: [((64 << 20) - 4, "end!")])
        try Data("small".utf8).write(to: lib.appendingPathComponent("notes.txt"))
        if variant != "plain" {
            let locked = lib.appendingPathComponent(variant == "backslash" ? "old\\disk.img" : "locked.img")
            try sparseFile(locked, 128 << 20, data: [(4096, "key")])
            try FileManager.default.createDirectory(at: lib.appendingPathComponent("x"), withIntermediateDirectories: true)
            try Data("plain".utf8).write(to: lib.appendingPathComponent(variant == "backslash" ? "x/a\\b.txt" : "x/ro.txt"))
            #expect(chmod(locked.path, 0o444) == 0)
            #expect(chmod(lib.appendingPathComponent(variant == "backslash" ? "x/a\\b.txt" : "x/ro.txt").path, 0o444) == 0)
        }
        func checkCopy(_ when: String) throws {
            let found = try MirrorCopy.structure(of: next, against: lib, previous: nil, control: nil)
            #expect(found.count == 0, "\(variant), \(when): \(found.examples)")
            var held: off_t = 0
            for rel in (FileManager.default.subpaths(atPath: next.path) ?? []) {
                var st = stat()
                if lstat(next.appendingPathComponent(rel).path, &st) == 0, st.st_mode & S_IFMT == S_IFREG { held += off_t(st.st_blocks) * 512 }
            }
            #expect(held < 8 << 20, "\(variant), \(when): the copy takes \(held >> 20) MB for about 20 KB of data")
            for rel in ["disks/disk.img", "tail.img"] {
                #expect(FileManager.default.contents(atPath: lib.appendingPathComponent(rel).path)
                        == FileManager.default.contents(atPath: next.appendingPathComponent(rel).path), "\(variant), \(when): \(rel) differs")
            }
        }
        try syncWritingSparseFilesDense(lib, into: next)
        try checkCopy("first run")
        // an earlier run's dense copy, as rsync left it on macOS 15 before this
        let fd = open(next.appendingPathComponent("disks/disk.img").path, O_WRONLY)
        let zeros = Data(count: 1 << 20)
        for mb in stride(from: 1, to: 64, by: 1) where mb != 100 { _ = zeros.withUnsafeBytes { pwrite(fd, $0.baseAddress, zeros.count, off_t(mb) << 20) } }
        var times = [timespec(), timespec()]; var st = stat(); lstat(vm.path, &st); times = [st.st_atimespec, st.st_mtimespec]
        _ = futimens(fd, &times); close(fd)
        try syncWritingSparseFilesDense(lib, into: next)
        try checkCopy("after a dense copy")
    }

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
