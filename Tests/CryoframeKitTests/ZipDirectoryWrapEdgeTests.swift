//
//  ZipDirectoryWrapEdgeTests.swift
//  Tests for ZipDirectory.unpackedSize on the directories ditto writes past 4 GiB.
//
//  ditto writes no Zip64 records: every size and offset is the true value modulo
//  2^32. The zips here are sparse files holding only a directory built the way ditto
//  writes it, so a 9 GiB case costs a few KB on disk. The reader never looks at an
//  entry's data, only at the directory and where it sits.
//

import Testing
import Foundation
@testable import CryoframeKit

private let gib: UInt64 = 1 << 30
private let wrap: UInt64 = 1 << 32

private struct FakeEntry {
    var name: String
    var compressed: UInt64      // true size of its data in the zip
    var uncompressed: UInt64    // true size unpacked
}

/// deflate's worst case on data that doesn't compress: 5 bytes per 64 KB block
private func incompressible(_ n: UInt64) -> UInt64 { n + n / 65_535 * 5 + 11 }

private func le(_ v: UInt64, _ bytes: Int) -> [UInt8] { (0..<bytes).map { UInt8(truncatingIfNeeded: v >> UInt64(8 * $0)) } }

/// A sparse zip the way ditto lays it out: local header (30 + name + a 28-byte extra),
/// the data, a 16-byte data descriptor, then a central directory whose sizes and
/// offsets are modulo 2^32, then an end record whose entry count is modulo 65,536.
private func makeZip(_ entries: [FakeEntry], at url: URL) throws {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let h = try FileHandle(forWritingTo: url)
    defer { try? h.close() }
    var at: UInt64 = 0
    var directory: [UInt8] = []
    for e in entries {
        let name = Array(e.name.utf8)
        var c: [UInt8] = []
        c += le(0x0201_4b50, 4) + le(0x031E, 2) + le(20, 2) + le(8, 2) + le(8, 2) + le(0, 4)
        c += le(0, 4) + le(e.compressed % wrap, 4) + le(e.uncompressed % wrap, 4)
        c += le(UInt64(name.count), 2) + le(0, 2) + le(0, 2) + le(0, 2) + le(0, 2) + le(0o100644 << 16, 4)
        c += le(at % wrap, 4) + name
        directory += c
        at += 30 + UInt64(name.count) + 28 + e.compressed + 16
    }
    try h.truncate(atOffset: at)
    try h.seek(toOffset: at)
    var end: [UInt8] = le(0x0605_4b50, 4) + le(0, 2) + le(0, 2) + le(UInt64(entries.count) % 65_536, 2) + le(UInt64(entries.count) % 65_536, 2)
    end += le(UInt64(directory.count), 4) + le(at % wrap, 4) + le(0, 2)
    try h.write(contentsOf: Data(directory + end))
}

private func sizeOf(_ entries: [FakeEntry]) throws -> UInt64? {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cf-zipwrap-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let zip = dir.appendingPathComponent("t.zip")
    try makeZip(entries, at: zip)
    return ZipDirectory.unpackedSize(zip, blockSize: 4096)
}

@Suite struct ZipDirectoryWrapEdgeTests {
    @Test func aFileJustOverFourGigabytesThatDoesntCompressIsCountedWhole() throws {
        let unc = wrap + 1000
        let got = try #require(try sizeOf([FakeEntry(name: "big.bin", compressed: incompressible(unc), uncompressed: unc)]))
        #expect(got == unc + 4096, "\(got) for \(unc)")
    }

    @Test func aFileOverEightGigabytesThatDoesntCompressIsCountedWhole() throws {
        let unc = 2 * wrap + 5
        let got = try #require(try sizeOf([FakeEntry(name: "big.bin", compressed: incompressible(unc), uncompressed: unc),
                                           FakeEntry(name: "small.txt", compressed: 40, uncompressed: 100)]))
        #expect(got == unc + 100 + 2 * 4096, "\(got) for \(unc)")
    }

    // 4 GiB less a byte unpacked, a few hundred KB over 4 GiB in the zip: the zip's
    // size wrapped and the file's didn't. Over, never under.
    @Test func aFileJustUnderFourGigabytesIsNeverCountedLow() throws {
        let unc = wrap - 1
        let got = try #require(try sizeOf([FakeEntry(name: "big.bin", compressed: incompressible(unc), uncompressed: unc)]))
        #expect(got >= unc + 4096, "\(got) for \(unc)")
    }

    // The limit Mike stated: what compresses well and unpacks past 4 GiB, with its
    // compressed size under that, can't be told from the directory. Pinned so that a
    // fix turns it red: the check passes for 4 GiB of unpack that is never counted.
    @Test func aCompressibleFileOverFourGigabytesIsCountedLow() throws {
        let unc = wrap + 1000
        let got = try #require(try sizeOf([FakeEntry(name: "disk.img", compressed: unc / 1000, uncompressed: unc)]))
        withKnownIssue("an unpack past 4 GiB that compresses is counted as the bytes past a multiple of 4 GiB") {
            #expect(got >= unc, "counted \(got) for a file that unpacks to \(unc)")
        }
    }

    // Not only the extreme: 2:1 data (text, a database) of 9 GiB wraps its compressed
    // size once and its own twice, and only the compressed wrap is added back.
    @Test func aTwoToOneFileOfNineGigabytesIsCountedLow() throws {
        let unc = 9 * gib
        let got = try #require(try sizeOf([FakeEntry(name: "db.sqlite", compressed: unc / 2, uncompressed: unc)]))
        withKnownIssue("the 4 GiB multiples its own size lost beyond its compressed size's are not added back") {
            #expect(got >= unc, "counted \(got) for a file that unpacks to \(unc)")
        }
    }

    // The check the reader makes with the size: a zip that unpacks to more than the
    // startup disk has room for is refused before anything is unpacked.
    @Test func aZipWithoutRoomToUnpackIsRefusedBeforeItIsUnpacked() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cf-zipwrap-\(UUID().uuidString)")
        let lib = dir.appendingPathComponent("Notes")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(String(repeating: "n", count: 10_000).utf8).write(to: lib.appendingPathComponent("a.txt"))
        let zip = dir.appendingPathComponent("Notes.zip")
        let made = try ProcessCommandRunner().run("/usr/bin/ditto", ["-c", "-k", "--keepParent", lib.path, zip.path])
        try #require(made.ok, "\(made.stderr)")
        let reader = ArchiveReader(runner: ProcessCommandRunner(), workBase: dir, freeSpace: { _ in 4096 })
        do {
            let opened = try reader.open(ArchiveResult(artifacts: [zip], format: .sealedZip))
            opened.close()
            Issue.record("opened with 4 KB free")
        } catch let e as RestoreError {
            guard case .notEnoughRoom = e else { Issue.record("\(e)"); return }
        } catch { Issue.record("\(error)") }
    }
}
