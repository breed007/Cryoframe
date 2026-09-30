//
//  SparseCopyRoomTests.swift
//  CryoframeKitTests
//
//  What a sparse file's copy takes on disk. APFS fills in a hole of under 16 MiB
//  between two writes, so a disk image with a little data every few MiB was copied
//  at its full length, and then found "not current" and written again every run.
//

import Testing
import Foundation
@testable import CryoframeKit

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-room-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

private func onDisk(_ path: String) -> Int64 { var st = stat(); return lstat(path, &st) == 0 ? Int64(st.st_blocks) * 512 : -1 }

/// a file of `length` with 64 KiB of data every `every` bytes, and holes between
@discardableResult
private func scattered(_ path: String, length: Int64, every: Int64) throws -> stat {
    let fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0o644)
    try #require(fd >= 0)
    defer { close(fd) }
    try #require(ftruncate(fd, length) == 0)
    var chunk = [UInt8](repeating: 0, count: 65_536)
    var at: Int64 = 0
    while at < length {
        arc4random_buf(&chunk, chunk.count)
        try #require(pwrite(fd, chunk, chunk.count, off_t(at)) == chunk.count)
        let end = at + 65_536
        if at + every < length {
            var hole = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: off_t(end), fp_length: off_t(every - 65_536))
            _ = fcntl(fd, F_PUNCHHOLE, &hole)
        }
        at += every
    }
    fsync(fd)
    var st = stat()
    try #require(fstat(fd, &st) == 0)
    return st
}

@Suite(.serialized) struct SparseCopyRoomTests {
    // 256 MiB with 64 KiB every 4 MiB (a disk image's scattered file system
    // structures): the copy takes about what the library does, and is current.
    @Test func aScatteredSparseFileIsCopiedSparse() throws {
        let base = folder("scatter"); defer { try? FileManager.default.removeItem(at: base) }
        let from = base.appendingPathComponent("disk.img").path, to = base.appendingPathComponent("copy.img").path
        let st = try scattered(from, length: 256 << 20, every: 4 << 20)
        try #require(MirrorCopy.isSparse(from, st), "the library file isn't sparse: \(onDisk(from))")
        try MirrorCopy.copyWithHoles(from, to, st)
        #expect(onDisk(to) <= onDisk(from) + MirrorCopy.sparseSlack, "library \(onDisk(from)), copy \(onDisk(to))")
        var c = stat()
        try #require(lstat(to, &c) == 0)
        #expect(MirrorCopy.sparseCopyIsCurrent(c, of: st))
        #expect(try Data(contentsOf: URL(fileURLWithPath: from)) == Data(contentsOf: URL(fileURLWithPath: to)))
    }

    // A dense copy of a large sparse file (what rsync on macOS 15 wrote) still isn't
    // current, so it is made sparse again.
    @Test func aDenseCopyOfALargeSparseFileIsNotCurrent() throws {
        let base = folder("dense"); defer { try? FileManager.default.removeItem(at: base) }
        let from = base.appendingPathComponent("disk.img").path, to = base.appendingPathComponent("copy.img").path
        let st = try scattered(from, length: 256 << 20, every: 32 << 20)
        try Data(contentsOf: URL(fileURLWithPath: from)).write(to: URL(fileURLWithPath: to))
        var times = [st.st_atimespec, st.st_mtimespec]
        try #require(utimensat(AT_FDCWD, to, &times, 0) == 0)
        var c = stat()
        try #require(lstat(to, &c) == 0)
        try #require(Int64(c.st_blocks) * 512 >= 200 << 20, "the copy isn't dense: \(onDisk(to))")
        #expect(!MirrorCopy.sparseCopyIsCurrent(c, of: st))
    }
}
