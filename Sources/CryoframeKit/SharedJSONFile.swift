//
//  SharedJSONFile.swift
//  CryoframeKit
//
//  A small JSON file that the app and the scheduled agent both change. Each change is
//  a read, change and write under an flock(2) on a lock file beside it, so neither
//  process writes over what the other just added, and the file is written whole
//  (a temporary file renamed over it), so a reader never sees half of one.
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
        guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Value.self, from: data) else {
            return empty()
        }
        return value
    }

    /// Change the file under the lock. `change` returns whether it changed anything;
    /// nothing is written when it didn't.
    @discardableResult
    func update<T>(_ change: (inout Value) -> (changed: Bool, result: T)) -> T {
        lock.lock(); defer { lock.unlock() }
        let fd = takeFileLock()
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        var value = read()
        let (changed, result) = change(&value)
        if changed { write(value) }
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
