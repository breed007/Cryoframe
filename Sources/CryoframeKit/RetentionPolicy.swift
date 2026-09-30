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
///
/// THE NEWEST VERSION IS NEVER RETURNED, whatever the policy says. A retention
/// setting that selects nothing — keepLast(0), or a GFS with every bucket at zero,
/// both of which the UI could express — otherwise means "delete every backup",
/// and the engine would carry that out on the version it had just finished
/// writing. No policy should be able to say that, and no future policy should be
/// able to reintroduce it, so the floor lives here in the one function every
/// caller shares rather than at the call sites.
///
/// Nor is any version in `keeping` (see KnownGood): the policy counts versions, not
/// whether they restore, and a week of versions that failed their drills would
/// otherwise push the last one that passed out of a keep-the-last-seven policy.
public func retentionPrune(_ versions: [Date], policy: RetentionPolicy, keeping: Set<Date> = [],
                           calendar: Calendar = Calendar(identifier: .gregorian)) -> Set<Date> {
    let sorted = versions.sorted(by: >)            // newest first
    var doomed: Set<Date>
    switch policy {
    case .keepAll:
        return []
    case .keepLast(let n):
        doomed = Set(sorted.dropFirst(max(0, n)))
    case .gfs(let daily, let weekly, let monthly):
        var keep = Set<Date>()
        keep.formUnion(newestPerBucket(sorted, limit: daily) { calendar.startOfDay(for: $0) })
        keep.formUnion(newestPerBucket(sorted, limit: weekly) { bucketStart($0, [.yearForWeekOfYear, .weekOfYear], calendar) })
        keep.formUnion(newestPerBucket(sorted, limit: monthly) { bucketStart($0, [.year, .month], calendar) })
        doomed = Set(versions).subtracting(keep)
    }
    if let newest = sorted.first { doomed.remove(newest) }
    let kept = Set(keeping.map(VersionStamp.string))
    return doomed.filter { !kept.contains(VersionStamp.string($0)) }
}

/// The version of a library last known to restore.
public enum KnownGood {
    /// The newest of `versions` a restore drill passed; if no version has passed
    /// one, the newest whose checksum check (or recovery rehearsal) passed. nil when
    /// none has passed a check. `records` newest first, as HealthStore.all() gives them.
    ///
    /// A version that passed and later failed still counts: keeping one version more
    /// than the policy asks costs space, and deleting the last one that ever restored
    /// can cost the backup.
    ///
    /// The checks are matched by the library folder's identity `key` where they
    /// recorded one, else by name, the library's or one it had (see
    /// ArchiveAssurance.lastVerified): by name alone, a renamed library found no
    /// check, and retention deleted the one version known to restore.
    public static func version(of library: String, key: String? = nil, formerNames: [String] = [],
                               among versions: [Date], records: [HealthRecord]) -> Date? {
        var checksum: Date?
        for v in versions.sorted(by: >) {
            switch ArchiveAssurance.lastVerified(library: library, key: key, formerNames: formerNames, version: v, in: records)?.level {
            case .drill?: return v
            case .checksum?: if checksum == nil { checksum = v }
            case nil: break
            }
        }
        return checksum
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
