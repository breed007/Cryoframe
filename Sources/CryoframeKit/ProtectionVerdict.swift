//
//  ProtectionVerdict.swift
//  CryoframeKit
//
//  One answer to "am I protected?", computed from the jobs, their latest runs and
//  their latest archive checks. The dashboard hero, the menu-bar glyph and the
//  menu's status line all show this one verdict, so they can never disagree. The
//  app adds only the color.
//

import Foundation

public struct ProtectionVerdict: Sendable, Equatable {
    public enum Level: Sendable, Equatable { case protected, attention, critical, idle }

    public var level: Level
    public var title: String
    public var subtitle: String
    public var glyph: String

    public init(level: Level, title: String, subtitle: String, glyph: String) {
        self.level = level; self.title = title; self.subtitle = subtitle; self.glyph = glyph
    }

    /// - Parameters:
    ///   - lastRecords: the latest run per job id.
    ///   - lastHealth: the latest archive check per job id.
    ///   - runningCount: how many jobs are running right now.
    ///   - lastGood: when each job last finished a good run (verified or completed),
    ///     however long ago; the latest record alone can't say, once a run was
    ///     stopped, put off or failed after it. A job missing here falls back to its
    ///     latest record if that one was good.
    ///   - now: the time to judge how long ago that was.
    ///   - scheduleOn: whether the scheduled agent is switched on. Off, no job runs on
    ///     its own.
    ///   - unrecordedRuns: runs the job store saw finish that the history no longer
    ///     holds (see `unrecordedRun`), by job id.
    ///   - lastCopies: job id → destination id → when it last got a complete copy
    ///     (ScheduleState.lastCopy), for rotating drives
    public static func compute(jobs: [BackupJob], lastRecords: [String: RunRecord],
                               lastHealth: [String: HealthRecord], runningCount: Int,
                               lastGood: [String: Date] = [:], now: Date = Date(),
                               scheduleOn: Bool = true, unrecordedRuns: [String: Date] = [:],
                               lastCopies: [String: [String: Date]] = [:]) -> ProtectionVerdict {
        guard !jobs.isEmpty else {
            return .init(level: .idle, title: "No backup jobs yet",
                         subtitle: "Create a job to start protecting a library.",
                         glyph: "plus.circle")
        }
        if runningCount > 0 {
            let n = runningCount
            return .init(level: .idle, title: "Backing up…",
                         subtitle: "\(n) \(n == 1 ? "job is" : "jobs are") running right now.",
                         glyph: "arrow.triangle.2.circlepath")
        }
        let standings = jobs.map { job in
            (job: job, standing: standing(of: job, latest: lastRecords[job.id],
                                          lastGood: lastGood[job.id] ?? goodDate(lastRecords[job.id]),
                                          health: lastHealth[job.id], now: now, unrecordedRun: unrecordedRuns[job.id],
                                          awayTooLong: RotationRules.awayTooLong(job, lastCopies: lastCopies[job.id] ?? [:], now: now)))
        }
        let healthy = standings.filter { $0.standing == .healthy }.count
        let neverRan = standings.filter { $0.standing == .neverRan }

        let failed = standings.filter { $0.standing == .failed }
        if let f = failed.first {
            return .init(level: .critical,
                         title: failed.count == 1 ? "1 backup failed" : "\(failed.count) backups failed",
                         subtitle: "\(f.job.name) didn't finish — open it to see why. \(Self.healthyOf(healthy, jobs.count)).",
                         glyph: "xmark.octagon.fill")
        }
        let critical = standings.filter { $0.standing.level == .critical }
        if let c = critical.first {
            return .init(level: .critical,
                         title: critical.count == 1 ? "1 backup is overdue" : "\(critical.count) backups are overdue",
                         subtitle: "\(c.job.name) \(c.standing.reason(now: now)) — open it to see why. \(Self.healthyOf(healthy, jobs.count)).",
                         glyph: "clock.badge.exclamationmark")
        }
        // Nothing runs on its own with the agent switched off, however recent the
        // last backups are.
        let scheduled = jobs.filter { $0.enabled && $0.frequency.isRecurring }
        if !scheduleOn, !scheduled.isEmpty {
            let n = scheduled.count
            return .init(level: .attention, title: "Scheduled backups are off",
                         subtitle: "\(n == 1 ? "1 job" : "\(n) jobs") won't run on \(n == 1 ? "its" : "their") schedule until they're turned back on in Settings.",
                         glyph: "exclamationmark.triangle.fill")
        }
        let attention = standings.filter { $0.standing.level == .attention }
        // the most pressing reason first; among equals, the first job
        if let b = attention.min(by: { $0.standing.rank < $1.standing.rank }) {
            return .init(level: .attention,
                         title: attention.count == 1 ? "1 job needs attention" : "\(attention.count) jobs need attention",
                         subtitle: "\(b.job.name) \(b.standing.reason(now: now)) — open it to fix. \(Self.healthyOf(healthy, jobs.count, fully: true)).",
                         glyph: "exclamationmark.triangle.fill")
        }
        if !neverRan.isEmpty && healthy == 0 {
            return .init(level: .idle, title: "Ready to back up",
                         subtitle: neverRan.count == 1 ? "Your job hasn't run yet — press Run now, or wait for its schedule."
                                                       : "\(neverRan.count) jobs haven't run yet.",
                         glyph: "clock.badge.checkmark")
        }
        let extra = neverRan.isEmpty ? "" : neverRan.count == 1 ? " 1 job hasn't run yet." : " \(neverRan.count) jobs haven't run yet."
        return .init(level: .protected, title: "You're protected",
                     subtitle: "\(healthy) \(healthy == 1 ? "job" : "jobs") healthy · \(lastBackupText(jobs: jobs, lastRecords: lastRecords).lowercased()) · nothing needs your attention.\(extra)",
                     glyph: "checkmark.shield.fill")
    }

