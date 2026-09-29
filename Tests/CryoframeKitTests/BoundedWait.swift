//
//  BoundedWait.swift
//  CryoframeKitTests
//
//  Waiting for a helper process without letting it hang the suite.
//
//  `Process.waitUntilExit()` waits for Foundation's termination notice, not for the
//  process. One run in eight hung for 23 minutes in a `defer` whose `lockf` child had
//  already exited: the notice never came. CI would sit there until the job timed out.
//  This asks the kernel directly, and gives up after a deadline measured in awake
//  time (the test Mac cycles clamshell sleep, and a wall-clock deadline expires
//  while it sleeps).
//

import Foundation
import Testing

/// wait up to `seconds` for `process` to exit, then kill it and wait a little more.
/// Returns its exit status, or nil if it had to be killed or its status is unknown.
@discardableResult
func waitBounded(_ process: Process, seconds: TimeInterval = 20) -> Int32? {
    let pid = process.processIdentifier
    let clock = { ProcessInfo.processInfo.systemUptime }
    var deadline = clock() + seconds
    var killed = false
    var reapedElsewhere = false
    while true {
        if !process.isRunning { return killed ? nil : process.terminationStatus }
        if !reapedElsewhere {
            var status: Int32 = 0
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid {
                if killed { return nil }
                let signal = status & 0x7f
                return signal == 0 ? (status >> 8) & 0xff : 128 + signal
            }
            // Foundation reaped it first; its notice should follow shortly
            if r == -1 && errno == ECHILD { reapedElsewhere = true }
            // r == 0: still our child and not yet exited, so the pid can't have been reused
            if r == 0, clock() >= deadline, !killed {
                kill(pid, SIGKILL)
                killed = true
                deadline = clock() + 5
                continue
            }
        }
        if clock() >= deadline && (killed || reapedElsewhere) { return nil }
        usleep(10_000)
    }
}

// MARK: - the wait itself

@Test func aBoundedWaitReturnsTheExitStatus() throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "exit 3"]
    try p.run()
    #expect(waitBounded(p) == 3)
}

@Test func aProcessThatWontExitIsKilledAtTheDeadline() throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sleep")
    p.arguments = ["60"]
    try p.run()
    let start = ProcessInfo.processInfo.systemUptime
    #expect(waitBounded(p, seconds: 0.5) == nil)
    #expect(ProcessInfo.processInfo.systemUptime - start < 10)
    #expect(kill(p.processIdentifier, 0) != 0 || !p.isRunning, "still running after the wait gave up")
}
