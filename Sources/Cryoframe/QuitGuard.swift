//
//  QuitGuard.swift
//  Cryoframe (app)
//
//  Quitting while a backup runs. The app used to quit at once, which ended the run
//  where it stood: a live mirror's disk image stayed attached, and its drive could
//  not be ejected until the next run cleaned up after it. Now the app asks first,
//  stops the run the way Stop does (the image detached, the mirror sealed or left
//  marked as interrupted), and quits once the run has ended.
//
//  AppKit's .terminateLater would keep a pending logout going, but while it waits the
//  main queue isn't served (measured on macOS 27: neither a main-actor task nor a
//  main-queue timer ran in 10 s), so a run could never report that it had stopped.
//  The quit is canceled instead and asked for again when the run ends.
//

import AppKit

final class CryoframeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppModel.current?.shouldQuit() ?? .terminateNow
    }
}

extension AppModel {
    /// Whether the app may quit now. With a backup running, asks; on yes, stops every
    /// run and quits once they have ended (see finishRun).
    func shouldQuit() -> NSApplication.TerminateReply {
        guard !runningJobIDs.isEmpty else { return .terminateNow }
        NSApp.activate(ignoringOtherApps: true)
        if quittingAfterStop {
            // asked again while the runs are stopping
            let alert = NSAlert()
            alert.messageText = "Cryoframe is still stopping the backup."
            alert.informativeText = "It quits as soon as the backup has stopped. Quitting now can leave a mirror's disk image attached until its next backup."
            alert.addButton(withTitle: "Keep Waiting")
            alert.addButton(withTitle: "Quit Now")
            return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
        }
        let alert = NSAlert()
        alert.messageText = "A backup is running. Stop it and quit?"
        alert.informativeText = "Cryoframe stops the backup first, the same way Stop does, and then quits. Backups it already made are kept as they were."
        alert.addButton(withTitle: "Stop and Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        quittingAfterStop = true
        stopAllForQuit()
        return .terminateCancel
    }
}
