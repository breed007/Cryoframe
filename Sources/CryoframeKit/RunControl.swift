//
//  RunControl.swift
//  CryoframeKit
//
//  Cooperative cancellation for a running job: flips a flag and terminates the
//  external tool (hdiutil/ditto/rsync) currently in flight, so Stop takes effect
//  promptly instead of waiting for a multi-GB archive to finish.
//

import Foundation

public struct CancelledError: Error {
    /// what a step Stop let finish printed (see ProcessCommandRunner.letsFinish): an
    /// attach that went on to succeed, whose disk the caller's cleanup records and
    /// detaches. nil when nothing was let finish.
    public let finished: CommandResult?
    public init(finished: CommandResult? = nil) { self.finished = finished }
}

/// live progress for the UI. `fraction` is 0…1 within the current library when
/// known (archive bytes vs source, or transfer parts done), nil when indeterminate.
public struct RunProgress: Sendable {
    public var stage: BackupStage
    public var libraryIndex: Int        // 1-based
    public var libraryCount: Int
    public var fraction: Double?
    public var detail: String
    public var speed: Double?           // bytes/sec, smoothed (nil until known)
    public var eta: TimeInterval?       // seconds remaining at the current rate (nil if unknown)
    public var elapsed: TimeInterval?   // seconds since this phase started
    public init(stage: BackupStage, libraryIndex: Int, libraryCount: Int, fraction: Double?, detail: String,
                speed: Double? = nil, eta: TimeInterval? = nil, elapsed: TimeInterval? = nil) {
        self.stage = stage; self.libraryIndex = libraryIndex; self.libraryCount = libraryCount
        self.fraction = fraction; self.detail = detail
        self.speed = speed; self.eta = eta; self.elapsed = elapsed
    }
}

/// A step of a run that has no growing archive to measure: checking a copy, finishing
/// it, putting it in place. The engine says which step it is on and how far it has got,
/// and the run's progress shows that (see `RunProgress.init(step:…)`).
///
/// A live mirror's progress used to come only from its image growing on the drive. On
/// a first run that reached 99% when the copy was written, and then everything after it
/// (finishing the copy, flushing it, reading every byte of it back from the drive)
/// showed as 99% at zero bytes a second, for up to an hour on a microSD card.
public struct RunStep: Sendable, Equatable {
    public enum Unit: Sendable, Equatable { case items, bytes }
    public let title: String
    public let stage: BackupStage
    public let unit: Unit
    /// nil when the step can't say ahead how much there is
    public let total: UInt64?
    public var done: UInt64 = 0
    public let started: Date

    public init(title: String, stage: BackupStage, unit: Unit = .items, total: UInt64? = nil, done: UInt64 = 0,
                started: Date = Date()) {
        self.title = title; self.stage = stage; self.unit = unit; self.total = total; self.done = done
        self.started = started
    }
}

extension RunProgress {
    /// what the run shows during `step`. `speed` (bytes a second) only for a step
    /// counted in bytes; the time left from it and what remains.
    public init(step: RunStep, libraryIndex: Int, libraryCount: Int, speed: Double?, elapsed: TimeInterval?) {
        var fraction: Double?, detail: String, eta: TimeInterval?
        let rate = step.unit == .bytes ? speed : nil
        if let total = step.total, total > 0 {
            let done = min(step.done, total)
            fraction = min(0.99, Double(done) / Double(total))
            switch step.unit {
            case .bytes:
                detail = "\(step.title): \(JobExecutor.human(done)) of \(JobExecutor.human(total))"
                if let rate, rate > 0 { eta = Double(total - done) / rate }
            case .items:
                detail = "\(step.title): \(Self.count(done)) of \(Self.count(total)) items"
            }
        } else if step.done > 0 {
            detail = step.unit == .bytes ? "\(step.title): \(JobExecutor.human(step.done))"
                                         : "\(step.title): \(Self.count(step.done)) items"
        } else {
            detail = "\(step.title)…"
        }
        self.init(stage: step.stage, libraryIndex: libraryIndex, libraryCount: libraryCount, fraction: fraction,
                  detail: detail, speed: rate, eta: eta, elapsed: elapsed)
    }

