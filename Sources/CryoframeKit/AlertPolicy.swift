//
//  AlertPolicy.swift
//  CryoframeKit
//
//  What is worth waking someone's phone for. Kept apart from how the message is
//  delivered, because the decision is the part that has to be right: an alert that
//  never fires is indistinguishable from a backup that never failed.
//
//  Both the app and the headless agent make this call — the agent for the runs it
//  performs on a schedule, the app for the ones you start yourself — so the rules
//  live somewhere they can be tested rather than in whichever of them ran.
//

import Foundation

public enum AlertPolicy {

    public struct Payload: Sendable, Equatable {
        public let title: String
        public let body: String
        public let high: Bool          // ntfy priority / urgency
        public let tags: String

        public init(title: String, body: String, high: Bool, tags: String) {
            self.title = title; self.body = body; self.high = high; self.tags = tags
        }
    }

    /// nil when this run isn't worth an alert.
    /// `everyEvent` is the user's "tell me about every run" setting; without it only
    /// runs that need attention are sent.
    public static func payload(for record: RunRecord, everyEvent: Bool) -> Payload? {
        let ok = record.outcome == .verified || record.outcome == .completed
        let attention = record.outcome == .failed || record.outcome == .partial
        guard attention || (everyEvent && ok) else { return nil }
        return Payload(title: "Cryoframe — \(record.jobName)",
                       body: "\(ok ? "✓" : "⚠️") \(record.summary)",
                       high: attention,
                       tags: attention ? "warning" : "white_check_mark")
    }

    /// How many scheduled passes in a row may put a job off before that is worth an
    /// alert. One is routine (an hour on battery); three in a row is a backup that
    /// isn't happening.
    public static let deferralsBeforeAlert = 3

    /// nil unless this is the deferral that makes `deferralsBeforeAlert` in a row, or a
    /// later one while that alert is still owed (it couldn't be delivered: alerts not
    /// set up yet, the network down). Sent once per run of deferrals; once the job
    /// runs, nothing is owed.
    public static func payload(forDeferral record: RunRecord, count: Int) -> Payload? {
        guard record.outcome == .deferred,
              count == deferralsBeforeAlert || (count > deferralsBeforeAlert && record.deferralAlertPending == true) else { return nil }
        return Payload(title: "Cryoframe — \(record.jobName) isn't running",
                       body: "⏸ Put off: \(record.summary)",
                       high: false, tags: "hourglass")
    }

    /// Whether an alert reached the service: an HTTP answer in the 2xx range. A
    /// request that failed, or was refused (a wrong topic, a webhook gone), wasn't
    /// delivered, and used to be counted as sent all the same.
    public static func wasDelivered(_ response: URLResponse?) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    /// A scheduled job gone twice its interval without a good run. The agent decides
    /// how often to repeat it (see AlertThrottle); this decides what it says.
    public static func payload(forOverdue job: BackupJob, standing: ProtectionVerdict.Standing, now: Date) -> Payload? {
        let (late, critical) = standing.isLate
        guard late else { return nil }
        return Payload(title: "Cryoframe — \(job.name) is overdue",
                       body: "\(critical ? "⚠️" : "⏰") \(job.name) \(standing.reason(now: now)).",
                       high: critical, tags: critical ? "warning" : "alarm_clock")
    }

