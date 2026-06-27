//
//  Scheduler.swift
//  CryoframeKit
//
//  Computes which jobs are due. A job is due when its next fire after its
//  reference point (last run, or creation if never run) has arrived. Pure +
//  date-injected, so it's fully testable.
//

import Foundation

public struct ScheduleState: Codable, Sendable, Equatable {
    public var jobs: [BackupJob]
    public var lastRun: [String: Date]
    /// number of jobs that failed to decode and were skipped on the last load — so the
    /// UI can tell the user "3 jobs couldn't be read" instead of silently showing none.
    public var droppedJobs: Int = 0

    public init(jobs: [BackupJob] = [], lastRun: [String: Date] = [:]) {
        self.jobs = jobs; self.lastRun = lastRun
    }

    enum CodingKeys: String, CodingKey { case jobs, lastRun }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // decode jobs through a non-throwing wrapper so ONE malformed or schema-
        // incompatible job can't wipe the whole list (the old whole-array decode did
        // exactly that). Bad elements decode to nil and are counted, not fatal.
        let wrapped = (try? c.decode([Failable<BackupJob>].self, forKey: .jobs)) ?? []
        self.jobs = wrapped.compactMap(\.value)
        self.droppedJobs = wrapped.count - self.jobs.count
        self.lastRun = (try? c.decode([String: Date].self, forKey: .lastRun)) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jobs, forKey: .jobs)
        try c.encode(lastRun, forKey: .lastRun)
    }
}

/// wraps a Decodable so a single bad element decodes to nil instead of throwing and
/// taking the whole array down with it.
private struct Failable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

public struct Scheduler: Sendable {
    public init() {}

    public func isDue(_ job: BackupJob, lastRun: Date?, now: Date, calendar: Calendar = .current) -> Bool {
        let reference = lastRun ?? job.createdAt
        guard let next = job.frequency.nextFireDate(after: reference, calendar: calendar) else { return false }
        return next <= now
    }

    public func dueJobs(_ state: ScheduleState, now: Date, calendar: Calendar = .current) -> [BackupJob] {
        state.jobs.filter { $0.enabled && isDue($0, lastRun: state.lastRun[$0.id], now: now, calendar: calendar) }
    }
}
