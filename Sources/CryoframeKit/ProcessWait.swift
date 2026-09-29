//
//  ProcessWait.swift
//  CryoframeKit
//
//  Waiting for a tool to exit without trusting Foundation's termination notice.
//

import Foundation

extension Process {
    /// the exit status reported when a process has exited but its status can't be read
    static let unknownExitStatus: Int32 = -1

    /// Wait for the process to exit, and return its exit status (the signal number if a
    /// signal ended it, as `terminationStatus` does).
    ///
    /// `waitUntilExit` waits for Foundation's termination notice, not for the process.
    /// In the test suite one never came: a child long gone, and the wait still blocked
    /// 23 minutes later. In a backup run that is a run hung forever with its snapshot
    /// held and its job locked. This asks the kernel instead, and if Foundation reaped
    /// the process first but never says so, gives up waiting on the notice after five
    /// seconds and reports the status as unknown (a failure) rather than hang. A tool
    /// that is genuinely still running is waited for as long as it runs.
    func waitForExit() -> Int32 {
        let pid = processIdentifier
        var pause: useconds_t = 500
        var reapedElsewhereAt: TimeInterval?
        while true {
            if !isRunning { return terminationStatus }
            if let since = reapedElsewhereAt {
                if ProcessInfo.processInfo.systemUptime - since > 5 { return Self.unknownExitStatus }
            } else {
                var status: Int32 = 0
                let r = waitpid(pid, &status, WNOHANG)
                if r == pid {
                    let signal = status & 0x7f
                    return signal == 0 ? (status >> 8) & 0xff : signal
                }
                // Foundation reaped it first; its notice should follow
                if r == -1, errno == ECHILD { reapedElsewhereAt = ProcessInfo.processInfo.systemUptime }
            }
            usleep(pause)
            pause = min(pause * 2, 20_000)
        }
    }
}
