//
//  SharedJSONFile.swift
//  CryoframeKit
//
//  A small JSON file that the app and the scheduled agent both change. Each change is
//  a read, change and write under an flock(2) on a lock file beside it, so neither
//  process writes over what the other just added, and the file is written whole
//  (a temporary file renamed over it), so a reader never sees half of one.
//
//  A file that is there but can't be decoded (a record a later version wrote, before
//  a return to this one) used to read as empty, and the next change wrote that back:
//  the run history, the check history or the overdue ledger, gone in one append. Its
//  contents are now copied beside it first (see UnreadableCopy), and it is replaced
//  only once that copy is there. These files have no way to tell anyone, and the run
//  history, the upload records and the overdue ledger have to go on being kept, so
//  the change goes ahead rather than being refused as JobStore refuses its own. A
//  file whose bytes can't be read at all can't be copied, and is never written over.
//

import Foundation

/// (job, destination), as the per-destination files key it
public struct DestinationKey: Hashable, Sendable {
    public let jobID: String
    public let targetID: String
    public init(jobID: String, targetID: String) { self.jobID = jobID; self.targetID = targetID }
    var string: String { "\(jobID)|\(targetID)" }

    /// every (job, destination) the jobs have now
    public static func all(_ jobs: [BackupJob]) -> Set<DestinationKey> {
        Set(jobs.flatMap { job in job.targets.map { DestinationKey(jobID: job.id, targetID: $0.id) } })
    }
}

final class SharedJSONFile<Value: Codable>: @unchecked Sendable {
    let url: URL
    private let lockURL: URL
    private let empty: @Sendable () -> Value
    /// one change at a time in this process; flock(2) is per open file, so two
    /// instances here (or the app and the agent) also wait for each other
    private let lock = NSLock()

    init(url: URL, lockName: String, empty: @escaping @Sendable () -> Value) {
        self.url = url
        self.lockURL = url.deletingLastPathComponent().appendingPathComponent(lockName)
        self.empty = empty
    }

    /// the file as it is now; empty when it is missing or can't be read
    func read() -> Value {
        if case .value(let value) = find() { return value }
        return empty()
    }

    private enum Found {
        case missing
        /// there, and its bytes can't be read
        case unreadable
        /// there, and not what this version writes
        case undecodable(Data)
        case value(Value)
    }

    private func find() -> Found {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        guard let value = try? JSONDecoder().decode(Value.self, from: data) else { return .undecodable(data) }
        return .value(value)
    }

    /// Change the file under the lock. `change` returns whether it changed anything;
    /// nothing is written when it didn't, or over a file that can't be read and
    /// couldn't be copied beside itself first (see the top).
    @discardableResult
    func update<T>(_ change: (inout Value) -> (changed: Bool, result: T)) -> T {
        lock.lock(); defer { lock.unlock() }
        let fd = takeFileLock()
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        var value = empty()
        var writable = true
        switch find() {
        case .missing: break
        case .unreadable: writable = false
        case .undecodable(let data): writable = UnreadableCopy.keep(data, from: url)
        case .value(let found): value = found
        }
        let (changed, result) = change(&value)
        if changed, writable { write(value) }
        return result
    }

    private func write(_ value: Value) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(value) { try? data.write(to: url, options: .atomic) }
    }

    /// The lock file, locked, or -1 when it can't be had within a few seconds. A
    /// holder only reads and writes a small file, so a lock held that long belongs to
    /// a process that hung; the change goes ahead rather than never being made.
    private func takeFileLock() -> Int32 {
        try? FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return -1 }
        let deadline = Date().addingTimeInterval(10)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, Date() < deadline else { close(fd); return -1 }
            usleep(2_000)
        }
        return fd
    }
}

/// What a file held that this version can't decode, kept beside it before anything is
/// written in its place.
enum UnreadableCopy {
    /// `data`, the contents of `url`, copied to `<name>.unreadable-<time, in UTC>` beside
    /// it, unless a copy of these same contents is there already. Whether a copy of
    /// them is there afterwards.
    @discardableResult
    static func keep(_ data: Data, from url: URL) -> Bool {
        let dir = url.deletingLastPathComponent(), prefix = url.lastPathComponent + ".unreadable-"
        let copies = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix(prefix) }
        guard !copies.contains(where: { (try? Data(contentsOf: dir.appendingPathComponent($0))) == data }) else { return true }
        let f = ISO8601DateFormatter()                          // 2026-10-29T155833Z
        f.formatOptions = [.withFullDate, .withTime, .withTimeZone]
        return (try? data.write(to: dir.appendingPathComponent(prefix + f.string(from: Date())), options: .withoutOverwriting)) != nil
    }
}
