//
//  SleepGuard.swift
//  Cryoframe (app)
//
//  Holds an idle-system-sleep power assertion while a backup is actively running,
//  so an unattended or scheduled job isn't cut off when the Mac idle-sleeps (which
//  would sever network mounts and can break an in-flight archive). Uses
//  ProcessInfo.beginActivity — the same assertion `caffeinate -i` takes, with no
//  child process and no forced display-on.
//
//  Scope: it prevents *idle* sleep only. Closing a laptop lid still sleeps the Mac
//  (no app can override clamshell sleep), and this never wakes a sleeping Mac — see
//  WakeScheduler for that. Gated by the "keep awake" preference (default on).
//

import Foundation

final class SleepGuard {
    private var token: NSObjectProtocol?

    /// take the assertion if the preference is on and we aren't already holding it.
    func begin(reason: String = "Cryoframe backup running") {
        guard token == nil else { return }
        guard UserDefaults.standard.object(forKey: Prefs.keepAwake) as? Bool ?? true else { return }
        token = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .suddenTerminationDisabled], reason: reason)
    }

    func end() {
        if let token { ProcessInfo.processInfo.endActivity(token) }
        token = nil
    }
}
