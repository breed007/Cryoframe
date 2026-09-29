//
//  ProcessIdentity.swift
//  CryoframeKit
//
//  A process, identified so that a recycled pid can't impersonate it: the pid plus
//  the moment the kernel started that process. Used to decide whether whoever made
//  a snapshot is still around to need it.
//

import Foundation

public struct ProcessIdentity: Codable, Sendable, Equatable {
    public var pid: Int32
    public var startedAt: TimeInterval      // seconds since 1970, to the microsecond

    public init(pid: Int32, startedAt: TimeInterval) { self.pid = pid; self.startedAt = startedAt }

    /// the running process with this pid, or nil if there is none.
    public static func of(pid: Int32) -> ProcessIdentity? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0,
              info.kp_proc.p_pid == pid else { return nil }
        let t = info.kp_proc.p_un.__p_starttime
        return ProcessIdentity(pid: pid, startedAt: Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000)
    }

    public static var current: ProcessIdentity? { of(pid: getpid()) }

    /// true while this exact process is running; false once it has exited, even if
    /// its pid has since been handed to another process.
    public var isAlive: Bool {
        guard let now = Self.of(pid: pid) else { return false }
        return abs(now.startedAt - startedAt) < 0.000_5
    }
}
