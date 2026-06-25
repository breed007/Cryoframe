//
//  TransferTests.swift
//  CryoframeKitTests
//
//  Chunked resumable shipping: parts reassemble to the original, resume skips
//  completed parts, pending-transfer persistence, and resumable-target flags.
//

import Testing
import Foundation
import Security
@testable import CryoframeKit

private func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-xfer-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}
private func writeRandom(_ bytes: Int, to url: URL) throws {
    var buf = [UInt8](repeating: 0, count: bytes)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &buf)
    try Data(buf).write(to: url)
}
private func reassemble(_ parts: [URL]) throws -> Data {
    var out = Data()
    for p in parts.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) { out.append(try Data(contentsOf: p)) }
    return out
}

@Test func shipsArchiveAsPartsThatReassemble() throws {
    let work = tempDir(); defer { try? FileManager.default.removeItem(at: work) }
    let source = work.appendingPathComponent("Lib.dmg")
    try writeRandom(5_000_000, to: source)
    let target = tempDir(); defer { try? FileManager.default.removeItem(at: target) }

    let pending = PendingTransfer(jobID: "j", sourceFile: source.path, baseName: "Lib.dmg",
                                  totalBytes: 5_000_000, chunkSize: 2_000_000,
                                  targetDir: target.path, format: .sealedDMG)
    let manifest = try ChunkedShipper().ship(pending, persist: { _ in })

    #expect(manifest.artifacts.map(\.size) == [2_000_000, 2_000_000, 1_000_000])   // 2+2+1
    for a in manifest.artifacts {
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent(a.name).path))
    }
    #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent(ArchiveManifest.sidecarName).path))
    let reassembled = try reassemble(manifest.artifacts.map { target.appendingPathComponent($0.name) })
    #expect(reassembled == (try Data(contentsOf: source)))
}

@Test func resumeReshipsOnlyMissingParts() throws {
    let work = tempDir(); defer { try? FileManager.default.removeItem(at: work) }
    let source = work.appendingPathComponent("Lib.dmg")
    try writeRandom(5_000_000, to: source)
    let target = tempDir(); defer { try? FileManager.default.removeItem(at: target) }
    let pending = PendingTransfer(jobID: "j", sourceFile: source.path, baseName: "Lib.dmg",
                                  totalBytes: 5_000_000, chunkSize: 2_000_000,
                                  targetDir: target.path, format: .sealedDMG)

    let full = try ChunkedShipper().ship(pending, persist: { _ in })
    let last = full.artifacts.last!.name
    try FileManager.default.removeItem(at: target.appendingPathComponent(last))   // simulate the dropped part

    var resumed = pending
    resumed.completed = Array(full.artifacts.prefix(2))                           // first two already done
    let m2 = try ChunkedShipper().ship(resumed, persist: { _ in })

    #expect(m2.artifacts.count == 3)
    #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent(last).path))   // re-shipped
    let reassembled = try reassemble(m2.artifacts.map { target.appendingPathComponent($0.name) })
    #expect(reassembled == (try Data(contentsOf: source)))
}

@Test func pendingTransferStoreRoundTrips() {
    let store = PendingTransferStore(url: tempDir().appendingPathComponent("p.json"))
    let t = PendingTransfer(jobID: "j", sourceFile: "/s", baseName: "b",
                            totalBytes: 10, chunkSize: 4, targetDir: "/t", format: .sealedZip)
    store.save(t)
    #expect(store.all().count == 1)
    #expect(store.all().first?.totalParts == 3)         // ceil(10/4)
    store.remove(jobID: "j")
    #expect(store.all().isEmpty)
}

@Test func resumerShipsPendingThenClearsIt() throws {
    let scratch = tempDir()
    let source = scratch.appendingPathComponent("Lib.dmg")
    try writeRandom(3_000_000, to: source)
    let target = tempDir(); defer { try? FileManager.default.removeItem(at: target) }
    let store = PendingTransferStore(url: tempDir().appendingPathComponent("p.json"))
    store.save(PendingTransfer(jobID: "j", sourceFile: source.path, baseName: "Lib.dmg",
                               totalBytes: 3_000_000, chunkSize: 2_000_000,
                               targetDir: target.path, format: .sealedDMG))

    let resumed = TransferResumer.resumeAll(store: store)

    #expect(resumed == ["j"])
    #expect(store.all().isEmpty)                                          // record cleared
    #expect(!FileManager.default.fileExists(atPath: scratch.path))       // scratch removed
    #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent(ArchiveManifest.sidecarName).path))
    #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent(ChunkedShipper.partName("Lib.dmg", 0)).path))
}

@Test func fragileTargetsShipResumablyButLocalDoesNot() {
    let ext = Target.externalDrive(id: "e", name: "Ext", dir: URL(fileURLWithPath: "/Volumes/Ext"))
    let nas = Target.networkShare(id: "n", name: "NAS", dir: URL(fileURLWithPath: "/Volumes/NAS"),
                                  mount: NetworkMountSpec(url: URL(string: "smb://nas/s")!, mountpoint: "/Volumes/NAS"))
    let local = Target.localVolume(id: "l", name: "Disk", dir: URL(fileURLWithPath: "/tmp"))
    #expect(ext.constraints.resumableTransfer)
    #expect(nas.constraints.resumableTransfer)
    #expect(!local.constraints.resumableTransfer)
}
