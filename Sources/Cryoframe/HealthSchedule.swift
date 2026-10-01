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

    /// re-check all jobs' archives if due, recording one health record per job. Depth
    /// is the checksum re-hash by default, or a full restore drill (reassemble, open,
    /// reopen) when configured — the drill reads encrypted jobs' passphrases from the
    /// Keychain, which the agent can reach as the same signed binary.
    ///
    /// Each job is checked holding its run lock, so a check never reads a version a
    /// run is still writing. A job a run holds (the app running it, say) is left for
    /// the next hourly pass rather than the next period.
    ///
    /// Stop pressed in the app ends a job's check (see RunLocks.whileChecking). A
    /// stopped check isn't recorded as one, and the job stays due: it is checked again
    /// on the next hourly pass. Failures it found are returned all the same, to alert.
    @discardableResult
    static func runIfDue(store: JobStore, now: Date, locks: RunLocks = .standard()) -> [CheckRecording.Outcome] {
        guard period() != nil else { return [] }
        let due = isDue(now: now)
        let pending = Set(UserDefaults.standard.stringArray(forKey: Prefs.healthPending) ?? [])
        let jobs = CheckRound.jobs(store.load().jobs, due: due, pending: pending)
        guard !jobs.isEmpty else { return [] }
        let registry = ContentTypeRegistry.withOverrides(LibraryOverrides.load())
        let healthStore = HealthStore.standard(), canceledStore = CanceledCheckStore.standard()
        let latestOnly = UserDefaults.standard.string(forKey: Prefs.healthScope) != "all"
        let drill = UserDefaults.standard.string(forKey: Prefs.healthDepth) == "drill"
        let materializeCloud = UserDefaults.standard.bool(forKey: Prefs.verifyCloudArchives)
        var written: [CheckRecording.Outcome] = []
        var stillPending: [String] = []
        for job in jobs {
            let resolved = job.resolvingLibraries(in: registry)
            let control = RunControl()
            let checked = locks.whileChecking(jobID: job.id, wait: 30, control: control) { () -> HealthReport in
                if drill {
                    let passphrase = job.encrypted ? KeychainArchiveKey.load(jobID: job.id) : nil
                    return RestoreDriller(runner: ProcessCommandRunner(control: control))
                        .drill(job: resolved, latestOnly: latestOnly, passphrase: passphrase, materializeCloud: materializeCloud)
                }
                return HealthChecker().check(job: resolved, latestOnly: latestOnly, materializeCloud: materializeCloud, control: control)
            }
            guard case .done(let report) = checked else { stillPending.append(job.id); continue }
            let outcome = CheckRecording.record(report, job: resolved, kind: drill ? "drill" : "checksum", at: now,
                                                trigger: "scheduled", health: healthStore, canceled: canceledStore)
            written.append(outcome)
            if case .canceled = outcome { stillPending.append(job.id) }
        }
        UserDefaults.standard.set(stillPending, forKey: Prefs.healthPending)
        if due { UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Prefs.lastHealthCheck) }
        return written
    }
}