    static func count(_ n: UInt64) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
    }
}

/// a step's speed in bytes a second, smoothed as the archive's is; nil for a step
/// counted in items, and starting afresh with each step
struct StepRate {
    private var title: String?, started: Date?
    private var lastDone: UInt64 = 0, lastTime = Date()
    private(set) var rate: Double?

    mutating func update(_ step: RunStep, now: Date = Date()) -> Double? {
        guard step.unit == .bytes else { return nil }
        if step.title != title || step.started != started {
            title = step.title; started = step.started
            lastDone = step.done; lastTime = now; rate = nil
            return nil
        }
        let dt = now.timeIntervalSince(lastTime)
        guard dt >= 0.1 else { return rate }
        let instant = Double(step.done >= lastDone ? step.done - lastDone : 0) / dt
        rate = rate.map { 0.65 * $0 + 0.35 * instant } ?? instant
        lastDone = step.done; lastTime = now
        return rate
    }
}

public final class RunControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var paused = false
    private var current: Process?
    private var watch: ToolWatch?
    private var currentStep: RunStep?
    /// how long a tool of this run may make no progress before it is stopped (see
    /// ToolWatchdog); shorter in tests
    public let quietLimit: TimeInterval

    public init(quietLimit: TimeInterval = ToolWatchdog.defaultQuietLimit) { self.quietLimit = quietLimit }

    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return paused }

    /// the step the run is on, if it has said (see RunStep)
    public var step: RunStep? { lock.lock(); defer { lock.unlock() }; return currentStep }

    /// told of each step as it begins, with the one it ends (tests follow a run with it)
    var stepChanged: (@Sendable (_ ended: RunStep?, _ begun: RunStep) -> Void)?

    /// start a step, replacing the one before
    public func begin(_ title: String, stage: BackupStage, unit: RunStep.Unit = .items, total: UInt64? = nil) {
        let s = RunStep(title: title, stage: stage, unit: unit, total: total)
        lock.lock(); let ended = currentStep; currentStep = s; let told = stepChanged; lock.unlock()
        told?(ended, s)
    }

    /// `n` more items or bytes of the current step done; safe from several threads
    public func advance(by n: UInt64 = 1) {
        lock.lock(); currentStep?.done += n; lock.unlock()
    }

    /// no step: the run's progress comes from what it writes again
    public func endStep() {
        lock.lock(); currentStep = nil; lock.unlock()
    }

    /// Stop: the tool in flight is ended the way the watchdog ends one (its process
    /// group gets SIGTERM, then SIGCONT so a paused one handles it, then SIGKILL after
    /// the grace period), so nothing it started is left running, and the run waits for
    /// its output no longer than for a stalled tool. Returns at once.
    ///
    /// Except a step that can't be stopped part way (an attach: see
    /// ProcessCommandRunner.letsFinish), which is let finish, and then cleaned up.
    public func cancel() {
        lock.lock(); cancelled = true; paused = false; let w = watch; lock.unlock()
        w?.stopForCancel()
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
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice   // never read, so never a pipe to fill
        guard (try? p.run()) != nil else { return [(root, "")] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        try? pipe.fileHandleForReading.close()      // releasing the Pipe doesn't (see ProcessCommandRunner)
        _ = p.waitForExit()
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

    /// register the watch over the process just launched, which Stop ends it
    /// through; returns false if Stop came first (the caller then ends the tool)
    func watching(_ w: ToolWatch) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if cancelled { return false }
        watch = w
        return true
    }

    func detach() {
        lock.lock(); current = nil; watch = nil; lock.unlock()
    }
}
