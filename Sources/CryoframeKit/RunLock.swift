//
//  RunLock.swift
//  CryoframeKit
//
//  One run per job, across every process. The app and the scheduled agent are
//  separate processes, and neither could see the other's runs: "Run now" could start
//  a second copy of a job the agent was already running, both writing the same
//  archive folder or mirror image.
//
//  Each job has a lock file. A run holds an exclusive flock(2) on it for as long as
//  it runs, so the kernel drops the lock the instant the process exits, however it
//  exits: nothing stale is left for the next run to trip over. The file's contents
//  say who holds it (pid, what started it, a run id) so the other process can show
//  the run and ask it to stop. Lock files are never deleted: unlinking a lock file
//  lets two processes each lock a different inode of the "same" file.
//
//  Stop across processes is a file too: `<job>.stop` naming the run id to stop. The
//  holder polls for it and cancels its own run, which keeps every teardown path in
//  the process that owns the snapshot, the mounts and the tools.
//

import Foundation

/// who holds a job's run lock.
public struct RunHolder: Codable, Sendable, Equatable {
    public enum Trigger: String, Codable, Sendable {
        case manual       // Run now in the app
        case scheduled    // the launchd agent
        case resume       // finishing an interrupted transfer
        case cleanup      // tidying the job's leftovers while nothing runs
        case unknown      // held, but the holder hasn't said who it is (yet)
    }

    public var pid: Int32            // 0 when unknown
    public var trigger: Trigger
    public var runID: String         // "" when unknown
    public var startedAt: Date

    public init(pid: Int32, trigger: Trigger, runID: String, startedAt: Date) {
        self.pid = pid; self.trigger = trigger; self.runID = runID; self.startedAt = startedAt
    }

    static let unknown = RunHolder(pid: 0, trigger: .unknown, runID: "", startedAt: .distantPast)

    /// whether this holder is the current process.
    public var isThisProcess: Bool { pid == getpid() }

    /// how the job's badge reads while someone else runs it.
    public var runningLabel: String {
        switch trigger {
        case .scheduled: "running (scheduled)"
        case .resume:    "resuming a transfer"
        case .cleanup:   "tidying up"
        case .manual, .unknown: "running"
        }
    }
}

public enum RunLockError: Error, Equatable {
    case alreadyRunning(RunHolder)
    case unavailable(String)          // the lock file couldn't be opened at all
}

extension RunLockError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .alreadyRunning(let h):
            switch h.trigger {
            case .scheduled: "already running (scheduled)"
            case .resume:    "already running (resuming an interrupted transfer)"
            case .cleanup, .manual, .unknown: "already running"
            }
        case .unavailable(let why): "couldn't check whether this job is already running — \(why)"
        }
    }
}