    /// "1 of 3 jobs are healthy", and "0 of 1 job is healthy" for a lone job
    static func healthyOf(_ healthy: Int, _ total: Int, fully: Bool = false) -> String {
        let jobs = total == 1 ? "job is" : "jobs are"
        let how = fully ? "fully healthy" : "healthy"
        return "\(healthy) of \(total) \(jobs) \(how)"
    }

    // MARK: - one job

    /// How long a job may go without a good run.
    public enum Staleness {
        /// a scheduled job is overdue once twice its interval has passed without a good run
        public static let overdueFactor = 2.0
        /// and critical once that has gone on for a week
        public static let critical: TimeInterval = 7 * 86_400
        /// A job you run by hand has no schedule to fall behind, so it is never
        /// overdue or critical for its age, and never sends an alert about it. But a
        /// newest copy more than a month old is worth a look on the dashboard.
        public static let manual: TimeInterval = 30 * 86_400
    }

    /// What one job's record says about it.
    public enum Standing: Equatable, Sendable {
        case healthy
        /// never run at all, and not overdue
        case neverRan
        /// the latest run failed
        case failed
        /// no good run for twice the schedule's interval; `lastGood` nil if never.
        /// `note` says what the latest attempt came to, if anything.
        case overdue(lastGood: Date?, since: Date, critical: Bool, note: String?)
        /// switched off: the schedule skips it
        case paused
        case partial
        case checkFailed
        /// the latest run was stopped before it finished
        case stopped
        /// runs only when asked, and its newest good copy is over a month old
        case notBackedUpLately(lastGood: Date)
        /// has tried, and never finished a good run (put off, say); not overdue yet
        case noGoodRunYet(note: String?)
        /// a drive in a rotation hasn't had a copy for longer than the rotation allows:
        /// its name, since when, and its last copy (nil: none since it joined)
        case driveAway(name: String, since: Date, lastCopy: Date?)
        /// ran (the job store says so), but the history no longer says how: 1.5
        /// trimmed it without keeping the last good run. Critical only if the job
        /// hasn't run at all for twice its interval and a week.
        case noRecordOfGoodRun(lastRan: Date, critical: Bool)

