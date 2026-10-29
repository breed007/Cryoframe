//
//  Notifier.swift
//  Cryoframe (app)
//
//  Notifications on this Mac for runs, checks, overdue jobs and full destinations.
//  What each says, and the never/failure/every-run policy, are NoticeContent's.
//  While the app runs it posts them, including for the scheduled runs it sees appear
//  in the history file. When it isn't open, the scheduled agent posts them instead
//  (AgentMain), but only when macOS allows Cryoframe's notifications; only the app
//  asks for that.
//
//  Measured: nothing yet. Read but not measured: the agent is the app's own executable
//  inside the bundle (BundleProgram), so macOS should take its notices as
//  Cryoframe's. A banner from the agent has not been seen on a signed build, nor
//  after a reboot or under Focus. That is why the agent posts last, after its
//  history, remote alerts and wake, and gives each call 5 seconds: if it can't post,
//  nothing else it does changes.
//

import Foundation
import UserNotifications
import CryoframeKit

enum Notifier {
    static func current() -> NotifyPolicy {
        NotifyPolicy(rawValue: UserDefaults.standard.string(forKey: Prefs.notifyPolicy) ?? "failure") ?? .failure
    }

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// post a notification for a run if the policy allows. The record id is the
    /// notification id, so the same run never alerts twice (even across processes).
    static func notify(_ record: RunRecord) {
        if let notice = NoticeContent.run(record, policy: current()) { Task { await LocalNotice.post(notice) } }
        // the agent alerts for the runs it performs on a schedule, so alerting here
        // too would send everything twice whenever the app happens to be running.
        if record.trigger != "scheduled" { RemoteAlert.send(for: record) }
    }

    /// Post an overdue notice when it is due in `ledger`. The turn is claimed before
    /// posting, so the agent looking at the same moment doesn't post it too, and handed
    /// back when macOS didn't take it (notifications turned off for Cryoframe), so one
    /// that couldn't be shown is owed, not counted.
    static func notifyOverdue(_ payload: AlertPolicy.Payload, subject: String, ledger: AlertThrottle, now: Date) {
        guard let notice = NoticeContent.overdue(payload, subject: subject, policy: current(), now: now) else { return }
        Task {
            guard await LocalNotice.authorization().allowsPosting, let claim = ledger.claim(subject, now: now) else { return }
            if !(await LocalNotice.post(notice)) { ledger.release(claim) }
        }
    }

    /// post for a stopped check that found failures (see AlertPolicy.payload(forStopped:)),
    /// as for a finished check's failures: unless notifications are off, and remotely
    /// from here only for a check this app made (the agent alerts for its own)
    static func notifyStopped(_ check: CanceledCheck) {
        if check.trigger != "scheduled", let p = AlertPolicy.payload(forStopped: check) {
            Task { await RemoteAlert.deliverPayload(p) }
        }
        if let notice = NoticeContent.stopped(check, policy: current()) { Task { await LocalNotice.post(notice) } }
    }

    /// post for an archive health check. Failures alert unless notifications are off;
    /// clean results alert only on the "every run" policy. The caller has already left
    /// out a check that found nothing on a job that has never run.
    static func notifyHealth(_ record: HealthRecord) {
        if record.trigger != "scheduled" { RemoteAlert.sendHealth(for: record) }   // see above
        if let notice = NoticeContent.health(record, policy: current(), jobHasRun: true) {
            Task { await LocalNotice.post(notice) }
        }
    }
}

/// Posting to the notification center, from the app or the agent. Not on the main
/// actor: the agent blocks its main thread while it waits for these. Each call is
/// given up after `bound` seconds, so a notification center that doesn't answer
/// can't hold up the agent's exit.
enum LocalNotice {
    static let bound: TimeInterval = 5

    /// what macOS says of Cryoframe's notifications; unknown when it doesn't say in time
    static func authorization() async -> AgentNotices.Authorization {
        await BoundedWait.value(within: bound, timedOut: AgentNotices.Authorization.unknown) { done in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                switch settings.authorizationStatus {
                case .authorized: done(.authorized)
                case .provisional: done(.provisional)
                case .denied: done(.denied)
                case .notDetermined: done(.notDetermined)
                default: done(.unknown)
                }
            }
        }
    }

    /// whether macOS took the notice in time
    @discardableResult
    static func post(_ notice: NoticeContent) async -> Bool {
        await BoundedWait.value(within: bound, timedOut: false) { done in
            let content = UNMutableNotificationContent()
            content.title = notice.title
            content.body = notice.body
            if notice.sound { content.sound = .default }
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: notice.id, content: content, trigger: nil)) { error in
                done(error == nil)
            }
        }
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
