//
//  NoticeContent.swift
//  CryoframeKit
//
//  What a notification on this Mac says, and whether it is posted at all. The app
//  posts these while it runs, and the scheduled agent posts the same ones when the
//  app isn't open, so the text and the policy live here, where both use them and
//  tests can pin them, rather than in whichever process happened to post.
//

import Foundation

/// The Notifications setting: never, on failure (the default), or on every run.
public enum NotifyPolicy: String, Sendable { case never, failure, all }

public struct NoticeContent: Sendable, Equatable {
    /// the notification's identifier. A run's is its record id, so a run is never
    /// shown twice, whichever process posts it.
    public let id: String
    public let title: String
    public let body: String
    public let sound: Bool

    public init(id: String, title: String, body: String, sound: Bool = false) {
        self.id = id; self.title = title; self.body = body; self.sound = sound
    }

    /// a finished run: failed and partial runs unless notifications are off, good ones
    /// on "every run" only. A run that found decay in a mirror has failed (see
    /// RunRecord.make), and its summary says so. What the run says beside its result,
    /// such as history removed to make room, follows on a line of its own.
    public static func run(_ record: RunRecord, policy: NotifyPolicy) -> NoticeContent? {
        let ok = record.outcome == .verified || record.outcome == .completed
        switch policy {
        case .never: return nil
        case .failure: guard record.outcome == .failed || record.outcome == .partial else { return nil }
        case .all: guard ok || record.outcome == .failed || record.outcome == .partial else { return nil }
        }
        var body = "\(ok ? "✓" : "⚠️") \(record.summary)"
        if let note = record.warning, !note.isEmpty { body += "\n" + note }
        return NoticeContent(id: record.id, title: "Cryoframe — \(record.jobName)", body: body)
    }

    /// an archive health check or recovery rehearsal. Failures unless notifications
    /// are off; clean results, and checks where every copy was skipped, on "every run"
    /// only. `jobHasRun`: a check that found nothing on a job that has never run means
    /// nothing has been made yet, not that the destination is missing, so it says nothing.
    public static func health(_ record: HealthRecord, policy: NotifyPolicy, jobHasRun: Bool) -> NoticeContent? {
        if record.archivesChecked == 0, !jobHasRun { return nil }
        let allSkipped = record.archivesChecked == 0 && record.skipped > 0
        let clean = record.passed && record.archivesChecked > 0
        if allSkipped || clean { guard policy == .all else { return nil } } else { guard policy != .never else { return nil } }
        let body: String, n = record.archivesChecked
        if allSkipped {
            let skip = record.skipPhrase ?? "\(record.skipped) not checked"
            body = "☁︎ \(skip) — skipped"
        } else if n == 0 {
            body = "⚠️ no archives found to check — is the target connected?"
        } else if record.passed {
            body = "✓ \(n) archive\(n == 1 ? "" : "s") verified"
        } else {
            let first = record.failures.first ?? "corruption detected"
            body = "⚠️ archive check failed — \(first)"
        }
        return NoticeContent(id: "health-\(record.id)", title: "Cryoframe — \(record.jobName)", body: body)
    }

    /// a stopped check that found failures (see AlertPolicy.payload(forStopped:)),
    /// unless notifications are off
    public static func stopped(_ check: CanceledCheck, policy: NotifyPolicy) -> NoticeContent? {
        guard policy != .never, let p = AlertPolicy.payload(forStopped: check) else { return nil }
        return NoticeContent(id: "stopped-\(check.id)", title: "Cryoframe — \(check.jobName)", body: p.body)
    }

    /// an overdue job (see AlertPolicy.overdueAlerts), unless notifications are off.
    /// Each is a new notice; how often one is posted is the overdue ledger's call.
    public static func overdue(_ payload: AlertPolicy.Payload, subject: String, policy: NotifyPolicy,
                               now: Date) -> NoticeContent? {
        guard policy != .never else { return nil }
        return NoticeContent(id: "overdue-\(subject)-\(Int(now.timeIntervalSince1970))", title: payload.title,
                             body: payload.body, sound: payload.high)
    }

    /// a destination too full for the next run (see AlertPolicy.payload(forStorage:)),
    /// unless notifications are off
    public static func storage(_ finding: StoragePressure.Finding, policy: NotifyPolicy, now: Date) -> NoticeContent? {
        guard policy != .never, let p = AlertPolicy.payload(forStorage: finding) else { return nil }
        return NoticeContent(id: "storage-\(finding.destination)-\(Int(now.timeIntervalSince1970))", title: p.title,
                             body: p.body, sound: p.high)
    }
}

/// Whether the scheduled agent posts its notices on this Mac.
public enum AgentNotices {
    /// what macOS says of Cryoframe's notifications
    public enum Authorization: Sendable {
        case authorized, provisional, denied, notDetermined, unknown
        /// macOS will show what is posted (provisional: quietly, in Notification Center)
        public var allowsPosting: Bool { self == .authorized || self == .provisional }
    }

    /// Only when macOS allows them (the agent never asks; the app asks at launch), and
    /// only when the app isn't open: an open app posts them itself, as it sees the
    /// agent's records appear in the history.
    public static func shouldPost(appOpen: Bool, authorization: Authorization) -> Bool {
        !appOpen && authorization.allowsPosting
    }
}

/// A wait for a callback that may never come, given up after a time.
public enum BoundedWait {
    /// The value `start` calls back with, or `timedOut` when it hasn't within
    /// `seconds`. A callback that comes later is ignored.
    public static func value<T: Sendable>(within seconds: TimeInterval, timedOut: T,
                                          _ start: (@escaping @Sendable (T) -> Void) -> Void) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            let once = Once()
            let finish: @Sendable (T) -> Void = { value in if once.take() { continuation.resume(returning: value) } }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { finish(timedOut) }
            start(finish)
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var taken = false
        func take() -> Bool { lock.lock(); defer { lock.unlock() }; if taken { return false }; taken = true; return true }
    }
}
