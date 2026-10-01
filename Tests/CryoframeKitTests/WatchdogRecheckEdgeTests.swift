//
//  WatchdogRecheckEdgeTests.swift
//  CryoframeKitTests
//
//  The watchdog stopping a frozen tool that starts something on its way out: a
//  process the tree it read doesn't hold, which keeps the tool's output open.
//
//  This is the flake in WatchdogEdgeTests.aToolFrozenFromOutsideIsStopped (CI,
//  macos-15: 32 s against a limit of 20). ToolWatch.stop reads the tree, sends it
//  SIGCONT, then SIGTERM. Between the two the frozen shell runs on and forks
//  `sleep 60`; the shell dies of the SIGTERM, the sleep doesn't (it wasn't in the
//  tree), is handed to launchd, and holds both pipes. The readers then wait out the
//  30 s allowed for a tool stuck in the kernel, and the sleep is still running after
//  the run has moved on. Measured here: 3 of 150 under load (each slow one left a
//  `sleep 60` with ppid 1), and 3 of 40 of the real test under load, all 32.0-33.0 s.
//  The tests below make the same thing happen every time. The tool runs in a
//  process group of its own, which the late child keeps.
//

import Testing
import Foundation
@testable import CryoframeKit

private func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

private func tmp(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-wdrecheck-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func pid(in file: URL) -> pid_t? {
    pid_t(String(decoding: (try? Data(contentsOf: file)) ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

/// whether `pid` is gone within `seconds`
private func gone(_ pid: pid_t, within seconds: TimeInterval) -> Bool {
    let deadline = uptime() + seconds
    while kill(pid, 0) == 0, uptime() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    return kill(pid, 0) != 0
}

@Suite(.serialized) struct WatchdogRecheckEdgeTests {
    // A frozen tool that outlasts SIGTERM (as a tool cleaning up does) and starts a
    // child when woken: the child isn't in the tree read before waking it.
    @Test func aChildStartedWhenTheFrozenToolIsWokenIsStoppedToo() throws {
        let dir = tmp("woken"); defer { try? FileManager.default.removeItem(at: dir) }
        let child = dir.appendingPathComponent("child")
        defer { if let p = pid(in: child) { kill(p, SIGKILL) } }
        let begin = uptime()
        #expect(throws: ToolStalled.self) {
            _ = try ProcessCommandRunner(quietLimit: 1).run("/bin/sh", ["-c",
                "trap '' TERM; trap '/bin/sh -c \"echo \\$\\$ > \(child.path); exec /bin/sleep 60\"' CONT; kill -STOP $$; wait"])
        }
        let took = uptime() - begin
        let late = try #require(pid(in: child), "the tool never started its child")
        #expect(gone(late, within: 2), "the child the tool started when woken is still running")
        #expect(took < 20, "took \(took) s")
    }

    // A frozen tool whose SIGTERM leaves a child behind as it exits: the child is
    // handed to launchd, out of any tree read from the tool, but still in its group.
    @Test func aChildLeftBehindByTheStoppedToolIsStoppedToo() throws {
        let dir = tmp("left"); defer { try? FileManager.default.removeItem(at: dir) }
        let child = dir.appendingPathComponent("child")
        defer { if let p = pid(in: child) { kill(p, SIGKILL) } }
        let begin = uptime()
        #expect(throws: ToolStalled.self) {
            _ = try ProcessCommandRunner(quietLimit: 1).run("/bin/sh", ["-c",
                "trap '/bin/sh -c \"echo \\$\\$ > \(child.path); exec /bin/sleep 60\" & exit 0' TERM; kill -STOP $$; while :; do :; done"])
        }
        let took = uptime() - begin
        let late = try #require(pid(in: child), "the tool never started its child")
        #expect(gone(late, within: 2), "the child the stopped tool left behind is still running")
        #expect(took < 20, "took \(took) s")
    }
}
