//
//  HealthSchedule.swift
//  Cryoframe (app)
//
//  The scheduled archive-health pass the agent runs: when the configured interval
//  has elapsed, re-verify every job's archives against their checksums and record
//  the result. Failures surface via the menu-bar app's history watch + notifications.
//

import Foundation
import CryoframeKit

enum HealthSchedule {
    private static func period() -> Double? {
        switch UserDefaults.standard.string(forKey: Prefs.healthInterval) ?? "off" {
        case "weekly":  return 7 * 86400
        case "monthly": return 30 * 86400
        default:        return nil      // off
        }
    }

    static func isDue(now: Date) -> Bool {
        guard let period = period() else { return false }
        return now.timeIntervalSince1970 - UserDefaults.standard.double(forKey: Prefs.lastHealthCheck) >= period
    }

    /// re-verify all jobs' archives if due, recording one health record per job.
    static func runIfDue(store: JobStore, now: Date) {
        guard isDue(now: now) else { return }
        let registry = ContentTypeRegistry.withOverrides(LibraryOverrides.load())
        let healthStore = HealthStore.standard()
        let checker = HealthChecker()
        let latestOnly = UserDefaults.standard.string(forKey: Prefs.healthScope) != "all"
        for job in store.load().jobs {
            let resolved = job.resolvingLibraries(in: registry)
            let report = checker.check(job: resolved, latestOnly: latestOnly)
            healthStore.append(HealthRecord.from(job: resolved, report: report, at: now))
        }
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Prefs.lastHealthCheck)
    }
}
