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
//  end. The decision is QuitPlan's (in the Kit): the answer is judged by what runs
//  when it is given, since the work can end while the question is up; the app looks
//  every second as well as when work ends; and a stop that hasn't finished after
//  QuitPlan.stopLimit is given up on. A restore is waited for.
//
//  A logout, restart or shutdown never waits on a question: nobody may be there to
//  answer, and canceling it would leave the Mac running. Everything is stopped, and
//  the reply waits (at most `systemQuitWait`) while the run loop is served, so the
//  runs can finish stopping; then the quit goes ahead. Measured on macOS 27: a quit
//  Apple event arrives through the run loop with its reason attached, and main-actor
//  tasks run while the reply waits.
//

import AppKit
import CryoframeKit

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

    /// what should end before the app does (see QuitPlan)
    var quitWork: QuitWork {
        QuitWork(backups: runningJobIDs.count, checks: verifyingJobIDs.count,
                 exports: QuitWatch.shared.count(.export), restores: QuitWatch.shared.count(.restore))
    }

    /// something that should end before the app does
    var busyForQuit: Bool { !quitWork.isEmpty }

    /// the person chose to stop and quit: nothing new starts
    var quittingAfterStop: Bool { quitPlan.isStopping }

    /// Whether the app may quit now. With something running, asks; on yes, stops it
    /// all and quits once it has ended (see quitIfIdle). A logout or restart doesn't ask.
    func shouldQuit() -> NSApplication.TerminateReply {
        switch quitPlan.request(quitWork, system: Self.isSystemQuit()) {
        case .quitNow:        return .terminateNow
        case .stopForSystem:  return stopForSystemQuit()
        case .ask:            return askToStop()
        case .askWhileStopping:
            // asked again while things are stopping
            let restores = quitWork.restores
            let alert = NSAlert()
            alert.messageText = "Cryoframe is still stopping."
            alert.informativeText = "It quits as soon as everything has stopped."
                + (restores > 0 ? " Quitting now leaves a restore half done." : " Quitting now can leave a backup's disk image attached until its next backup.")
            alert.addButton(withTitle: "Keep Waiting")
            alert.addButton(withTitle: "Quit Now")
            NSApp.activate(ignoringOtherApps: true)
            let quitNow = answering { alert.runModal() == .alertSecondButtonReturn }
            // what was waited for may have ended while the question was up
            return quitNow || quitPlan.check(quitWork, now: Date()) != .wait ? .terminateNow : .terminateCancel
        }
    }

    private func askToStop() -> NSApplication.TerminateReply {
        NSApp.activate(ignoringOtherApps: true)
        let work = quitWork
        let (what, plural) = work.described
        let alert = NSAlert()
        if work.onlyRestores {
            alert.messageText = "\(what) \(plural ? "are" : "is") under way. Quit when \(plural ? "they're" : "it's") done?"
            alert.informativeText = "A restore can't be stopped part way. Cryoframe quits as soon as it has finished."
            alert.addButton(withTitle: "Quit When Done")
        } else {
            alert.messageText = "\(what) \(plural ? "are" : "is") under way. Stop and quit?"
            alert.informativeText = "Cryoframe stops first, the same way Stop does, and then quits. Backups it already made are kept as they were."
                + (work.restores > 0 ? " A restore can't be stopped part way, so Cryoframe waits for it to finish." : "")
            alert.addButton(withTitle: "Stop and Quit")
        }
        alert.addButton(withTitle: "Cancel")
        guard answering({ alert.runModal() == .alertFirstButtonReturn }) else { return .terminateCancel }
        // Judged by what runs now: the question can stay up while the work ends on its
        // own, and then there is nothing left to stop and nothing would ask again.
        if quitPlan.stop(quitWork, now: Date()) { return .terminateNow }
        stopAllForQuit()
        watchForQuit()
        return .terminateCancel
    }

    /// run a question; while it is up, nothing ends the quit under it (see quitIfIdle)
    private func answering<T>(_ ask: () -> T) -> T {
        askingToQuit = true
        defer { askingToQuit = false }
        return ask()
    }

    /// Look every second as well as when something ends, so a quit never waits on a
    /// path that forgot to say so, and a stop that never ends is given up on.
    private func watchForQuit() {
        quitWatchTask?.cancel()
        quitWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.quitIfIdle()
            }
        }
    }

    /// A logout, restart or shutdown asked for the quit: nobody may be there to
    /// answer. Stop everything, wait for it while the run loop turns, and go ahead.
    private func stopForSystemQuit() -> NSApplication.TerminateReply {
        _ = quitPlan.stop(quitWork, now: Date())
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

    /// Quit now if the person asked to quit and everything has ended, or a stop has
    /// gone on past QuitPlan.stopLimit. Called when work ends and every second.
    func quitIfIdle() {
        guard !waitingForSystemQuit, !askingToQuit else { return }
        switch quitPlan.check(quitWork, now: Date()) {
        case .wait:
            return
        case .quit:
            break
        case .quitAfterLimit:
            let (what, _) = quitWork.described
            log("⚠︎ \(what) hadn't stopped after \(Int(QuitPlan.stopLimit)) seconds; quitting anyway")
        }
        quitWatchTask?.cancel()
        NSApp.terminate(nil)
    }
}
