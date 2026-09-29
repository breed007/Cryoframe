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
        case check        // verifying, drilling or rehearsing the job's archives
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

    /// a run of the job, as opposed to a chore done for it (finishing a transfer,
    /// tidying scratch). Unknown counts as a run: it can't be told apart from one.
    public var isRun: Bool { trigger == .manual || trigger == .scheduled || trigger == .unknown }

    /// why a scheduled run waits while this chore holds its job; nil for a run.
    public var deferralReason: String? {
        switch trigger {
        case .resume:  "an interrupted transfer of this job is still finishing — it runs at the next check"
        case .cleanup: "this job's leftovers were being tidied — it runs at the next check"
        case .check:   "this job's archives were being checked — it runs at the next check"
        case .manual, .scheduled, .unknown: nil
        }
    }

    /// whether this holder is the current process.
    public var isThisProcess: Bool { pid == getpid() }

    /// how the job's badge reads while someone else runs it.
    public var runningLabel: String {
        switch trigger {
        case .scheduled: "running (scheduled)"
        case .resume:    "resuming a transfer"
        case .cleanup:   "tidying up"
        case .check:     "checking its archives"
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
            case .check:     "its archives are being checked — run it again once that's done"
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
        let deadline = Date().addingTimeInterval(wait)
        var replaced = 0
        while true {
            switch try attempt(path: path, jobID: jobID) {
            case .took(let fd):
                // stale stop requests name an earlier run; clear them before saying who
                // we are, so no request can name this run until it is known
                try? FileManager.default.removeItem(at: stopURL(jobID))
                let holder = RunHolder(pid: getpid(), trigger: trigger, runID: UUID().uuidString, startedAt: now)
                Self.write(holder, to: fd)
                HeldHere.shared.set(path, holder)
                return RunLease(locks: self, jobID: jobID, path: path, fd: fd, holder: holder)
            case .busy(let holder):
                if Date() >= deadline { throw RunLockError.alreadyRunning(holder) }
                Thread.sleep(forTimeInterval: 0.1)
            case .replaced:
                replaced += 1
                if replaced > 20 { throw RunLockError.unavailable("its lock file keeps being replaced") }
            }
        }
    }

    private enum Attempt { case took(Int32), busy(RunHolder), replaced }

    private func attempt(path: String, jobID: String) throws -> Attempt {
        // This process's own locks are known here even once their file is gone: the
        // lock is the inode, and a removed path no longer leads to it.
        if let mine = HeldHere.shared.holder(path) { return .busy(mine) }
        // O_CLOEXEC: a tool this run launches must never inherit the lock. If it did,
        // a crash of this process would leave the lock held by an orphaned rsync.
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw RunLockError.unavailable(String(cString: strerror(errno))) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let err = errno
            close(fd)
            guard err == EWOULDBLOCK || err == EINTR else { throw RunLockError.unavailable(String(cString: strerror(err))) }
            return .busy(readHolder(jobID) ?? .unknown)
        }
        // What we locked must still be what the path names. If the file was removed
        // (and perhaps re-created) between open and flock, we hold a lock nobody else
        // can see; let go and take the one at the path.
        guard Self.sameFile(fd, path) else { flock(fd, LOCK_UN); close(fd); return .replaced }
        return .took(fd)
    }

    static func sameFile(_ fd: Int32, _ path: String) -> Bool {
        var a = stat(), b = stat()
        guard fstat(fd, &a) == 0, stat(path, &b) == 0 else { return false }
        return a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }

    static func write(_ holder: RunHolder, to fd: Int32) {
        guard let data = try? JSONEncoder().encode(holder) else { return }
        ftruncate(fd, 0)
        _ = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, data.count, 0) }
    }

    // MARK: looking without taking

    public enum Look: Equatable, Sendable {
        case free
        case held(RunHolder)
        case unreadable(String)       // the lock can't be read, so nobody can say
    }

    /// what is known about the job's lock, without taking it: a probe that briefly
    /// took the lock would make a run starting at that instant think the job was busy.
    public func look(_ jobID: String) -> Look {
        if let mine = HeldHere.shared.holder(lockURL(jobID).path) { return .held(mine) }
        let fd = open(lockURL(jobID).path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            let err = errno
            // no lock file (or no folder yet): never locked, so nobody holds it
            return err == ENOENT ? .free : .unreadable(String(cString: strerror(err)))
        }
        defer { close(fd) }
        var probe = flock()
        probe.l_type = Int16(F_WRLCK)
        probe.l_whence = Int16(SEEK_SET)
        probe.l_start = 0
        probe.l_len = 0
        // On Darwin, F_GETLK reports a conflicting flock(2) lock as well as record locks.
        guard fcntl(fd, F_GETLK, &probe) == 0 else { return .unreadable(String(cString: strerror(errno))) }
        guard probe.l_type != Int16(F_UNLCK) else { return .free }
        return .held(readHolder(jobID) ?? .unknown)
    }

    /// the job's current holder, or nil when nobody is running it or the lock can't
    /// be read. For showing runs; anything that must not act while a run might be
    /// going (cleanup) uses look(_:) and treats unreadable as busy.
    public func holder(of jobID: String) -> RunHolder? {
        if case .held(let h) = look(jobID) { return h }
        return nil
    }

    /// the jobs a run (not a chore) holds right now, in any process.
    public func runningJobIDs(among jobIDs: [String]) -> Set<String> {
        Set(holders(of: jobIDs).filter { $0.value.isRun }.keys)
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
    private let path: String
    private let mutex = NSLock()
    private var fds: [Int32]                  // the lock file, and any it was re-created as
    private var watcher: DispatchSourceTimer?
    private var keeper: DispatchSourceTimer?

    /// how often a held lock checks that its file is still there.
    static let keepInterval: TimeInterval = 1

    init(locks: RunLocks, jobID: String, path: String, fd: Int32, holder: RunHolder) {
        self.locks = locks; self.jobID = jobID; self.path = path; self.fds = [fd]; self.holder = holder
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + Self.keepInterval, repeating: Self.keepInterval)
        timer.setEventHandler { [weak self] in self?.keepLockFile() }
        keeper = timer
        timer.resume()
    }

    deinit { release() }

    /// If the lock file is removed while the run holds it (someone clears the app's
    /// support folder mid-backup), the run's lock is on an inode no path leads to,
    /// and another process could lock a fresh file and start a second run. Put the
    /// file back and lock it too. The window is at most one check; this process's own
    /// takers are covered with no window at all (see HeldHere).
    func keepLockFile() {
        mutex.lock(); defer { mutex.unlock() }
        guard let current = fds.last, !RunLocks.sameFile(current, path) else { return }
        try? FileManager.default.createDirectory(at: locks.directory, withIntermediateDirectories: true)
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0, RunLocks.sameFile(fd, path) else { close(fd); return }
        RunLocks.write(holder, to: fd)
        fds.append(fd)
    }

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
        keeper?.cancel(); keeper = nil
        guard !fds.isEmpty else { return }
        HeldHere.shared.remove(path)
        for fd in fds {
            ftruncate(fd, 0)                   // nobody should read our identity after we're gone
            flock(fd, LOCK_UN)
            close(fd)
        }
        fds = []
    }

    public var isHeld: Bool { mutex.lock(); defer { mutex.unlock() }; return !fds.isEmpty }

    /// what a crash does to the lock: the descriptor goes away without an unlock,
    /// and the process's memory of holding it goes with it. For tests that prove
    /// nothing else keeps the lock alive.
    func closeWithoutUnlocking() {
        mutex.lock(); defer { mutex.unlock() }
        watcher?.cancel(); watcher = nil
        keeper?.cancel(); keeper = nil
        HeldHere.shared.remove(path)
        for fd in fds { close(fd) }
        fds = []
    }
}

