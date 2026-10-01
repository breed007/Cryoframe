//
//  LetFinishTests.swift
//  CryoframeKitTests
//
//  Steps Stop and the watchdog never signal (ProcessCommandRunner.letsFinish): an
//  attach, and the making of an empty image. Stop lets one finish and hands back what
//  it printed, so the attach can be recorded and detached; the watchdog only gives up
//  on a stalled one. And the watchdog counts the work of a helper that has left the
//  tool's tree, as diskimages-helper does during an attach.
//

import Testing
import Foundation
@testable import CryoframeKit

private func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

private func tmp(_ tag: String) throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-letfinish-\(tag)-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// a stand-in hdiutil that notes a SIGTERM, runs `seconds` quietly, then prints a disk
private func standIn(in dir: URL, seconds: Int) throws -> URL {
    let tool = dir.appendingPathComponent("hdiutil")
    try """
    #!/bin/sh
    trap 'echo term > \(dir.appendingPathComponent("term").path)' TERM
    echo $$ > \(dir.appendingPathComponent("started").path)
    i=0; while [ $i -lt \(seconds * 10) ]; do /bin/sleep 0.1; i=$((i+1)); done
    echo done > \(dir.appendingPathComponent("finished").path)
    echo /dev/disk99
    exit 0
    """.write(to: tool, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
    return tool
}

@Suite(.serialized) struct LetFinishTests {

    @Test func onlyAnAttachAndTheMakingOfAnEmptyImageAreLetFinish() {
        let h = "/usr/bin/hdiutil"
        #expect(ProcessCommandRunner.letsFinish(h, ["attach", "/x.dmg", "-mountpoint", "/m"]))
        #expect(ProcessCommandRunner.letsFinish(h, ["create", "-type", "SPARSEBUNDLE", "-fs", "APFS", "/x.sparsebundle"]))
        #expect(!ProcessCommandRunner.letsFinish(h, ["create", "-srcfolder", "/src", "-format", "UDZO", "/x.dmg"]))
        #expect(!ProcessCommandRunner.letsFinish(h, ["resize", "-size", "2g", "/x.sparsebundle"]))
        #expect(!ProcessCommandRunner.letsFinish(h, ["detach", "/dev/disk9"]))
        #expect(!ProcessCommandRunner.letsFinish("/usr/bin/rsync", ["attach"]))
    }

    // Stop during an attach: the attach finishes, unsignaled, and the stop carries what
    // it printed, so its disk can be recorded and then detached.
    @Test func stopHandsBackWhatTheAttachItLetFinishPrinted() throws {
        let dir = try tmp("stop"); defer { try? FileManager.default.removeItem(at: dir) }
        let tool = try standIn(in: dir, seconds: 2)
        let control = RunControl(quietLimit: 60)
        let begin = uptime()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { control.cancel() }
        var stop: CancelledError?
        do { _ = try ProcessCommandRunner(control: control).run(tool.path, ["attach", "/x.dmg"]) }
        catch let e as CancelledError { stop = e }
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("finished").path))
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("term").path), "the attach was signaled")
        #expect(stop?.finished?.ok == true)
        #expect(stop?.finished?.stdout.contains("/dev/disk99") == true)
        #expect(uptime() - begin < 10)
        // nothing more is launched after Stop
        #expect(throws: CancelledError.self) { try ProcessCommandRunner(control: control).run("/bin/echo", ["x"]) }
    }

    // A quiet attach past the limit is given up on, never signaled: killed, the real
    // one attaches anyway, with no record of whose it is.
    @Test func aStalledAttachIsGivenUpOnNotSignaled() throws {
        let dir = try tmp("stall"); defer { try? FileManager.default.removeItem(at: dir) }
        let tool = try standIn(in: dir, seconds: 4)
        #expect(throws: ToolStalled.self) { try ProcessCommandRunner(quietLimit: 1).run(tool.path, ["attach", "/x.dmg"]) }
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("term").path), "the attach was signaled")
        let until = uptime() + 8
        while !fm.fileExists(atPath: dir.appendingPathComponent("finished").path), uptime() < until { Thread.sleep(forTimeInterval: 0.1) }
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("finished").path), "the attach was killed")
    }

    // The tool sits idle while a helper it started works on, after leaving the tool's
    // tree for launchd in a session of its own (diskimages-helper during an attach).
    @Test func workByAHelperThatLeftTheToolCounts() throws {
        let helper = "use POSIX; use Time::HiRes qw(time sleep); if (fork) { sleep 0.5; exit 0 } POSIX::setsid(); my $t = time + 4.5; while (time < $t) {}"
        let start = uptime()
        let r = try ProcessCommandRunner(quietLimit: 1).run("/bin/sh", ["-c", "/usr/bin/perl -e '\(helper)' >/dev/null 2>&1; sleep 4"])
        #expect(r.ok, "stopped after \(uptime() - start) s")
    }
}
