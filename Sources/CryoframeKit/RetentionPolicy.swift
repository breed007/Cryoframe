//
//  RetentionPolicy.swift
//  CryoframeKit
//
//  Sealed archives are versioned: each run writes a timestamped folder under the
//  library, so you can restore a point in time. The retention policy decides which
//  old versions to prune after a run — keep everything, keep the last N, or a
//  grandfather-father-son scheme (so many dailies, weeklies, monthlies). Live
//  mirrors are single-copy and aren't versioned.
//

import Foundation

public enum RetentionPolicy: Codable, Sendable, Equatable {
    case keepAll
    case keepLast(Int)
    case gfs(daily: Int, weekly: Int, monthly: Int)
}

/// the timestamp folder name for a version: `2026-06-25-143000`. Sorts lexically in
/// chronological order and round-trips to a Date.
public enum VersionStamp {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()
    public static func string(_ date: Date) -> String { formatter.string(from: date) }
    public static func date(_ name: String) -> Date? { formatter.date(from: name) }
}

/// given the dates of all existing versions, return the ones to DELETE under
/// `policy`. Pure and total — the engine maps these back to folders. The newest
/// versions are always kept (keepLast(n)/gfs select from newest down).
public func retentionPrune(_ versions: [Date], policy: RetentionPolicy,
                           calendar: Calendar = Calendar(identifier: .gregorian)) -> Set<Date> {
    let sorted = versions.sorted(by: >)            // newest first
    switch policy {
    case .keepAll:
        return []
    case .keepLast(let n):
        return Set(sorted.dropFirst(max(0, n)))
    case .gfs(let daily, let weekly, let monthly):
        var keep = Set<Date>()
        keep.formUnion(newestPerBucket(sorted, limit: daily) { calendar.startOfDay(for: $0) })
        keep.formUnion(newestPerBucket(sorted, limit: weekly) { bucketStart($0, [.yearForWeekOfYear, .weekOfYear], calendar) })
        keep.formUnion(newestPerBucket(sorted, limit: monthly) { bucketStart($0, [.year, .month], calendar) })
        return Set(versions).subtracting(keep)
    }
}

/// keep the newest version in each of the newest `limit` distinct buckets.
private func newestPerBucket(_ sorted: [Date], limit: Int, key: (Date) -> Date) -> [Date] {
    guard limit > 0 else { return [] }
    var seen = Set<Date>(), kept: [Date] = []
    for v in sorted {
        let k = key(v)
        if seen.insert(k).inserted {
            kept.append(v)
            if seen.count >= limit { break }
        }
    }
    return kept
}

private func bucketStart(_ date: Date, _ components: Set<Calendar.Component>, _ calendar: Calendar) -> Date {
    calendar.date(from: calendar.dateComponents(components, from: date)) ?? date
}
