//
//  RunControl.swift
//  CryoframeKit
//
//  Cooperative cancellation for a running job: flips a flag and terminates the
//  external tool (hdiutil/ditto/rsync) currently in flight, so Stop takes effect
//  promptly instead of waiting for a multi-GB archive to finish.
//

import Foundation

public struct CancelledError: Error { public init() {} }

/// live progress for the UI. `fraction` is 0…1 within the current library when
/// known (archive bytes vs source, or transfer parts done), nil when indeterminate.
public struct RunProgress: Sendable {
    public var stage: BackupStage
    public var libraryIndex: Int        // 1-based
    public var libraryCount: Int
    public var fraction: Double?
    public var detail: String
    public init(stage: BackupStage, libraryIndex: Int, libraryCount: Int, fraction: Double?, detail: String) {
        self.stage = stage; self.libraryIndex = libraryIndex; self.libraryCount = libraryCount
        self.fraction = fraction; self.detail = detail
    }
}

public final class RunControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var paused = false
    private var current: Process?

    public init() {}

    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return paused }

    public func cancel() {
        lock.lock(); cancelled = true; paused = false; let p = current; lock.unlock()
        if let pid = p?.processIdentifier, pid > 0 {
            for pr in Self.subtreeProcs(of: pid) { kill(pr.pid, SIGCONT) }   // wake so terminate can land
        }
        p?.terminate()
    }

    /// suspend the in-flight tool *and its children* — a tool like `ditto`/`rsync`
    /// does its own I/O, so the whole subtree must freeze for bytes to stop.
    ///
    /// Refuses `hdiutil`: its `diskimages-helper` child segfaults if it's frozen
    /// even briefly (the kernel disk-image driver loses sync), which corrupts the
    /// archive. Returns false in that case so the UI never shows Pause for a DMG.
    @discardableResult
    public func pause() -> Bool {
        lock.lock(); let p = current; lock.unlock()
        if let pid = p?.processIdentifier, pid > 0 {
            let procs = Self.subtreeProcs(of: pid)
            guard !procs.contains(where: { Self.unsuspendable($0.comm) }) else { return false }
            lock.lock(); paused = true; lock.unlock()
            for pr in procs { kill(pr.pid, SIGSTOP) }        // root first, tight loop
        } else {
            // no external tool in flight (our chunked transfer is pure file I/O) —
            // cooperative pause: the ship loop honors `paused` between parts.
            lock.lock(); paused = true; lock.unlock()
        }
        return true
    }

    public func resume() {
        lock.lock(); paused = false; let p = current; lock.unlock()
        guard let pid = p?.processIdentifier, pid > 0 else { return }
        for pr in Self.subtreeProcs(of: pid).reversed() { kill(pr.pid, SIGCONT) }  // children first
    }

    /// tools whose process tree must never be SIGSTOPped — they crash when frozen.
    private static func unsuspendable(_ comm: String) -> Bool {
        comm.contains("hdiutil") || comm.contains("diskimages-helper")
    }

    /// `root` and every descendant with its executable path, read fresh via `ps`
    /// (works even when processes are already stopped). DFS order, root first.
    static func subtreeProcs(of root: pid_t) -> [(pid: pid_t, comm: String)] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,ppid=,comm="]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return [(root, "")] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var children: [pid_t: [pid_t]] = [:]
        var comm: [pid_t: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 2, let pid = pid_t(f[0]), let ppid = pid_t(f[1]) else { continue }
            children[ppid, default: []].append(pid)
            comm[pid] = f.count >= 3 ? f[2...].joined(separator: " ") : ""
        }
        var result: [(pid_t, String)] = [], stack = [root]
        while let pid = stack.popLast() {
            result.append((pid, comm[pid] ?? ""))
            if let kids = children[pid] { stack.append(contentsOf: kids) }
        }
        return result
    }

    /// block the caller while paused (used before launching each command/part).
    func waitWhilePaused() {
        while true {
            lock.lock(); let (pz, cx) = (paused, cancelled); lock.unlock()
            if cx || !pz { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    /// register the process about to run; returns false if already cancelled.
    /// Launching while paused is prevented by `waitWhilePaused()` before the call.
    func attach(_ process: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if cancelled { return false }
        current = process
        return true
    }

    func detach() {
        lock.lock(); current = nil; lock.unlock()
    }
}