public final class RunLocks: @unchecked Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// the per-user lock directory both the app and the agent use.
    public static func standard() -> RunLocks {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.cryoframe", isDirectory: true)
        return RunLocks(directory: base.appendingPathComponent("run-locks", isDirectory: true))
    }

    func lockURL(_ jobID: String) -> URL { directory.appendingPathComponent(Self.safe(jobID) + ".lock") }
    func stopURL(_ jobID: String) -> URL { directory.appendingPathComponent(Self.safe(jobID) + ".stop") }

    /// job ids are UUIDs; anything else is made safe to use as one path component.
    static func safe(_ id: String) -> String {
        let s = String(id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "_" })
        return s.isEmpty || s.allSatisfy({ $0 == "." }) ? "_" : s
    }

    // MARK: taking the lock

    /// Take the job's run lock, or report who has it. `wait` rides out a momentary
    /// holder (a leftover tidy, say) so it isn't mistaken for a run: a real run
    /// holds the lock for minutes, so a short wait changes nothing for that case.
    public func acquire(jobID: String, trigger: RunHolder.Trigger, wait: TimeInterval = 0,
                        now: Date = Date()) throws -> RunLease {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = lockURL(jobID).path
        // O_CLOEXEC: a tool this run launches must never inherit the lock. If it did,
        // a crash of this process would leave the lock held by an orphaned rsync.
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw RunLockError.unavailable(String(cString: strerror(errno))) }
        let deadline = Date().addingTimeInterval(wait)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let err = errno
            guard err == EWOULDBLOCK || err == EINTR else {
                close(fd); throw RunLockError.unavailable(String(cString: strerror(err)))
            }
            if Date() >= deadline {
                close(fd)
                throw RunLockError.alreadyRunning(readHolder(jobID) ?? .unknown)
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        // stale stop requests name an earlier run; clear them before saying who we
        // are, so no request can name this run until it is known
        try? FileManager.default.removeItem(at: stopURL(jobID))
        let holder = RunHolder(pid: getpid(), trigger: trigger, runID: UUID().uuidString, startedAt: now)
        if let data = try? JSONEncoder().encode(holder) {
            ftruncate(fd, 0)
            _ = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, data.count, 0) }
        }
        return RunLease(locks: self, jobID: jobID, fd: fd, holder: holder)
    }

    // MARK: looking without taking

    /// the job's current holder, or nil when nobody is running it. Only looks: a
    /// probe that briefly took the lock would make a run starting at that instant
    /// think the job was busy.
    public func holder(of jobID: String) -> RunHolder? {
        let fd = open(lockURL(jobID).path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }                    // never locked: nobody holds it
        defer { close(fd) }
        var probe = flock()
        probe.l_type = Int16(F_WRLCK)
        probe.l_whence = Int16(SEEK_SET)
        probe.l_start = 0
        probe.l_len = 0
        // On Darwin, F_GETLK reports a conflicting flock(2) lock as well as record locks.
        guard fcntl(fd, F_GETLK, &probe) == 0, probe.l_type != Int16(F_UNLCK) else { return nil }
        return readHolder(jobID) ?? .unknown
    }

    /// holders for the jobs that are running now, by job id.
    public func holders(of jobIDs: [String]) -> [String: RunHolder] {
        var out: [String: RunHolder] = [:]
        for id in jobIDs { if let h = holder(of: id) { out[id] = h } }
        return out
    }

    private func readHolder(_ jobID: String) -> RunHolder? {
        guard let data = try? Data(contentsOf: lockURL(jobID)), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(RunHolder.self, from: data)
    }

    // MARK: stopping someone else's run

    /// ask whoever is running this job to stop. Returns false when nobody is, or the
    /// holder can't be identified (it hasn't written its run id yet: try again).
    @discardableResult
    public func requestStop(jobID: String) -> Bool {
        guard let h = holder(of: jobID), !h.runID.isEmpty else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(h.runID.utf8).write(to: stopURL(jobID), options: .atomic)
            return true
        } catch { return false }
    }

    func stopRequested(jobID: String, runID: String) -> Bool {
        guard let data = try? Data(contentsOf: stopURL(jobID)) else { return false }
        return String(decoding: data, as: UTF8.self) == runID
    }
}

/// a held run lock. Release it when the run ends; if the process dies first, the
/// kernel releases it.
public final class RunLease: @unchecked Sendable {
    public let jobID: String
    public let holder: RunHolder
    private let locks: RunLocks
    private let mutex = NSLock()
    private var fd: Int32
    private var watcher: DispatchSourceTimer?

    init(locks: RunLocks, jobID: String, fd: Int32, holder: RunHolder) {
        self.locks = locks; self.jobID = jobID; self.fd = fd; self.holder = holder
    }

    deinit { release() }

    /// whether another process has asked this run to stop.
    public var stopRequested: Bool { locks.stopRequested(jobID: jobID, runID: holder.runID) }

    /// call `handler` (once, on a background queue) when another process asks this
    /// run to stop. Polls, because the request can come from any process at any time
    /// and a one-second answer to Stop is plenty.
    public func onStopRequest(every interval: TimeInterval = 1, _ handler: @escaping @Sendable () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self, self.stopRequested else { return }
            self.mutex.lock(); let t = self.watcher; self.watcher = nil; self.mutex.unlock()
            t?.cancel()
            try? FileManager.default.removeItem(at: self.locks.stopURL(self.jobID))
            handler()
        }
        mutex.lock(); watcher?.cancel(); watcher = timer; mutex.unlock()
        timer.resume()
    }

    /// give the lock back. Safe to call more than once.
    public func release() {
        mutex.lock(); defer { mutex.unlock() }
        watcher?.cancel(); watcher = nil
        guard fd >= 0 else { return }
        ftruncate(fd, 0)                       // nobody should read our identity after we're gone
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    public var isHeld: Bool { mutex.lock(); defer { mutex.unlock() }; return fd >= 0 }

    /// what a crash does to the lock: the descriptor goes away without an unlock.
    /// For tests that prove nothing else keeps the lock alive.
    func closeWithoutUnlocking() {
        mutex.lock(); defer { mutex.unlock() }
        watcher?.cancel(); watcher = nil
        guard fd >= 0 else { return }
        close(fd)
        fd = -1
    }
}

extension RunLocks {
    /// Run `body` holding the job's lock, releasing it however `body` ends. Throws
    /// RunLockError.alreadyRunning, without running `body`, when the job is busy.
    public func withLock<T>(jobID: String, trigger: RunHolder.Trigger, wait: TimeInterval = 0,
                            _ body: (RunLease) throws -> T) throws -> T {
        let lease = try acquire(jobID: jobID, trigger: trigger, wait: wait)
        defer { lease.release() }
        return try body(lease)
    }
}
