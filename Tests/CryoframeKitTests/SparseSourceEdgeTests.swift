//
//  SparseSourceEdgeTests.swift
//  CryoframeKitTests
//
//  A library holding a sparse file: a virtual machine's disk, Docker's disk, a
//  database's preallocated file. Most of it is a hole that takes no room. Measured
//  on macOS 26.7: `hdiutil create -srcfolder` sizes the image by what the folder
//  takes on disk, then writes the file out whole and fails "No space left on
//  device" (with plenty free on the drive). Older than milestone 4; found while
//  testing its room checks.
//

import Testing
import Foundation
@testable import CryoframeKit

@Suite struct SparseSourceEdgeTests {

    @Test func aLibraryHoldingASparseFileSealsIntoADiskImage() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("cf-sparse-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: base) }
        let lib = base.appendingPathComponent("VMs")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        let disk = lib.appendingPathComponent("disk.img")
        try #require(FileManager.default.createFile(atPath: disk.path, contents: Data("boot".utf8)))
        let fh = try FileHandle(forWritingTo: disk)
        try fh.truncate(atOffset: 1 << 30)                       // 1 GiB, nearly all of it a hole
        try fh.close()
        try #require(JobExecutor.directoryStats(lib).bytes < 64 * 1024 * 1024, "the file system didn't keep the hole")
        do {
            let result = try SealedArchiveEngine(.dmg).archive(ArchiveSource(name: "VMs", root: lib), to: base.appendingPathComponent("out"))
            #expect(result.artifacts.count == 1)
        } catch {
            Issue.record("a library holding a 1 GiB sparse file (\(JobExecutor.directoryStats(lib).bytes) bytes on disk) didn't seal: \(error)")
        }
    }
}
