//
//  MirrorSparseTests.swift
//  CryoframeKitTests
//
//  A live mirror of a library holding a sparse file (a virtual machine's disk).
//  Measured on macOS 26.7: rsync without -S writes a 1 GiB sparse file out whole
//  into the mirror's image, 1 GB of bands for 4 KB of data, where the room check
//  and the image's cap counted only what the file takes on disk.
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

@Suite(.serialized) struct MirrorSparseTests {

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
