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
    public init(jobs: [BackupJob] = [], lastRun: [String: Date] = [:]) {
        self.jobs = jobs; self.lastRun = lastRun
    }
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
