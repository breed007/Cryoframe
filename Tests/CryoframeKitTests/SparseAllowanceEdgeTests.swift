//
//  SparseAllowanceEdgeTests.swift
//  CryoframeKitTests
//
//  copyWithHoles punches out each hole APFS filled in before a range of data, but
//  not the hole after the last one. APFS fills a trailing hole of up to about
//  16 MiB too (measured on macOS 26), so a sparse file with a little data and a
//  hole of just over 16 MiB after it is copied at its full length: more than the
//  library's room plus an eighth plus 16 MiB, so not current, written again and
//  read back on every run.
//

import Testing
import Foundation
@testable import CryoframeKit

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-allow-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

private func onDisk(_ path: String) -> Int64 { var st = stat(); return lstat(path, &st) == 0 ? Int64(st.st_blocks) * 512 : -1 }

@Suite(.serialized) struct SparseAllowanceEdgeTests {
    // 16 MiB + 8 KiB long, 4 KiB of data at the start and a hole to the end.
    @Test func aTrailingHoleIsPunchedOutOfTheCopy() throws {
        let base = folder("tail"); defer { try? FileManager.default.removeItem(at: base) }
        let from = base.appendingPathComponent("disk.img").path, to = base.appendingPathComponent("copy.img").path
        let length: Int64 = (16 << 20) + 8192
        let fd = open(from, O_RDWR | O_CREAT | O_TRUNC, 0o644)
        try #require(fd >= 0)
        var block = [UInt8](repeating: 7, count: 1 << 20)
        var at: Int64 = 0
        while at < length {
            let n = Int(min(Int64(block.count), length - at))
            try #require(pwrite(fd, &block, n, off_t(at)) == n)
            at += Int64(n)
        }
        fsync(fd)
        var hole = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: 4096, fp_length: off_t(length - 4096))
        try #require(fcntl(fd, F_PUNCHHOLE, &hole) == 0)
        fsync(fd)
        var st = stat()
        try #require(fstat(fd, &st) == 0)
        close(fd)
        try #require(MirrorCopy.isSparse(from, st), "the library file isn't sparse: \(onDisk(from))")

        try MirrorCopy.copyWithHoles(from, to, st)
        var c = stat()
        try #require(lstat(to, &c) == 0)
        #expect(onDisk(to) <= onDisk(from) + (1 << 20), "library \(onDisk(from)) bytes on disk, copy \(onDisk(to))")
        #expect(MirrorCopy.sparseCopyIsCurrent(c, of: st), "the copy it just made isn't current: written again every run")
        #expect(try Data(contentsOf: URL(fileURLWithPath: from)) == Data(contentsOf: URL(fileURLWithPath: to)))
    }
}
