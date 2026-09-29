//
//  TransferStopEdgeTests.swift
//  CryoframeKitTests
//
//  Stop reaching a transfer in the middle of a part, not just between parts. A part
//  can be gigabytes on a slow share; the shipper checks the run's control every
//  8 MB block. Stopped mid-part, nothing half-written may be left under a final
//  part name, and the record must not claim the part.
//

import Testing
import Foundation
@testable import CryoframeKit

@Test func stopInTheMiddleOfAPartLeavesNoPartBehind() throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("cf-stopedge-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: base) }
    let dest = base.appendingPathComponent("dest")
    try fm.createDirectory(at: dest, withIntermediateDirectories: true)
    // one 256 MB part: sparse on disk, but read, hashed and written block by block
    let size: UInt64 = 256 * 1024 * 1024
    let src = base.appendingPathComponent("Lib.dmg")
    fm.createFile(atPath: src.path, contents: nil)
    let h = try FileHandle(forWritingTo: src); try h.truncate(atOffset: size); try h.close()

    let pending = PendingTransfer(jobID: "job:dest:lib", sourceFile: src.path, baseName: "Lib.dmg",
                                  totalBytes: size, chunkSize: size, targetDir: dest.path,
                                  format: .sealedDMG, encrypted: false)
    let control = RunControl()
    let saved = SavedParts()
    // Stop once the part is being written, so it lands mid-part and not before it
    let tmp = dest.appendingPathComponent("Lib.dmg.part.000.cryoframe-tmp").path
    let sawPart = Flag()
    DispatchQueue.global().async {
        let deadline = ProcessInfo.processInfo.systemUptime + 10     // uptime: stops while the Mac sleeps
        while ProcessInfo.processInfo.systemUptime < deadline {
            if FileManager.default.fileExists(atPath: tmp) { sawPart.set(); control.cancel(); return }
            usleep(500)
        }
    }

    let started = ProcessInfo.processInfo.systemUptime
    #expect(throws: CancelledError.self) {
        try ChunkedShipper().ship(pending, persist: { saved.add($0) }, control: control)
    }
    let took = ProcessInfo.processInfo.systemUptime - started

    #expect(sawPart.value, "the part finished before Stop could land mid-part")
    let left = (try? fm.contentsOfDirectory(atPath: dest.path)) ?? []
    #expect(left.isEmpty, "left behind after a stop: \(left)")
    #expect(saved.count == 0)                                   // no part claimed
    #expect(took < 5, "a stop mid-part took \(took) s to be heard")
}

private final class SavedParts: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [PendingTransfer] = []
    func add(_ s: PendingTransfer) { lock.lock(); states.append(s); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return states.count }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    func set() { lock.lock(); on = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return on }
}
