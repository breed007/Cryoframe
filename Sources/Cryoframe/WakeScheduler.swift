//
//  WakeScheduler.swift
//  Cryoframe (app)
//
//  Optional, opt-in: schedules a `pmset` wake (via the root helper) shortly before
//  the next due job, so a Mac left asleep still runs its scheduled backup near the
//  intended time. SleepGuard keeps the Mac awake *during* a run; this gets it awake
//  to *start* one. It only ever manages the single wake event Cryoframe creates.
//
//  Invasive (root, modifies the system power schedule), so it's off by default and
//  gated on Prefs.wakeForSchedule. It can't power on a Mac that's fully shut down,
//  and it can't beat clamshell sleep — see HelpView.
//

import Foundation
import CryoframeKit

enum WakeScheduler {
    static let leadSeconds: TimeInterval = 120        // wake ~2 min before the job is due

    /// the earliest moment an enabled job will next be due, strictly after `now`.
    static func nextDue(_ state: ScheduleState, now: Date) -> Date? {
        state.jobs
            .filter { $0.enabled }
            .compactMap { job in job.frequency.nextFireDate(after: max(state.lastRun[job.id] ?? job.createdAt, now)) }
            .filter { $0 > now }
            .min()
    }

    /// arm the wake to match the schedule, or clear ours when the feature is off or
    /// nothing is scheduled. Best-effort: silently does nothing if the helper is away.
    static func arm(store: JobStore = .standard(), now: Date = Date()) async {
        let on = UserDefaults.standard.bool(forKey: Prefs.wakeForSchedule)
        let target: Date? = on
            ? nextDue(store.load(), now: now).map { $0.addingTimeInterval(-leadSeconds) }
            : nil
        let xpc = XPCPrivilegedHelper()
        try? await xpc.scheduleWake(at: target)
        xpc.invalidate()
    }
}
