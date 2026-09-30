//
//  CloudDownloadTests.swift
//  CryoframeKitTests
//
//  Opening an archive a cloud provider has evicted: it is downloaded before any tool
//  reads it, a slow download is left to finish as long as it moves, and one that
//  stops moving (or a Stop) ends the open plainly. The download is simulated.
//

import Testing
import Foundation
@testable import CryoframeKit

/// a simulated provider: evicted until fetched, a fetch that takes `seconds`, and a
/// progress figure that moves while it does (or doesn't, if `stuck`)
private final class FakeProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var local = false, ticks: UInt64 = 0
    private(set) var fetchedBeforeAttach: Bool?
    let seconds: Double, stuck: Bool
    init(seconds: Double, stuck: Bool = false) { self.seconds = seconds; self.stuck = stuck }
    var isLocal: Bool { lock.lock(); defer { lock.unlock() }; return local }
    func attaching() { lock.lock(); if fetchedBeforeAttach == nil { fetchedBeforeAttach = local }; lock.unlock() }
    var download: CloudDownload {
        CloudDownload(isEvicted: { _ in !self.isLocal },
                      fetch: { _ in
                          let end = ProcessInfo.processInfo.systemUptime + self.seconds
                          while ProcessInfo.processInfo.systemUptime < end { Thread.sleep(forTimeInterval: 0.05) }
                          self.lock.lock(); self.local = true; self.lock.unlock()
                      },
                      progress: { _ in
                          self.lock.lock(); defer { self.lock.unlock() }
                          if !self.stuck { self.ticks += 1 }
                          return self.ticks
                      })
    }
}

/// notes, at each attach or extract, whether the archive was local by then
private struct Watching: CommandRunner {
    let inner: ProcessCommandRunner
    let provider: FakeProvider
    var control: RunControl? { inner.control }
    var forTeardown: CommandRunner { inner.forTeardown }
    func run(_ launchPath: String, _ args: [String], stdin: Data?) throws -> CommandResult {
        if args.first == "attach" || args.first == "-x" { provider.attaching() }
        return try inner.run(launchPath, args, stdin: stdin)
    }
}

private func tempDir(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-cloud-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@Suite(.serialized) struct CloudDownloadTests {

    // A download that takes several times the quiet limit, and keeps moving: the
    // archive is local before hdiutil sees it, and the open succeeds. Before, the
    // tool read the placeholder itself, sat idle while the provider fetched, and the
    // watchdog stopped it.
    @Test func anEvictedArchiveIsDownloadedBeforeItIsOpened() throws {
        let src = tempDir("src"), out = tempDir("out"), work = tempDir("work")
        defer { for d in [src, out, work] { try? FileManager.default.removeItem(at: d) } }
        try Data("inside".utf8).write(to: src.appendingPathComponent("a.txt"))
        let result = try SealedArchiveEngine(.dmg).archive(ArchiveSource(name: "Lib", root: src), to: out)
        let provider = FakeProvider(seconds: 3)
        let runner = Watching(inner: ProcessCommandRunner(quietLimit: 1), provider: provider)
        let opened = try ArchiveReader(runner: runner, workBase: work, cloud: provider.download).open(result)
        defer { opened.close() }
        #expect(provider.fetchedBeforeAttach == true, "the tool read the archive before it was downloaded")
        #expect(FileManager.default.fileExists(atPath: opened.root.appendingPathComponent("Lib/a.txt").path)
                || FileManager.default.fileExists(atPath: opened.root.appendingPathComponent("a.txt").path))
    }

    // A download that stops moving ends the open with a plain message about the cloud,
    // not a tool that "made no progress".
    @Test func aDownloadThatStopsMovingEndsTheOpenPlainly() throws {
        let provider = FakeProvider(seconds: 60, stuck: true)
        let start = ProcessInfo.processInfo.systemUptime
        #expect {
            _ = try ArchiveReader(runner: ProcessCommandRunner(quietLimit: 1), cloud: provider.download)
                .open(ArchiveResult(artifacts: [URL(fileURLWithPath: "/tmp/nowhere.dmg")], format: .sealedDMG))
        } throws: { error in
            (error as? CloudDownloadStalled) != nil && error.localizedDescription.hasPrefix("this archive is in a cloud folder and isn't on this Mac")
        }
        #expect(ProcessInfo.processInfo.systemUptime - start < 10)
    }

    // Stop ends it at once, however the download is going.
    @Test func stopEndsADownloadAtOnce() throws {
        let provider = FakeProvider(seconds: 60)
        let control = RunControl(quietLimit: 30)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { control.cancel() }
        let start = ProcessInfo.processInfo.systemUptime
        #expect(throws: CancelledError.self) {
            _ = try ArchiveReader(runner: ProcessCommandRunner(control: control), cloud: provider.download)
                .open(ArchiveResult(artifacts: [URL(fileURLWithPath: "/tmp/nowhere.dmg")], format: .sealedDMG))
        }
        #expect(ProcessInfo.processInfo.systemUptime - start < 5)
    }
}