        public var level: Level {
            switch self {
            case .healthy: return .protected
            case .neverRan: return .idle
            case .failed: return .critical
            case .overdue(_, _, let critical, _): return critical ? .critical : .attention
            case .noRecordOfGoodRun(_, let critical): return critical ? .critical : .attention
            case .paused, .partial, .checkFailed, .stopped, .notBackedUpLately, .noGoodRunYet, .driveAway: return .attention
            }
        }

        /// which attention reason the dashboard names first
        var rank: Int {
            switch self {
            case .overdue: return 0
            case .noRecordOfGoodRun: return 1
            case .partial: return 1
            case .driveAway: return 1
            case .checkFailed: return 2
            case .stopped: return 3
            case .noGoodRunYet: return 4
            case .paused: return 5
            case .notBackedUpLately: return 6
            default: return 9
            }
        }

        /// the reason as it follows the job's name
        public func reason(now: Date) -> String {
            switch self {
            case .healthy: return "is healthy"
            case .neverRan: return "hasn't run yet"
            case .failed: return "didn't finish"
            case .overdue(let lastGood, let since, _, let note):
                let age = ProtectionVerdict.age(from: since, to: now)
                let base = lastGood == nil ? "hasn't finished a backup since it was set up \(age) ago"
                                           : "hasn't had a good backup in \(age)"
                return note.map { "\(base) (\($0))" } ?? base
            case .paused: return "is paused, so its schedule doesn't run it"
            case .partial: return "finished as a partial backup"
            case .driveAway(let name, let since, let last):
                let age = ProtectionVerdict.age(from: since, to: now)
                return last == nil ? "hasn't had a copy on \(name) since it joined the rotation \(age) ago; connect it for its turn"
                                   : "hasn't had a copy on \(name) in \(age); connect it for its turn"
            case .checkFailed: return "failed an archive check"
            case .stopped: return "was stopped before it finished"
            case .notBackedUpLately(let lastGood):
                return "hasn't been backed up in \(ProtectionVerdict.age(from: lastGood, to: now)); it runs only when you press Run now"
            case .noGoodRunYet(let note):
                return note.map { "hasn't finished a backup yet (\($0))" } ?? "hasn't finished a backup yet"
            case .noRecordOfGoodRun(let ran, _):
                return "has no record of its last good backup (older history wasn't kept); it last ran \(ProtectionVerdict.age(from: ran, to: now)) ago"
            }
        }

        /// late enough for an alert: overdue, or not run at all for a week
        public var isLate: (late: Bool, critical: Bool) {
            switch self {
            case .overdue(_, _, let critical, _): return (true, critical)
            case .noRecordOfGoodRun(_, let critical): return (critical, critical)
            default: return (false, false)
            }
        }
    }

    /// A job's standing. A stopped or put-off run is not a success: only a verified or
    /// completed run counts as the job's last good one, and a job is judged by how long
    /// ago that was. A partial run doesn't count either: part of what the job covers
    /// wasn't backed up.
    ///
    /// `unrecordedRun`: a run the job store saw finish and the history no longer
    /// holds. With no good run on record, that run is judged unknown rather than
    /// absent: a job upgraded from 1.5, whose good runs were trimmed out of the
    /// history, read as never backed up, critical, with a high-priority alert.
    ///
    /// `awayTooLong`: the job's rotating drives gone longer than their rotation allows
    /// (RotationRules.awayTooLong). A drive that's away isn't a fault, and the runs
    /// that skip it are good ones; one away too long is worth a look.
    public static func standing(of job: BackupJob, latest: RunRecord?, lastGood: Date?,
                                health: HealthRecord?, now: Date, unrecordedRun: Date? = nil,
                                awayTooLong: [RotationRules.AwayTooLong] = []) -> Standing {
        if latest?.outcome == .failed { return .failed }
        if !job.enabled { return .paused }
        if lastGood == nil, let ran = unrecordedRun {
            let age = now.timeIntervalSince(ran)
            let critical = job.frequency.interval.map { age >= $0 * Staleness.overdueFactor && age >= Staleness.critical } ?? false
            return .noRecordOfGoodRun(lastRan: ran, critical: critical)
        }
        let note = latest.flatMap(attemptNote)
        if let interval = job.frequency.interval {
            let since = lastGood ?? job.createdAt
            let age = now.timeIntervalSince(since)
            if age >= interval * Staleness.overdueFactor {
                return .overdue(lastGood: lastGood, since: since, critical: age >= Staleness.critical, note: note)
            }
        }
        if latest?.outcome == .partial { return .partial }
        if let away = awayTooLong.first { return .driveAway(name: away.name, since: away.since, lastCopy: away.lastCopy) }
        if let health, !health.passed { return .checkFailed }
        if latest?.outcome == .cancelled { return .stopped }
        guard latest != nil else { return .neverRan }
        guard let lastGood else { return .noGoodRunYet(note: note) }
        if job.frequency == .manual, now.timeIntervalSince(lastGood) >= Staleness.manual {
            return .notBackedUpLately(lastGood: lastGood)
        }
        return .healthy
    }

