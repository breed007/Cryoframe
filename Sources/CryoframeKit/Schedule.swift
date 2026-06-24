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