    /// The overdue alerts one pass of the scheduled agent sends: each enabled,
    /// scheduled job that is late (see ProtectionVerdict.Standing.isLate), at most
    /// once a day, and at once again when it turns critical. Each comes with the
    /// subject to record with `throttle` once it has actually been delivered.
    ///
    /// The throttle is cleared only when the job's latest run is a good one. It used
    /// to be cleared whenever the job wasn't overdue at that moment, and a failed run
    /// isn't overdue (it is failed), so an hourly job alternating failed and put-off
    /// runs was told it was overdue about every other hour.
    public static func overdueAlerts(jobs: [BackupJob], latest: [String: RunRecord], lastGood: [String: Date],
                                     unrecordedRuns: [String: Date] = [:], now: Date,
                                     throttle: AlertThrottle) -> [(payload: Payload, subject: String)] {
        var out: [(payload: Payload, subject: String)] = []
        for job in jobs where job.enabled && job.frequency.isRecurring {
            if latest[job.id]?.outcome.isGood == true {
                throttle.clear(job.id); throttle.clear(job.id + ".critical")
                continue
            }
            let standing = ProtectionVerdict.standing(of: job, latest: latest[job.id], lastGood: lastGood[job.id],
                                                      health: nil, now: now, unrecordedRun: unrecordedRuns[job.id])
            guard let p = payload(forOverdue: job, standing: standing, now: now) else { continue }
            let subject = standing.isLate.critical ? job.id + ".critical" : job.id
            guard throttle.shouldSend(subject, now: now) else { continue }
            out.append((p, subject))
        }
        return out
    }

    /// A destination about to run out. Only the "no room for the next run" case is
    /// sent: a job quietly keeping every version is worth showing in the app, but it
    /// is not worth a notification on someone's phone.
    public static func payload(forStorage finding: StoragePressure.Finding) -> Payload? {
        guard finding.kind == .tight else { return nil }
        let free = ByteCountFormatter.string(fromByteCount: Int64(finding.free), countStyle: .file)
        let run = ByteCountFormatter.string(fromByteCount: Int64(finding.runBytes), countStyle: .file)
        return Payload(title: "Cryoframe — \(finding.destination) is nearly full",
                       body: "⚠️ \(free) free, and \(finding.jobName) needs about \(run). The next backup is likely to fail.",
                       high: true, tags: "warning")
    }

    /// nil when this health check isn't worth an alert.
    public static func payload(forHealth record: HealthRecord, everyEvent: Bool) -> Payload? {
        // every copy was a cloud placeholder nobody downloaded: benign, and not the
        // same thing as a destination being offline.
        if record.archivesChecked == 0 && record.skipped > 0 {
            guard everyEvent else { return nil }
            return Payload(title: "Cryoframe — archive health",
                           body: "☁︎ \(record.jobName): \(record.skipped) cloud archive(s) not downloaded — skipped",
                           high: false, tags: "cloud")
        }
        if record.passed && record.archivesChecked > 0 {
            guard everyEvent else { return nil }
            return Payload(title: "Cryoframe — archive health",
                           body: "✓ \(record.jobName): \(record.archivesChecked) verified",
                           high: false, tags: "white_check_mark")
        }
        let body = record.archivesChecked == 0
            ? "⚠️ \(record.jobName): no archives found to check — is the target connected?"
            : "⚠️ \(record.jobName): \(record.failures.count) archive check(s) failed"
        return Payload(title: "Cryoframe — archive health", body: body, high: true, tags: "warning")
    }
}

/// Remembers when an alert about something was last sent, so the hourly agent says it
/// once a day rather than every time it looks. Kept in `defaults` under `key`, by
/// subject (a job id, a destination).
public struct AlertThrottle: @unchecked Sendable {
    let defaults: UserDefaults
    let key: String
    let interval: TimeInterval

    public init(defaults: UserDefaults = .standard, key: String, interval: TimeInterval = 24 * 60 * 60) {
        self.defaults = defaults; self.key = key; self.interval = interval
    }

    public func shouldSend(_ subject: String, now: Date) -> Bool {
        guard let last = (defaults.dictionary(forKey: key) as? [String: Double])?[subject] else { return true }
        return now.timeIntervalSince1970 - last >= interval || now.timeIntervalSince1970 < last
    }

    public func recordSent(_ subject: String, now: Date) {
        var map = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        map[subject] = now.timeIntervalSince1970
        defaults.set(map, forKey: key)
    }

    /// forget a subject that is fine again, so its next trouble is told at once
    public func clear(_ subject: String) {
        var map = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        guard map.removeValue(forKey: subject) != nil else { return }
        defaults.set(map, forKey: key)
    }
}
