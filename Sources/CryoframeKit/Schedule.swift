//
//  Schedule.swift
//  CryoframeKit
//
//  When a job fires. nextFireDate is pure (takes `after` + calendar), so the
//  scheduler is deterministic and testable with injected dates.
//

import Foundation

public enum BackupFrequency: Codable, Sendable, Equatable {
    case manual                                   // ad-hoc only
    case oneTime(Date)
    case everyHours(Int)
    case daily(hour: Int, minute: Int)

    /// the time between scheduled runs, for a job that repeats; nil for one that runs
    /// only when asked, or once
    public var interval: TimeInterval? {
        switch self {
        case .everyHours(let hours): return TimeInterval(max(1, hours)) * 3600
        case .daily: return 86_400
        case .manual, .oneTime: return nil
        }
    }

    /// runs on a repeating schedule
    public var isRecurring: Bool { interval != nil }

    /// the next scheduled instant strictly after `after`. nil if none (manual,
    /// or a one-time job already past `after`).
    public func nextFireDate(after reference: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .manual:
            return nil
        case .oneTime(let date):
            return date > reference ? date : nil
        case .everyHours(let hours):
            return calendar.date(byAdding: .hour, value: max(1, hours), to: reference)
        case .daily(let hour, let minute):
            return calendar.nextDate(after: reference,
                                     matching: DateComponents(hour: hour, minute: minute),
                                     matchingPolicy: .nextTime)
        }
    }
}

extension BackupJob {
    /// When the job's next backup runs, as far as can be told at `now`: its next
    /// scheduled time after its last run (`lastRun`; nil: it hasn't run), or `now`
    /// when that time has passed (the next scheduled pass runs it), the job is
    /// paused, or it runs only when asked. What a count of what the next backup
    /// deletes places that backup at.
    public func nextBackup(lastRun: Date?, now: Date, calendar: Calendar = .current) -> Date {
        guard enabled, let next = frequency.nextFireDate(after: lastRun ?? createdAt, calendar: calendar), next > now else { return now }
        return next
    }
}
