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

    // Stop (RunControl.cancel) wakes the tool and SIGTERMs the tool alone: never what
    // it started, and never SIGKILL (333e8de moved only the watchdog off that).
    // A child of the tool (rsync's, or one a shell leaves running) keeps the tool's
    // output open after the tool has gone, the watchdog has quit (the tool isn't
    // running), and the run waits on the output for as long as the child lives, with
    // its snapshot held and its job locked: here 40 s, on a hung share for good.
    @Test func stopEndsWhatTheToolStartedToo() throws {
        let dir = tmp("stopchild"); defer { try? FileManager.default.removeItem(at: dir) }
        let child = dir.appendingPathComponent("child")
        defer { if let p = pid(in: child) { kill(p, SIGKILL) } }
        let control = RunControl(quietLimit: 30)
        let took = try stopping(control, after: { pid(in: child) != nil }, "/bin/sh", ["-c",
            "/bin/sh -c \"echo \\$\\$ > \(child.path); exec /bin/sleep 40\" & wait"])
        let late = try #require(pid(in: child), "the tool never started its child")
        #expect(gone(late, within: 2), "the tool's child is still running after Stop")
        #expect(took < 15, "Stop took \(took) s")
    }

    // Stop on a paused tool: it is woken, then SIGTERMed, and starts a child as it
    // exits. That child is the late child the watchdog had (it isn't in the tree read
    // before waking), here through Stop.
    @Test func stopOnAPausedToolEndsTheChildItLeavesAsItExits() throws {
        let dir = tmp("stoppaused"); defer { try? FileManager.default.removeItem(at: dir) }
        let child = dir.appendingPathComponent("child"), ready = dir.appendingPathComponent("ready")
        defer { if let p = pid(in: child) { kill(p, SIGKILL) } }
        let control = RunControl(quietLimit: 30)
        let took = try stopping(control, after: {
            guard pid(in: ready) != nil else { return false }
            return control.pause()
        }, "/bin/sh", ["-c",
            "trap '/bin/sh -c \"echo \\$\\$ > \(child.path); exec /bin/sleep 40\" & exit 0' TERM; echo $$ > \(ready.path); while :; do /bin/sleep 0.1; done"])
        let late = try #require(pid(in: child), "the tool never started its child")
        #expect(gone(late, within: 2), "the child the stopped tool left is still running after Stop")
        #expect(took < 15, "Stop took \(took) s")
    }
}

/// Run `tool` under `control` on a thread of its own, Stop it once `when` says so,
/// and return how long the run took from the Stop to returning (it must say Cancelled).
private func stopping(_ control: RunControl, after when: @escaping () -> Bool, _ tool: String, _ args: [String]) throws -> TimeInterval {
    let finished = DispatchSemaphore(value: 0)
    let outcome = Outcome()
    Thread.detachNewThread {
        do { _ = try ProcessCommandRunner(control: control).run(tool, args); outcome.set("finished") }
        catch is CancelledError { outcome.set("cancelled") }
        catch { outcome.set("\(error)") }
        finished.signal()
    }
    let deadline = uptime() + 10
    while !when(), uptime() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    try #require(uptime() < deadline, "the tool never got going")
    Thread.sleep(forTimeInterval: 0.3)
    let stoppedAt = uptime()
    control.cancel()
    _ = finished.wait(timeout: .now() + 60)
    let took = uptime() - stoppedAt
    #expect(outcome.value == "cancelled", "\(outcome.value ?? "still running")")
    return took
}

private final class Outcome: @unchecked Sendable {
    private let lock = NSLock()
    private var v: String?
    func set(_ s: String) { lock.lock(); v = s; lock.unlock() }
    var value: String? { lock.lock(); defer { lock.unlock() }; return v }
}
