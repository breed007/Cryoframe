//
//  ToolWatchdogTests.swift
//  CryoframeKitTests
//
//  A tool that makes no progress is stopped and the run fails saying so; a tool that
//  is working, however slowly and however quietly, is left alone.
//

import Testing
import Foundation
@testable import CryoframeKit

private func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

/// a shell loop that spends about `seconds` of CPU and prints nothing
private func busy(_ seconds: Double) -> [String] {
    ["-c", "end=$(( $(date +%s) + \(Int(seconds.rounded(.up))) )); while [ $(date +%s) -lt $end ]; do :; done"]
}

@Suite(.serialized) struct ToolWatchdogTests {

    // Blocked (on a dead share, on a prompt), a tool spends no CPU, does no I/O and
    // prints nothing. It used to be waited on for as long as it took: all night.
    @Test func aToolThatMakesNoProgressIsStopped() throws {
        let start = uptime()
        #expect {
            _ = try ProcessCommandRunner(quietLimit: 1).run("/bin/sleep", ["60"])
        } throws: { error in
            guard let e = error as? ToolStalled else { return false }
            return e.tool == "sleep" && e.quiet >= 1
        }
        #expect(uptime() - start < 15, "took \(uptime() - start) s to give up")
        #expect(ToolStalled(tool: "rsync", quiet: 900).localizedDescription
                .hasPrefix("rsync made no progress for 15 minutes and was stopped"))
    }

    // Everything the tool started is stopped with it.
    @Test func whatTheToolStartedIsStoppedToo() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("cf-wd-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        #expect(throws: ToolStalled.self) {
            _ = try ProcessCommandRunner(quietLimit: 1).run("/bin/sh", ["-c", "sleep 60 & echo $! > \(marker.path); wait"])
        }
        let child = try #require(Int32(String(decoding: try Data(contentsOf: marker), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        let deadline = uptime() + 5
        while kill(child, 0) == 0, uptime() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        #expect(kill(child, 0) != 0, "the tool's child is still running")
    }

    // Working and silent (rsync prints nothing without -v), slow and printing, or
    // working through a child: all left alone, however long past the quiet limit.
    @Test func aToolThatIsWorkingIsNeverStopped() throws {
        let runner = ProcessCommandRunner(quietLimit: 1)
        let silent = try runner.run("/bin/sh", busy(3))
        #expect(silent.ok)
        let chatty = try runner.run("/bin/sh", ["-c", "for i in 1 2 3 4 5 6 7 8; do echo $i; sleep 0.4; done"])
        #expect(chatty.ok && chatty.stdout.split(separator: "\n").count == 8)
        let parent = try runner.run("/bin/sh", ["-c", "sh -c '\(busy(3)[1])' & wait"])
        #expect(parent.ok)
    }

    // Pause stops the tool on purpose. That quiet isn't a stall.
    @Test func aPausedToolIsNotStopped() throws {
        let control = RunControl(quietLimit: 1)
        let runner = ProcessCommandRunner(control: control)
        let paused = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            Thread.sleep(forTimeInterval: 0.5)
            _ = control.pause()
            Thread.sleep(forTimeInterval: 3)
            control.resume()
            paused.signal()
        }
        let r = try runner.run("/bin/sh", busy(2))
        #expect(r.ok)
        #expect(paused.wait(timeout: .now() + 10) == .success)
    }

    // After a stop the run still cleans up: the next command, and the teardown
    // runner, work as before.
    @Test func teardownWorksAfterAStop() throws {
        let control = RunControl(quietLimit: 1)
        let runner = ProcessCommandRunner(control: control)
        #expect(throws: ToolStalled.self) { _ = try runner.run("/bin/sleep", ["60"]) }
        #expect(!control.isCancelled)
        #expect(try runner.run("/bin/echo", ["next"]).stdout == "next\n")
        #expect(try runner.forTeardown.run("/usr/bin/true", []).ok)
        #expect((runner.forTeardown as? ProcessCommandRunner)?.quietLimit == 1)
    }

    // A mirror run whose rsync stops making progress (a drive that hangs) fails with
    // the watchdog's message, detaches the image, and leaves the previous copy to
    // restore.
    @Test func aStalledMirrorRunFailsPlainlyAndLeavesThePreviousCopy() throws {
        let fm = FileManager.default
        func dir(_ tag: String) -> URL {
            let d = fm.temporaryDirectory.appendingPathComponent("cf-wdm-\(tag)-\(UUID().uuidString)")
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
            return URL(fileURLWithPath: realpath(d.path, nil).map { p in defer { free(p) }; return String(cString: p) } ?? d.path)
        }
        let src = dir("src").appendingPathComponent("Lib"), out = dir("out"), base = dir("base"), back = dir("back")
        defer { for d in [src.deletingLastPathComponent(), out, base, back] { try? fm.removeItem(at: d) } }
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("first".utf8).write(to: src.appendingPathComponent("a.txt"))
        let bundle = try SparseBundleMirrorEngine(sizeGB: 1, mountBase: base).archive(ArchiveSource(name: "Lib", root: src), to: out).artifacts[0]
        try Data("second".utf8).write(to: src.appendingPathComponent("a.txt"))

        let hangs = RsyncHangs(quietLimit: 1)
        let start = uptime()
        var failure: Error?
        do { _ = try SparseBundleMirrorEngine(sizeGB: 1, runner: hangs, mountBase: base).archive(ArchiveSource(name: "Lib", root: src), to: out) }
        catch { failure = error }
        #expect(failure is ToolStalled, "\(String(describing: failure))")
        #expect(uptime() - start < 60)
        #expect(MirrorMounts.mountPoints(of: bundle, runner: ProcessCommandRunner()).isEmpty, "the image was left attached")
        let archive = try #require(RestoreDiscovery.archive(at: out))
        let restored = try RestoreEngine().restore(archive, to: back, verify: true)
        #expect(try String(contentsOf: restored.appendingPathComponent("a.txt"), encoding: .utf8) == "first")
    }

    // Stop still wins: a run that was stopped reports that, not a stall.
    @Test func stopIsStillStop() throws {
        let control = RunControl(quietLimit: 30)
        let runner = ProcessCommandRunner(control: control)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { control.cancel() }
        #expect(throws: CancelledError.self) { _ = try runner.run("/bin/sleep", ["60"]) }
    }
}

/// runs every tool for real, except rsync, which hangs (a stand-in that makes no
/// progress), under a short quiet limit
private final class RsyncHangs: CommandRunner, @unchecked Sendable {
    let inner: ProcessCommandRunner
    init(quietLimit: TimeInterval) { inner = ProcessCommandRunner(quietLimit: quietLimit) }
    var forTeardown: CommandRunner { inner.forTeardown }
    func run(_ launchPath: String, _ args: [String], stdin: Data?) throws -> CommandResult {
        if (launchPath as NSString).lastPathComponent == "rsync" { return try inner.run("/bin/sleep", ["60"], stdin: nil) }
        return try inner.run(launchPath, args, stdin: stdin)
    }
}
