//
//  StopAttachEdgeTests.swift
//  CryoframeKitTests
//
//  Stop pressed while `hdiutil attach` runs. Since 4820deb, Stop ends a tool the
//  way the watchdog does: SIGTERM to its group, then SIGKILL after the grace period.
//
//  Killing hdiutil doesn't stop an attach. The work is done by diskimages-helper,
//  which launchd starts (ppid 1, a process group of its own), so neither the
//  group nor the tree under hdiutil reaches it. Measured on macOS 26.7 with a 1.5 GB
//  UDZO: SIGTERM makes hdiutil print "canceling..." and then finish the attach
//  (status 0, mounted); SIGKILL 0.05 s into the attach leaves status 137, and the image
//  is attached and mounted anyway a moment later, by a helper that keeps running
//  after its disk is detached. AttachRecords records only an attach that returned,
//  so that disk is nobody's: teardown that runs before it mounts misses it, and the
//  next mirror run of the image refuses it as attached elsewhere until someone ejects
//  it. So an attach is let finish (and then detached) rather than killed.
//
//  The stand-in below acts as hdiutil does on SIGTERM: says it's canceling, and goes
//  on to finish 12 s later, past the 10 s grace.
//

import Testing
import Foundation
@testable import CryoframeKit

@Suite(.serialized) struct StopAttachEdgeTests {
    @Test func stopLetsAnAttachInFlightFinishRatherThanKillIt() throws {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: realPath(fm.temporaryDirectory.path))
            .appendingPathComponent("cf-stopattach-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let tool = dir.appendingPathComponent("hdiutil")
        let started = dir.appendingPathComponent("started"), finished = dir.appendingPathComponent("finished")
        try """
        #!/bin/sh
        trap 'echo canceling...' TERM
        echo $$ > \(started.path)
        i=0; while [ $i -lt 120 ]; do /bin/sleep 0.1; i=$((i+1)); done
        echo attached > \(finished.path)
        echo /dev/disk99
        exit 0
        """.write(to: tool, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let control = RunControl(quietLimit: 60)
        let done = DispatchSemaphore(value: 0)
        let outcome = Box()
        Thread.detachNewThread {
            do { _ = try ProcessCommandRunner(control: control).run(tool.path, ["attach", dir.appendingPathComponent("x.dmg").path,
                                                                                 "-mountpoint", dir.appendingPathComponent("mnt").path]); outcome.set("finished") }
            catch is CancelledError { outcome.set("cancelled") }
            catch { outcome.set("\(error)") }
            done.signal()
        }
        let begin = ProcessInfo.processInfo.systemUptime
        while !fm.fileExists(atPath: started.path), ProcessInfo.processInfo.systemUptime - begin < 10 { Thread.sleep(forTimeInterval: 0.05) }
        try #require(fm.fileExists(atPath: started.path), "the attach never started")
        Thread.sleep(forTimeInterval: 0.3)
        control.cancel()
        _ = done.wait(timeout: .now() + 40)
        // give a killed one the time it would have needed, then look
        while !fm.fileExists(atPath: finished.path), ProcessInfo.processInfo.systemUptime - begin < 16 { Thread.sleep(forTimeInterval: 0.1) }
        #expect(outcome.value == "cancelled", "\(outcome.value ?? "still running")")
        #expect(fm.fileExists(atPath: finished.path),
                "Stop killed hdiutil attach mid-way: the real helper finishes it anyway, unrecorded")
    }
}

private func realPath(_ p: String) -> String {
    guard let r = realpath(p, nil) else { return p }
    defer { free(r) }
    return String(cString: r)
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var v: String?
    func set(_ s: String) { lock.lock(); v = s; lock.unlock() }
    var value: String? { lock.lock(); defer { lock.unlock() }; return v }
}
