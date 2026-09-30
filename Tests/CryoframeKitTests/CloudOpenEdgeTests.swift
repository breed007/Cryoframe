//
//  CloudOpenEdgeTests.swift
//  CryoframeKitTests
//
//  Downloading an evicted archive before it is opened, at the edges: a provider
//  that says "downloading" forever, a fetch that comes back with the archive still
//  not on this Mac, split archives with only some parts evicted, a local archive
//  never fetched at all, and quiet measured from the last sign of progress. The
//  provider is simulated through CloudDownload.
//

import Testing
import Foundation
@testable import CryoframeKit

private func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var _fetched: [String] = []
    private var _tick: UInt64 = 0
    var fetched: [String] { lock.lock(); defer { lock.unlock() }; return _fetched }
    func fetch(_ u: URL) { lock.lock(); _fetched.append(u.lastPathComponent); lock.unlock() }
    func bump() -> UInt64 { lock.lock(); defer { lock.unlock() }; _tick += 1; return _tick }
}

@Suite(.serialized) struct CloudOpenEdgeTests {

    // A provider that keeps saying it is downloading and never finishes: never
    // called stalled (it moves), and Stop still ends it at once.
    @Test func aDownloadThatNeverFinishesIsEndedByStop() throws {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let box = Box()
        let cloud = CloudDownload(isEvicted: { _ in true }, fetch: { _ in release.wait() }, progress: { _ in box.bump() })
        let control = RunControl(quietLimit: 0.3)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { control.cancel() }
        let start = uptime()
        #expect(throws: CancelledError.self) {
            try cloud.bringDown([URL(fileURLWithPath: "/nowhere/a.dmg")], quietLimit: 0.3, control: control)
        }
        #expect(uptime() - start >= 1.8, "stopped before Stop was pressed")
        #expect(uptime() - start < 4, "took \(uptime() - start) s to stop")
    }

    // The fetch came back (offline, the provider refused) and the archive is still a
    // placeholder: the open says so, instead of handing the placeholder to hdiutil
    // or ditto to wait on or fail at with a message about the image.
    @Test func aFetchThatLeavesTheArchiveEvictedIsReported() {
        let cloud = CloudDownload(isEvicted: { _ in true }, fetch: { _ in }, progress: { _ in 0 })
        var thrown: Error?
        do { try cloud.bringDown([URL(fileURLWithPath: "/nowhere/a.dmg")], quietLimit: 5, control: nil) }
        catch { thrown = error }
        #expect(thrown != nil, "the archive is still evicted after the fetch, and the open went on")
    }

    // A split archive with only some parts evicted: only those are fetched, and an
    // archive on a local drive isn't fetched at all.
    @Test func onlyEvictedPartsAreFetched() throws {
        let box = Box()
        let cloud = CloudDownload(isEvicted: { $0.lastPathComponent.hasPrefix("evicted") }, fetch: { box.fetch($0) }, progress: { _ in 0 })
        let parts = ["local.aa", "evicted.ab", "local.ac", "evicted.ad"].map { URL(fileURLWithPath: "/nowhere/\($0)") }
        try cloud.bringDown(parts, quietLimit: 5, control: nil)
        #expect(box.fetched == ["evicted.ab", "evicted.ad"])
        let local = Box()
        try CloudDownload(isEvicted: { _ in false }, fetch: { local.fetch($0) }, progress: { _ in 0 })
            .bringDown([URL(fileURLWithPath: "/nowhere/x.dmg")], quietLimit: 5, control: nil)
        #expect(local.fetched.isEmpty)
        // and the real check calls a plain local file local
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("cf-cloudedge-\(UUID().uuidString).dmg")
        try Data(repeating: 1, count: 4096).write(to: f)
        defer { try? FileManager.default.removeItem(at: f) }
        #expect(!CloudDownload.system.isEvicted(f))
    }

    // Quiet is counted from the last sign of progress, not from the start: a download
    // that moves for a while and then stops is stopped one quiet limit after it stopped.
    @Test func quietIsCountedFromTheLastProgress() throws {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let start = uptime()
        let box = Box()
        let cloud = CloudDownload(isEvicted: { _ in true }, fetch: { _ in release.wait() },
                                  progress: { _ in uptime() - start < 1.5 ? box.bump() : 999_999 })
        var stalled: CloudDownloadStalled?
        do { try cloud.bringDown([URL(fileURLWithPath: "/nowhere/a.dmg")], quietLimit: 1, control: nil) }
        catch let e as CloudDownloadStalled { stalled = e }
        let took = uptime() - start
        #expect(stalled != nil)
        #expect(took >= 2.3 && took < 5, "stopped after \(took) s")
        #expect(stalled?.localizedDescription.contains("cloud") == true)
    }
}
