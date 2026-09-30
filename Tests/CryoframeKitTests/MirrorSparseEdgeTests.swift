//
//  MirrorSparseEdgeTests.swift
//  CryoframeKitTests
//
//  Sparse files copied by Cryoframe itself, at their edges. The read-back compares
//  the bytes of every file a run wrote, and takes a file whose library size and date
//  match the previous copy's as carried over, sharing its blocks. A dense copy an
//  earlier run left (rsync on macOS 15, 1.5 included) has the library's size and
//  date, and is written again, into new blocks, to make it sparse: it must be read
//  back too, or data lost writing it (a drive filling up under the image, where
//  nothing reports an error) replaces a good copy unseen. Also: a sparse file's
//  attributes, a file that is all hole, and one that shrinks below the size that
//  makes it sparse-copied.
//

import Testing
import Foundation
@testable import CryoframeKit

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-spe-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

private func random(_ n: Int) -> Data { var d = Data(count: n); d.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, n) }; return d }

/// a file `length` long holding `data` at each offset, holes between
private func sparseFile(_ url: URL, _ length: UInt64, data: [(UInt64, Data)]) throws {
    try #require(FileManager.default.createFile(atPath: url.path, contents: nil))
    let fh = try FileHandle(forWritingTo: url)
    try fh.truncate(atOffset: length)
    for (at, d) in data { try fh.seek(toOffset: at); try fh.write(contentsOf: d) }
    try fh.close()
}

private func blocks(_ url: URL) -> off_t { var st = stat(); return lstat(url.path, &st) == 0 ? off_t(st.st_blocks) * 512 : -1 }

private func syncWithRsync(_ lib: URL, into next: URL) throws {
    let runner = ProcessCommandRunner()
    try MirrorCopy.sync(lib, into: next, runner: runner) { cmd in
        let r = try runner.run(cmd.tool, cmd.args, stdin: nil)
        guard r.ok else { throw ArchiveError.toolFailed(tool: cmd.tool, status: r.status, stderr: r.stderr) }
    }
}

@Suite(.serialized) struct MirrorSparseEdgeTests {

    // The previous copy holds the library's VM disk dense, at its exact size and
    // date. This run writes it again with its holes, into new blocks. The read-back
    // counts it carried over (size and date match the previous copy) and never reads
    // what was just written.
    @Test func aDenseCopyWrittenAgainSparseIsReadBack() throws {
        let base = folder("redo"); defer { try? FileManager.default.removeItem(at: base) }
        let lib = base.appendingPathComponent("Lib"), vol = base.appendingPathComponent("vol")
        let current = vol.appendingPathComponent("Lib"), staging = vol.appendingPathComponent(".cryoframe-staging")
        let next = staging.appendingPathComponent("Lib")
        for d in [lib, current, staging] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let vm = lib.appendingPathComponent("vm.img")
        try sparseFile(vm, 256 << 20, data: [(0, random(65_536)), (128 << 20, random(65_536))])   // (APFS fills in small ones)
        // the earlier run's dense copy: the same bytes, every one written, the same dates
        let dense = current.appendingPathComponent("vm.img")
        try Data(contentsOf: vm).write(to: dense)
        var st = stat(); lstat(vm.path, &st)
        var times = [st.st_atimespec, st.st_mtimespec]
        #expect(utimensat(AT_FDCWD, dense.path, &times, 0) == 0)
        try #require(blocks(dense) >= 256 << 20 && blocks(vm) < 8 << 20, "dense \(blocks(dense)), library \(blocks(vm))")
        let cloned = try ProcessCommandRunner().run("/bin/cp", ["-c", "-Rp", current.path, next.path], stdin: nil)
        try #require(cloned.ok, "\(cloned.stderr)")

        try syncWithRsync(lib, into: next)
        #expect(blocks(next.appendingPathComponent("vm.img")) < 8 << 20, "made sparse again: written anew")
        let found = try MirrorCopy.structure(of: next, against: lib, previous: current, control: nil)
        #expect(found.count == 0, "\(found.examples)")
        #expect(found.written.contains("vm.img"), "vm.img was written this run, and the read-back won't compare its bytes: \(found.written)")
    }

