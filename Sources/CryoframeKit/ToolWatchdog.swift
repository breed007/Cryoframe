//
//  ToolWatchdog.swift
//  CryoframeKit
//
//  Stops a tool that has stopped making progress.
//
//  A run waits on its tools (hdiutil, rsync, ditto, tmutil) to finish, and some ways a
//  tool gets stuck never end: a network share that stops answering mid-write, a drive
//  that hangs, hdiutil waiting for an administrator's password nobody is there to
//  type. The run then held its snapshot, its lock and the job all night, and said
//  nothing.
//
//  Progress is judged the same way for every tool, from what the kernel counts for it
//  and the processes it started: CPU time, disk reads and writes, and anything it
//  prints. A tool that is working moves at least one of those; a tool blocked on a dead
//  share or a prompt moves none of them (measured: 0 ns of CPU and 0 bytes of I/O for
//  a blocked process over seconds). A slow transfer to a slow share still spends CPU on
//  every write, so it is never mistaken for a stuck one; only a whole quiet period with
//  none of it counts. The period defaults to fifteen minutes, and a paused run (Pause
//  stops the tool on purpose) is never counted as quiet.
//

import Foundation
import os

public enum ToolWatchdog {
    /// how long a tool may make no progress at all before it is stopped
    public static let defaultQuietLimit: TimeInterval = 15 * 60

    /// CPU time below this over a quiet period is noise, not work
    static let cpuFloorNs: UInt64 = 10_000_000

    /// how long a stopped tool gets to exit after SIGTERM before SIGKILL, and after
    /// that before the run stops waiting for it (a process stuck inside the kernel on
    /// a dead share can't be killed until the kernel lets go)
    static let termGrace: TimeInterval = 10
    static let abandonAfter: TimeInterval = 20

    /// CPU time (ns) and disk bytes read and written, for `pid` and every process
    /// under it; nil if `pid` can't be read (it has exited)
    static func activity(of pid: pid_t) -> (cpuNs: UInt64, io: UInt64)? {
        guard let own = usage(pid) else { return nil }
        var cpu = own.cpuNs, io = own.io
        var stack = children(pid), seen = Set<pid_t>([pid])
        while let child = stack.popLast(), seen.count < 512 {
            guard seen.insert(child).inserted, let u = usage(child) else { continue }
            cpu &+= u.cpuNs; io &+= u.io
            stack += children(child)
        }
        return (cpu, io)
    }

    private static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb); return tb
    }()

    private static func usage(_ pid: pid_t) -> (cpuNs: UInt64, io: UInt64)? {
        var info = rusage_info_v2()
        let r = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        guard r == 0 else { return nil }
        let ticks = info.ri_user_time &+ info.ri_system_time
        return (ticks / UInt64(timebase.denom) * UInt64(timebase.numer), info.ri_diskio_bytesread &+ info.ri_diskio_byteswritten)
    }

    private static func children(_ pid: pid_t) -> [pid_t] {
        var buf = [pid_t](repeating: 0, count: 128)
        let n = proc_listchildpids(pid, &buf, Int32(buf.count * MemoryLayout<pid_t>.size))
        return n > 0 ? Array(buf.prefix(min(Int(n), buf.count))) : []
    }
}

/// A tool the watchdog stopped: it made no progress for `quiet` seconds.
public struct ToolStalled: Error, Equatable {
    public let tool: String
    public let quiet: TimeInterval
    public init(tool: String, quiet: TimeInterval) { self.tool = tool; self.quiet = quiet }
}

extension ToolStalled: LocalizedError {
    public var errorDescription: String? {
        let minutes = Int((quiet / 60).rounded())
        let span = quiet >= 90 ? "\(minutes) minutes" : "\(Int(quiet.rounded())) seconds"
        return "\(tool) made no progress for \(span) and was stopped, so this run didn't finish. A drive or network share that stopped responding does this, and so does a tool waiting for a password nobody is there to type. Check that the destination is connected and responding, then run again."
    }
}

/// Watches one running tool, and stops it after `limit` seconds without progress.
final class ToolWatch: @unchecked Sendable {
    private let process: Process
    private let limit: TimeInterval
    private let control: RunControl?
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let done = DispatchSemaphore(value: 0)

    private struct State {
        var output: UInt64 = 0
        var stalledAfter: TimeInterval?
        var stoppedAt: TimeInterval?
    }

    init(_ process: Process, limit: TimeInterval, control: RunControl?) {
        self.process = process; self.limit = limit; self.control = control
    }

    /// the tool printed `n` more bytes
    func printed(_ n: Int) { state.withLock { $0.output &+= UInt64(n) } }

    /// how long the tool had been quiet when it was stopped; nil if it wasn't
    var stalledAfter: TimeInterval? { state.withLock { $0.stalledAfter } }

    /// when (system uptime) the watchdog began stopping the tool; nil if it hasn't
    var stoppedAt: TimeInterval? { state.withLock { $0.stoppedAt } }

    func start() {
        let pid = process.processIdentifier
        let tick = min(5, max(0.02, limit / 10))
        Thread.detachNewThread { [self] in
            let clock = { ProcessInfo.processInfo.systemUptime }
            var quietSince = clock()
            var last = (cpu: UInt64(0), io: UInt64(0), output: UInt64(0))
            if let a = ToolWatchdog.activity(of: pid) { last = (a.cpuNs, a.io, 0) }
            while done.wait(timeout: .now() + tick) == .timedOut {
                guard process.isRunning else { return }
                let output = state.withLock { $0.output }
                let now = ToolWatchdog.activity(of: pid)
                let cpu = now?.cpuNs ?? last.cpu, io = now?.io ?? last.io
                // Paused on purpose (its processes are stopped), or moving: not quiet.
                // CPU counts once it has added up to more than noise since the last
                // sign of progress, so a trickle of it is still seen.
                if control?.isPaused == true || output != last.output || io != last.io
                    || cpu &- last.cpu >= ToolWatchdog.cpuFloorNs {
                    quietSince = clock()
                    last = (cpu, io, output)
                    continue
                }
                let quiet = clock() - quietSince
                guard quiet >= limit else { continue }
                let at = clock()
                state.withLock { $0.stalledAfter = quiet; $0.stoppedAt = at }
                stop(pid)
                return
            }
        }
    }

    /// the tool exited or the run has moved on: stop watching
    func finish() { done.signal() }

    /// SIGTERM the tool and everything under it (woken first, if paused), then SIGKILL
    /// whatever is still there after the grace period
    private func stop(_ pid: pid_t) {
        let tree = RunControl.subtreeProcs(of: pid).map(\.pid)
        for p in tree { kill(p, SIGCONT) }
        for p in tree { kill(p, SIGTERM) }
        let deadline = ProcessInfo.processInfo.systemUptime + ToolWatchdog.termGrace
        while ProcessInfo.processInfo.systemUptime < deadline, tree.contains(where: { kill($0, 0) == 0 }) {
            Thread.sleep(forTimeInterval: 0.1)
        }
        for p in tree where kill(p, 0) == 0 { kill(p, SIGKILL) }
    }
}
