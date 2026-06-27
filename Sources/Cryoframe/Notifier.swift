//
//  Notifier.swift
//  Cryoframe (app)
//
//  User notifications for run results, posted from the GUI process (a headless
//  LaunchAgent can't reliably reach the notification center). Because the menu-bar
//  item keeps the app resident, the GUI also notifies for scheduled runs it sees
//  appear in the history file. Policy: never / on failure (default) / every run.
//

import Foundation
import UserNotifications
import CryoframeKit

enum NotifyPolicy: String { case never, failure, all }

enum Notifier {
    static func current() -> NotifyPolicy {
        NotifyPolicy(rawValue: UserDefaults.standard.string(forKey: Prefs.notifyPolicy) ?? "failure") ?? .failure
    }

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func shouldNotify(_ record: RunRecord, policy: NotifyPolicy) -> Bool {
        switch policy {
        case .never:   return false
        case .failure: return [.failed, .partial].contains(record.outcome)   // a degraded backup is worth a heads-up
        case .all:     return [.verified, .completed, .partial, .failed].contains(record.outcome)
        }
    }

    /// post a notification for a run if the policy allows. The record id is the
    /// notification id, so the same run never alerts twice (even across processes).
    static func notify(_ record: RunRecord) {
        if shouldNotify(record, policy: current()) {
            let content = UNMutableNotificationContent()
            content.title = "Cryoframe — \(record.jobName)"
            let ok = record.outcome == .verified || record.outcome == .completed
            content.body = "\(ok ? "✓" : "⚠️") \(record.summary)"
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: record.id, content: content, trigger: nil))
        }
        RemoteAlert.send(for: record)        // off-machine, on its own policy — fires even if local is off
    }

    /// post for an archive health check. Failures alert unless notifications are off;
    /// clean results alert only on the "every run" policy.
    static func notifyHealth(_ record: HealthRecord) {
        RemoteAlert.sendHealth(for: record)   // off-machine, independent of the local policy
        let policy = current()
        let clean = record.passed && record.archivesChecked > 0
        if clean { guard policy == .all else { return } } else { guard policy != .never else { return } }
        let content = UNMutableNotificationContent()
        content.title = "Cryoframe — \(record.jobName)"
        if record.archivesChecked == 0 {
            content.body = "⚠️ no archives found to check — is the target connected?"
        } else if record.passed {
            content.body = "✓ \(record.archivesChecked) archive\(record.archivesChecked == 1 ? "" : "s") verified"
        } else {
            content.body = "⚠️ archive check failed — \(record.failures.first ?? "corruption detected")"
        }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "health-\(record.id)", content: content, trigger: nil))
    }
}

/// fires `onChange` when anything in a directory changes — used to notice runs the
/// scheduled agent appends to the history while the GUI is resident in the menu bar.
final class DirWatcher {
    private let fd: Int32
    private let source: DispatchSourceFileSystemObject

    init?(url: URL, onChange: @escaping () -> Void) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler(handler: onChange)
        let captured = fd
        source.setCancelHandler { close(captured) }
        source.resume()
    }

    deinit { source.cancel() }
}
