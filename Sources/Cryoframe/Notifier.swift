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
        case .failure: return record.outcome == .failed
        case .all:     return [.verified, .completed, .failed].contains(record.outcome)
        }
    }

    /// post a notification for a run if the policy allows. The record id is the
    /// notification id, so the same run never alerts twice (even across processes).
    static func notify(_ record: RunRecord) {
        guard shouldNotify(record, policy: current()) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Cryoframe — \(record.jobName)"
        content.body = "\(record.outcome == .failed ? "⚠️" : "✓") \(record.summary)"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: record.id, content: content, trigger: nil))
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