/// the run locks this process holds, by lock file path.
final class HeldHere: @unchecked Sendable {
    static let shared = HeldHere()
    private let lock = NSLock()
    private var held: [String: RunHolder] = [:]
    func holder(_ path: String) -> RunHolder? { lock.lock(); defer { lock.unlock() }; return held[path] }
    func set(_ path: String, _ holder: RunHolder) { lock.lock(); held[path] = holder; lock.unlock() }
    func remove(_ path: String) { lock.lock(); held[path] = nil; lock.unlock() }
}

/// How a check of a job's archives went, given the job's run lock.
public enum CheckUnderLock<T> {
    case done(T)
    /// a run (or another check) held the job throughout the wait
    case busy(RunHolder)
    /// the lock couldn't be opened, so nobody can say whether a run is writing
    case unavailable(String)
}

extension RunLocks {
    /// Check a job's archives holding its lock, as a chore (a scheduled run that finds
    /// it held waits for the next pass). Verifications, drills and rehearsals read the
    /// newest version; without the lock they could read one a run was still writing
    /// and report a good backup as broken. Waits up to `wait` for a run to finish.
    public func whileChecking<T>(jobID: String, wait: TimeInterval = 0, _ body: () throws -> T) rethrows -> CheckUnderLock<T> {
        let lease: RunLease
        do {
            lease = try acquire(jobID: jobID, trigger: .check, wait: wait)
        } catch RunLockError.alreadyRunning(let holder) {
            return .busy(holder)
        } catch {
            return .unavailable(error.localizedDescription)
        }
        defer { lease.release() }
        return .done(try body())
    }

    /// Run `body` holding the job's lock, releasing it however `body` ends. Throws
    /// RunLockError.alreadyRunning, without running `body`, when the job is busy.
    public func withLock<T>(jobID: String, trigger: RunHolder.Trigger, wait: TimeInterval = 0,
                            _ body: (RunLease) throws -> T) throws -> T {
        let lease = try acquire(jobID: jobID, trigger: trigger, wait: wait)
        defer { lease.release() }
        return try body(lease)
    }
}