    // A sparse file carrying what a file of the user's carries: quarantine, a Finder
    // tag, another attribute, a resource fork and an access list. A file that is all
    // hole, and one with data only in its middle, beside it.
    @Test func aSparseFilesAttributesAndShapesComeThrough() throws {
        let base = folder("attrs"); defer {
            _ = try? ProcessCommandRunner().run("/bin/chmod", ["-R", "-N", base.path])
            try? FileManager.default.removeItem(at: base)
        }
        let lib = base.appendingPathComponent("Lib"), vol = base.appendingPathComponent("vol")
        let current = vol.appendingPathComponent("Lib"), staging = vol.appendingPathComponent(".cryoframe-staging")
        let next = staging.appendingPathComponent("Lib")
        for d in [lib, next] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let vm = lib.appendingPathComponent("Downloaded VM.img")
        try sparseFile(vm, 32 << 20, data: [(4096, random(8192)), ((32 << 20) - 8192, random(4096))])
        let quarantine = "0083;66f1a2b3;Safari;"
        #expect(setxattr(vm.path, "com.apple.quarantine", quarantine, quarantine.utf8.count, 0, 0) == 0)
        #expect(setxattr(vm.path, "app.cryoframe.test", "value", 5, 0, 0) == 0)
        #expect(setxattr(vm.path, "com.apple.ResourceFork", "fork data", 9, 0, 0) == 0)
        try (vm as NSURL).setResourceValue(["Red"], forKey: .tagNamesKey)
        let acl = try ProcessCommandRunner().run("/bin/chmod", ["+a", "everyone deny delete", vm.path], stdin: nil)
        #expect(acl.ok, "\(acl.stderr)")
        try sparseFile(lib.appendingPathComponent("empty.img"), 16 << 20, data: [])
        try sparseFile(lib.appendingPathComponent("middle.img"), 64 << 20, data: [(32 << 20, random(4096))])
        for rel in ["Downloaded VM.img", "empty.img", "middle.img"] {
            try #require(blocks(lib.appendingPathComponent(rel)) < 1 << 20, "\(rel) in the library isn't sparse")
        }

        try syncWithRsync(lib, into: next)
        #expect(throws: Never.self, "the read-back of the sparse files") {
            try MirrorCopy.verify(MirrorCopy.Staged(volume: vol, current: current, staging: staging, next: next), against: lib, control: nil)
        }
        let copy = next.appendingPathComponent("Downloaded VM.img")
        var buf = [UInt8](repeating: 0, count: 64)
        let n = getxattr(copy.path, "com.apple.quarantine", &buf, buf.count, 0, 0)
        #expect(n > 0 && String(decoding: buf.prefix(max(0, n)), as: UTF8.self) == quarantine, "quarantine as the library has it")
        #expect(getxattr(copy.path, "com.apple.ResourceFork", nil, 0, 0, 0) == 9)
        #expect((try? copy.resourceValues(forKeys: [.tagNamesKey]))?.tagNames == ["Red"])
        for rel in ["Downloaded VM.img", "empty.img", "middle.img"] {
            #expect(blocks(next.appendingPathComponent(rel)) < 1 << 20, "\(rel) stayed sparse")
            #expect(FileManager.default.contents(atPath: lib.appendingPathComponent(rel).path)
                    == FileManager.default.contents(atPath: next.appendingPathComponent(rel).path), "\(rel)")
        }
    }

    // A VM disk the previous copy held sparse is now small and dense in the library:
    // rsync takes it again, and it reads back.
    @Test func aSparseFileThatShrankBelowTheLimitIsCopiedByRsync() throws {
        let base = folder("shrink"); defer { try? FileManager.default.removeItem(at: base) }
        let lib = base.appendingPathComponent("Lib"), vol = base.appendingPathComponent("vol")
        let current = vol.appendingPathComponent("Lib"), staging = vol.appendingPathComponent(".cryoframe-staging")
        let next = staging.appendingPathComponent("Lib")
        for d in [lib, current, staging] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try sparseFile(current.appendingPathComponent("vm.img"), 64 << 20, data: [(0, random(4096))])
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
                                              ofItemAtPath: current.appendingPathComponent("vm.img").path)
        try random(100_000).write(to: lib.appendingPathComponent("vm.img"))
        let cloned = try ProcessCommandRunner().run("/bin/cp", ["-c", "-Rp", current.path, next.path], stdin: nil)
        try #require(cloned.ok, "\(cloned.stderr)")
        try syncWithRsync(lib, into: next)
        #expect(throws: Never.self) {
            try MirrorCopy.verify(MirrorCopy.Staged(volume: vol, current: current, staging: staging, next: next), against: lib, control: nil)
        }
    }
}
