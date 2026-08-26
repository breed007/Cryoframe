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
