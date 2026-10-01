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

    /// how long Stop waits for a step it lets finish (see ProcessCommandRunner.letsFinish)
    /// before the run stops waiting for it. The watchdog still watches it meanwhile.
    static let finishAfterStop: TimeInterval = 5 * 60

    /// the process group `pid` leads, if it leads one of its own: one this process
    /// isn't in, so signaling it can never reach Cryoframe itself. Foundation's
    /// Process starts every tool as the leader of a new group, which everything the
    /// tool starts joins unless it makes one of its own (pinned in ToolWatchdogTests).
    /// nil when that isn't so: the tool is then stopped by the processes under it.
    static func ownGroup(of pid: pid_t) -> pid_t? {
        let group = getpgid(pid)
        return pid > 1 && group == pid && group != getpgrp() ? group : nil
    }

    /// CPU time (ns) and disk bytes read and written, for `pid`, every process under
    /// it, and every process seen under it before that has since left (`known`, kept
    /// by the caller: pid and start time, so a later process given the pid isn't
    /// counted); nil if `pid` can't be read (it has exited).
    ///
    /// The ones that left count because hdiutil's work is done by a diskimages-helper it
    /// starts, not by hdiutil itself (measured: 0.01 s of CPU for hdiutil over a 30 s
    /// create). The helper runs under hdiutil while it works, until an attach hands it
    /// to launchd (a group of its own, parent 1) while hdiutil still waits.
    static func activity(of pid: pid_t, known: inout [pid_t: TimeInterval]) -> (cpuNs: UInt64, io: UInt64)? {
        guard let own = usage(pid) else { return nil }
        var cpu = own.cpuNs, io = own.io
        var stack = children(pid), seen = Set<pid_t>([pid])
        for (p, started) in known {
            guard let id = ProcessIdentity.of(pid: p), abs(id.startedAt - started) < 0.000_5 else { known[p] = nil; continue }
            stack.append(p)
        }
        while let child = stack.popLast(), seen.count < 512 {
            guard seen.insert(child).inserted, let u = usage(child) else { continue }
            cpu &+= u.cpuNs; io &+= u.io
            if known[child] == nil, known.count < 512, let id = ProcessIdentity.of(pid: child) { known[child] = id.startedAt }
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
    /// a step Stop and the watchdog never signal (see ProcessCommandRunner.letsFinish)
    let letFinish: Bool
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let done = DispatchSemaphore(value: 0)

    private struct State {
        var output: UInt64 = 0
        var stalledAfter: TimeInterval?
        var stoppedAt: TimeInterval?
        var stopAskedAt: TimeInterval?
        var group: pid_t?
    }

    init(_ process: Process, limit: TimeInterval, control: RunControl?, letFinish: Bool = false) {
        self.process = process; self.limit = limit; self.control = control; self.letFinish = letFinish
    }

    /// the tool printed `n` more bytes
    func printed(_ n: Int) { state.withLock { $0.output &+= UInt64(n) } }

    /// how long the tool had been quiet when it was stopped; nil if it wasn't
    var stalledAfter: TimeInterval? { state.withLock { $0.stalledAfter } }

    /// when (system uptime) the watchdog or Stop began stopping the tool; nil if
    /// neither has
    var stoppedAt: TimeInterval? { state.withLock { $0.stoppedAt } }

    /// when (system uptime) Stop was pressed during a step it lets finish; nil if it
    /// wasn't
    var stopAskedAt: TimeInterval? { state.withLock { $0.stopAskedAt } }

    func start() {
        let pid = process.processIdentifier
        // read now, while the tool surely runs: once it has exited and been reaped,
        // its group (which outlives it while anything it started is left) can't be
        // read from it
        let group = ToolWatchdog.ownGroup(of: pid)
        state.withLock { $0.group = group }
        let tick = min(5, max(0.02, limit / 10))
        Thread.detachNewThread { [self] in
            let clock = { ProcessInfo.processInfo.systemUptime }
            var quietSince = clock()
            var last = (cpu: UInt64(0), io: UInt64(0), output: UInt64(0))
            var known: [pid_t: TimeInterval] = [:]
            if let a = ToolWatchdog.activity(of: pid, known: &known) { last = (a.cpuNs, a.io, 0) }
            while done.wait(timeout: .now() + tick) == .timedOut {
                guard process.isRunning, stoppedAt == nil else { return }      // ended, or Stop is ending it
                let output = state.withLock { $0.output }
                let now = ToolWatchdog.activity(of: pid, known: &known)
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
                guard begin(stalledAfter: quiet) else { return }
                // one let finish is only given up on: signaled, it leaves its image
                // attached anyway, with no record of whose it is
                if !letFinish { stop(pid, group: group) }
                return
            }
        }
    }

    /// the tool exited or the run has moved on: stop watching
    func finish() { done.signal() }

    /// Stop was pressed: end the tool the way the watchdog does (see stop), on a
    /// thread of its own, so Stop returns at once. Its run waits for the tool's output
    /// no longer than it does for a tool the watchdog stopped.
    ///
    /// A step Stop lets finish is left running, and only noted; its run waits for it
    /// (see ProcessCommandRunner.run).
    func stopForCancel() {
        if letFinish {
            let at = ProcessInfo.processInfo.systemUptime
            state.withLock { if $0.stopAskedAt == nil { $0.stopAskedAt = at } }
            return
        }
        guard begin(stalledAfter: nil) else { return }
        let pid = process.processIdentifier, group = state.withLock { $0.group }
        Thread.detachNewThread { [self] in stop(pid, group: group) }
    }

    /// mark the tool as being stopped, once: false if the watchdog or Stop already is
    private func begin(stalledAfter quiet: TimeInterval?) -> Bool {
        let at = ProcessInfo.processInfo.systemUptime
        return state.withLock {
            guard $0.stoppedAt == nil else { return false }
            $0.stoppedAt = at; $0.stalledAfter = quiet
            return true
        }
    }

    /// SIGTERM the tool's process group and anything else under it, then wake it (a
    /// paused tool handles the SIGTERM before it runs anything more), then SIGKILL
    /// whatever of it is still there after the grace period.
    ///
    /// The group, not just the processes read under the tool: a tool woken from a
    /// pause runs on between the read and the signal, and a child it starts then (or
    /// leaves behind as it exits, handed to launchd) isn't under it, but is in its
    /// group. Left running, that child held the tool's output open, and the run
    /// waited out the time allowed for a tool stuck in the kernel.
    private func stop(_ pid: pid_t, group: pid_t?) {
        // anything under the tool that left its group (or all of it, if the tool has
        // no group of its own to signal)
        let strays = RunControl.subtreeProcs(of: pid).map(\.pid).filter { p in group.map { getpgid(p) != $0 } ?? true }
        func signal(_ sig: Int32) {
            if let group { kill(-group, sig) }
            for p in strays { kill(p, sig) }
        }
        func running() -> Bool {
            (group.map { kill(-$0, 0) == 0 } ?? false) || strays.contains { kill($0, 0) == 0 }
        }
        signal(SIGTERM)
        signal(SIGCONT)
        let deadline = ProcessInfo.processInfo.systemUptime + ToolWatchdog.termGrace
        while ProcessInfo.processInfo.systemUptime < deadline, running() { Thread.sleep(forTimeInterval: 0.1) }
        if running() { signal(SIGKILL) }
    }
}