    /// The run the job store last saw finish (`lastRun`, recorded at the end of every
    /// finished run, whatever came of it), if the history holds no record of it.
    /// Before 1.6 the history was trimmed at 200 records with nothing kept per job.
    /// `records`: this job's records.
    public static func unrecordedRun(lastRun: Date?, records: [RunRecord]) -> Date? {
        guard let lastRun else { return nil }
        // lastRun is the time the run started; its record runs from then to its finish
        let held = records.contains { r in
            r.outcome != .deferred && lastRun >= r.startedAt.addingTimeInterval(-300) && lastRun <= r.finishedAt.addingTimeInterval(300)
        }
        return held ? nil : lastRun
    }

    /// what the latest attempt came to, when it wasn't a finished run
    static func attemptNote(_ record: RunRecord) -> String? {
        switch record.outcome {
        case .deferred: return record.summary.isEmpty ? "put off" : "put off: \(record.summary)"
        case .cancelled: return "its last run was stopped"
        case .partial: return "its last run was partial"
        default: return nil
        }
    }

    /// the finish time of a good run
    static func goodDate(_ record: RunRecord?) -> Date? {
        guard let record, record.outcome.isGood else { return nil }
        return record.finishedAt
    }

    /// "3 days", "11 hours": how long, for these sentences
    static func age(from: Date, to now: Date) -> String {
        let hours = Int(max(0, now.timeIntervalSince(from)) / 3600)
        if hours < 48 { return hours == 1 ? "1 hour" : "\(hours) hours" }
        return "\(hours / 24) days"
    }

    // MARK: - shared derived values

    /// the newest run that left a usable copy behind, across all jobs.
    public static func lastSuccessfulRecord(jobs: [BackupJob], lastRecords: [String: RunRecord]) -> RunRecord? {
        jobs.compactMap { lastRecords[$0.id] }
            .filter { [.verified, .completed, .partial].contains($0.outcome) }
            .max(by: { $0.finishedAt < $1.finishedAt })
    }

    public static func lastSuccess(jobs: [BackupJob], lastRecords: [String: RunRecord]) -> Date? {
        lastSuccessfulRecord(jobs: jobs, lastRecords: lastRecords)?.finishedAt
    }

    public static func lastBackupText(jobs: [BackupJob], lastRecords: [String: RunRecord]) -> String {
        guard let d = lastSuccess(jobs: jobs, lastRecords: lastRecords) else { return "Never" }
        return d.formatted(.relative(presentation: .named)).localizedCapitalized
    }

    /// distinct libraries across all jobs, by name.
    public static func libraryCount(_ jobs: [BackupJob]) -> Int {
        Set(jobs.flatMap { $0.libraries.map(\.displayName) }).count
    }

    /// distinct destinations across all jobs, by path.
    public static func destinationCount(_ jobs: [BackupJob]) -> Int {
        Set(jobs.flatMap { $0.targets.map(\.destinationDir.path) }).count
    }
}
