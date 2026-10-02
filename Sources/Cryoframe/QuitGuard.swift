//
//  QuitGuard.swift
//  Cryoframe (app)
//
//  Quitting while something runs: a backup, a check of the backups, an export or a
//  restore. The app used to quit at once, which ended a run where it stood: a live
//  mirror's disk image stayed attached, and its drive could not be ejected until the
//  next run cleaned up after it. Now the app asks first, stops what can be stopped
//  the way Stop does (the image detached, the mirror sealed or left marked as
//  interrupted), and quits once everything has ended. A restore can't be stopped
//  part way, so the app waits for it.
//
//  AppKit's .terminateLater would keep a pending logout going, but while it waits the
//  main queue isn't served (measured on macOS 27: neither a main-actor task nor a
//  main-queue timer ran in 10 s), so a run could never report that it had stopped.
//  A quit the person asks for is canceled instead and asked for again when the runs
//  end.
//
//  A logout, restart or shutdown never waits on a question: nobody may be there to
//  answer, and canceling it would leave the Mac running. Everything is stopped, and
//  the reply waits (at most `systemQuitWait`) while the run loop is served, so the
//  runs can finish stopping; then the quit goes ahead. Measured on macOS 27: a quit
//  Apple event arrives through the run loop with its reason attached, and main-actor
//  tasks run while the reply waits.
//

import AppKit

final class CryoframeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppModel.current?.shouldQuit() ?? .terminateNow
    }
}

/// Exports and restores under way in windows of their own, which the quit guard
/// stops or waits for. Backups and checks are AppModel's own.
@MainActor
final class QuitWatch {
    static let shared = QuitWatch()

    enum Kind { case export, restore }

    private struct Item {
        let kind: Kind
        /// nil: can't be stopped part way (a restore)
        let stop: (@MainActor () -> Void)?
    }
    private var items: [UUID: Item] = [:]

    /// an export or restore starting; `stop` stops it, when it can be stopped
    func begin(_ kind: Kind, stop: (@MainActor () -> Void)? = nil) -> UUID {
        let id = UUID()
        items[id] = Item(kind: kind, stop: stop)
        return id
    }

    /// it has ended; the app quits now if it was waiting for this
    func end(_ id: UUID?) {
        guard let id, items.removeValue(forKey: id) != nil else { return }
        AppModel.current?.quitIfIdle()
    }

    var isEmpty: Bool { items.isEmpty }
    func count(_ kind: Kind) -> Int { items.values.filter { $0.kind == kind }.count }

    func stopAll() {
        for item in items.values { item.stop?() }
    }
}

extension AppModel {
    /// how long a logout or restart waits for the runs to stop before going ahead
    static let systemQuitWait: TimeInterval = 15

    /// something that should end before the app does
    var busyForQuit: Bool {
        !runningJobIDs.isEmpty || !verifyingJobIDs.isEmpty || !QuitWatch.shared.isEmpty
    }

    /// Whether the app may quit now. With something running, asks; on yes, stops it
    /// all and quits once it has ended (see quitIfIdle). A logout or restart doesn't ask.
    func shouldQuit() -> NSApplication.TerminateReply {
        guard busyForQuit else { return .terminateNow }
        if Self.isSystemQuit() { return stopForSystemQuit() }
        NSApp.activate(ignoringOtherApps: true)
        let restores = QuitWatch.shared.count(.restore)
        if quittingAfterStop {
            // asked again while things are stopping
            let alert = NSAlert()
            alert.messageText = "Cryoframe is still stopping."
            alert.informativeText = "It quits as soon as everything has stopped."
                + (restores > 0 ? " Quitting now leaves a restore half done." : " Quitting now can leave a backup's disk image attached until its next backup.")
            alert.addButton(withTitle: "Keep Waiting")
            alert.addButton(withTitle: "Quit Now")
            return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
        }
        let alert = NSAlert()
        let (what, plural) = busyDescription()
        let onlyRestores = restores > 0 && runningJobIDs.isEmpty && verifyingJobIDs.isEmpty && QuitWatch.shared.count(.export) == 0
        if onlyRestores {
            alert.messageText = "\(what) \(plural ? "are" : "is") under way. Quit when \(plural ? "they're" : "it's") done?"
            alert.informativeText = "A restore can't be stopped part way. Cryoframe quits as soon as it has finished."
            alert.addButton(withTitle: "Quit When Done")
        } else {
            alert.messageText = "\(what) \(plural ? "are" : "is") under way. Stop and quit?"
            alert.informativeText = "Cryoframe stops first, the same way Stop does, and then quits. Backups it already made are kept as they were."
                + (restores > 0 ? " A restore can't be stopped part way, so Cryoframe waits for it to finish." : "")
            alert.addButton(withTitle: "Stop and Quit")
        }
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        quittingAfterStop = true
        stopAllForQuit()
        return .terminateCancel
    }

    /// "A backup and an export", for the question, and whether it's more than one
    private func busyDescription() -> (String, Bool) {
        var parts: [String] = []
        if runningJobIDs.count == 1 { parts.append("a backup") } else if runningJobIDs.count > 1 { parts.append("backups") }
        if verifyingJobIDs.count == 1 { parts.append("a check of your backups") } else if verifyingJobIDs.count > 1 { parts.append("checks of your backups") }
        let exports = QuitWatch.shared.count(.export), restores = QuitWatch.shared.count(.restore)
        if exports == 1 { parts.append("an export") } else if exports > 1 { parts.append("exports") }
        if restores == 1 { parts.append("a restore") } else if restores > 1 { parts.append("restores") }
        let text = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " and " + parts.last! : parts.first ?? "something"
        let plural = parts.count > 1 || !(parts.first ?? "a").hasPrefix("a")
        return (text.prefix(1).uppercased() + text.dropFirst(), plural)
    }

    /// A logout, restart or shutdown asked for the quit: nobody may be there to
    /// answer. Stop everything, wait for it while the run loop turns, and go ahead.
    private func stopForSystemQuit() -> NSApplication.TerminateReply {
        quittingAfterStop = true
        waitingForSystemQuit = true
        stopAllForQuit()
        let deadline = Date().addingTimeInterval(Self.systemQuitWait)
        while busyForQuit && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return .terminateNow
    }

    /// Whether the quit comes from a logout, restart or shutdown: loginwindow's quit
    /// event says why, and the workspace announces a power-off just before it.
    private static func isSystemQuit() -> Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        if event?.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil { return true }
        guard let at = AppModel.current?.powerOffAnnouncedAt else { return false }
        return Date().timeIntervalSince(at) < 60
    }

    /// Quit now if the person asked to quit and everything has ended.
    func quitIfIdle() {
        guard quittingAfterStop, !waitingForSystemQuit, !busyForQuit else { return }
        NSApp.terminate(nil)
    }
}
