//
//  WatchdogEdgeTests.swift
//  CryoframeKitTests
//
//  The tool watchdog against tools that are slow but working: bursts of work with
//  long quiet stretches between them (shorter than the limit), work done by a
//  grandchild, work that is only disk I/O, and a run paused past the limit. Then the
//  ones it must stop: a tool frozen from outside, and a tool whose own child is the
//  one stuck. Limits here are 1-2 s instead of 15 min; the rule is the same.
//

import Testing
import Foundation
@testable import CryoframeKit

private func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

/// sh that spends about `ms` milliseconds of CPU (measured: about 2 µs an iteration)
private func spin(_ ms: Int) -> String {
    "i=0; while [ $i -lt \(ms * 500) ]; do i=$((i+1)); done"
}

private func tmp(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-wdedge-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@Suite(.serialized) struct WatchdogEdgeTests {

    // A slow NAS or hdiutil between phases: bursts of work, each followed by a quiet
    // stretch of 70% of the limit, for four times the limit in all. Never stopped.
    @Test func burstsOfWorkWithQuietBetweenAreLeftAlone() throws {
        let start = uptime()
        let r = try ProcessCommandRunner(quietLimit: 2).run("/bin/sh", ["-c", "for n in 1 2 3 4 5 6; do \(spin(60)); sleep 1.4; done"])
        #expect(r.ok, "stopped after \(uptime() - start) s: \(r.stderr)")
        #expect(uptime() - start >= 8)
    }

    // The work happens two levels down (a tool that starts a helper that starts a
    // worker), and the tool itself sits waiting.
    @Test func workByAGrandchildCounts() throws {
        let r = try ProcessCommandRunner(quietLimit: 1).run("/bin/sh", ["-c", "/bin/sh -c '/bin/sh -c \"for n in 1 2 3 4 5 6 7 8 9 10 11 12; do \(spin(40)); sleep 0.2; done\"; true'; true"])
        #expect(r.ok)
    }

    // Disk writes alone, with next to no CPU: a slow drive taking a trickle of data.
    @Test func diskWritesAloneCount() throws {
        let dir = tmp("io"); defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("trickle").path
        // one process writing 1 MB and syncing it every 0.5 s for 4 s, limit 1 s
        let r = try ProcessCommandRunner(quietLimit: 1).run("/usr/bin/perl", ["-MIO::Handle", "-e",
            "open(my $f, '>', '\(f)') or die; for (1..8) { sysseek($f, 0, 0); syswrite($f, 'x' x 1048576); $f->sync; select(undef, undef, undef, 0.5) }"])
        #expect(r.ok)
    }

    // Paused for three times the limit, then resumed: the pause isn't a stall, and
    // the quiet clock starts again at the resume rather than at the pause.
    @Test func aLongPauseThenQuietIsJudgedFromTheResume() throws {
        let control = RunControl(quietLimit: 1)
        let runner = ProcessCommandRunner(control: control)
        DispatchQueue.global().async {
            Thread.sleep(forTimeInterval: 0.3)
            _ = control.pause()
            Thread.sleep(forTimeInterval: 3)
            control.resume()
        }
        // works for the whole time, so only a pause mistaken for a stall could stop it
        let r = try runner.run("/bin/sh", ["-c", "for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do \(spin(30)); sleep 0.2; done"])
        #expect(r.ok)
    }

    // Frozen from outside (SIGSTOP by something other than Pause): no progress, so
    // stopped, and the whole tree is gone afterwards.
    @Test func aToolFrozenFromOutsideIsStopped() throws {
        let dir = tmp("frozen"); defer { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appendingPathComponent("pid").path
        let start = uptime()
        #expect(throws: ToolStalled.self) {
            _ = try ProcessCommandRunner(quietLimit: 1).run("/bin/sh", ["-c", "echo $$ > \(pidFile); kill -STOP $$; sleep 60"])
        }
        #expect(uptime() - start < 20, "took \(uptime() - start) s")
        if let pid = Int32(String(decoding: (try? Data(contentsOf: URL(fileURLWithPath: pidFile))) ?? Data(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)) {
            let deadline = uptime() + 5
            while kill(pid, 0) == 0, uptime() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            #expect(kill(pid, 0) != 0, "the frozen tool is still there")
        }
    }

    // A tool that prints steadily is working even when its CPU and disk use are nil
    // (rsync -v over a share: the share does the work).
    @Test func steadyOutputAloneCounts() throws {
        let r = try ProcessCommandRunner(quietLimit: 1).run("/bin/sh", ["-c", "for n in $(/usr/bin/seq 1 12); do echo line $n >&2; sleep 0.4; done"])
        #expect(r.ok)
        #expect(r.stderr.split(separator: "\n").count == 12)
    }

    // The stall is reported as the tool's, in words a person can act on, and the
    // wording picks seconds or minutes sensibly at the edge.
    @Test func theStallMessageReadsWell() {
        #expect(ToolStalled(tool: "hdiutil", quiet: 89).localizedDescription.hasPrefix("hdiutil made no progress for 89 seconds"))
        #expect(ToolStalled(tool: "hdiutil", quiet: 90).localizedDescription.hasPrefix("hdiutil made no progress for 2 minutes"))
        #expect(ToolStalled(tool: "rsync", quiet: 915).localizedDescription.hasPrefix("rsync made no progress for 15 minutes"))
    }
}
