//
//  RehearsalSchedule.swift
//  Cryoframe (app)
//
//  Rehearsals run monthly by default. Often enough that a destination which has
//  quietly stopped receiving a library is caught within weeks rather than on the
//  day it matters, rare enough that it isn't opening archives every night.
//
//  Each rehearsal only opens the newest version of each library, so the work is
//  bounded by how many libraries you protect, not how long you've kept them.
//

import Foundation
import CryoframeKit

enum RehearsalSchedule {
    private static let month: TimeInterval = 30 * 24 * 60 * 60

    static var enabled: Bool {
        (UserDefaults.standard.string(forKey: Prefs.rehearsalCadence) ?? "monthly") != "off"
    }

    static func isDue(now: Date) -> Bool {
        guard enabled else { return false }
        let last = UserDefaults.standard.double(forKey: Prefs.lastRehearsal)
        guard last > 0 else {
            // Never run here. Start the clock instead of rehearsing immediately:
            // otherwise updating the app makes the next hourly tick open an archive
            // from every library, which on a big NAS is real work nobody asked for
            // at a moment they didn't choose. The first one lands a month out.
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Prefs.lastRehearsal)
            return false
        }
        return now.timeIntervalSince1970 - last >= month
    }

    /// rehearse every job's destinations and record the result like any other check.
    /// A job a run holds is left for the next hourly pass (see HealthSchedule).
    @discardableResult
    static func runIfDue(store: JobStore, now: Date) -> [HealthRecord] {
        guard enabled else { return [] }
        let due = isDue(now: now)
        let pending = Set(UserDefaults.standard.stringArray(forKey: Prefs.rehearsalPending) ?? [])
        let jobs = CheckRound.jobs(store.load().jobs, due: due, pending: pending)
        guard !jobs.isEmpty else { return [] }
        let (records, busy) = run(store: store, now: now, jobs: Set(jobs.map(\.id)), wait: 30, trigger: "scheduled")
        UserDefaults.standard.set(busy.map(\.job.id), forKey: Prefs.rehearsalPending)
        if due { UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Prefs.lastRehearsal) }
        return records
    }

    /// the rehearsal itself, without the schedule — also used by "Rehearse recovery".
    /// Each job is rehearsed holding its run lock; `busy` are the ones a run held
    /// throughout `wait`, not rehearsed.
    static func run(store: JobStore, now: Date, jobs jobIDs: Set<String>? = nil, wait: TimeInterval = 0,
                    trigger: String = "manual", locks: RunLocks = .standard())
        -> (records: [HealthRecord], busy: [(job: BackupJob, holder: RunHolder?)]) {
        let registry = ContentTypeRegistry.withOverrides(LibraryOverrides.load())
        let healthStore = HealthStore.standard()
        let materializeCloud = UserDefaults.standard.bool(forKey: Prefs.verifyCloudArchives)
        var written: [HealthRecord] = []
        var busy: [(job: BackupJob, holder: RunHolder?)] = []

        for job in store.load().jobs where jobIDs?.contains(job.id) ?? true {
            let resolved = job.resolvingLibraries(in: registry)
            let expecting = resolved.libraries.map(\.displayName)
            // one passphrase per library, from this Mac's Keychain — the same key a
            // restore would use. A job with no stored key rehearses as "locked".
            let key = resolved.encrypted ? KeychainArchiveKey.load(jobID: job.id) : nil
            let rehearsed = locks.whileChecking(jobID: job.id, wait: wait) { () -> [ArchiveCheck] in
                var checks: [ArchiveCheck] = []
                for target in resolved.targets {
                    let report = RecoveryRehearsal().rehearse(
                        destination: target.destinationDir,
                        expecting: expecting,
                        isCloud: target.kind == .cloudSync,
                        materializeCloud: materializeCloud,
                        passphrase: { _ in key })
                    checks += report.asHealthReport(multiDestination: resolved.targets.count > 1).checks
                }
                return checks
            }
            guard case .done(let checks) = rehearsed else {
                if case .busy(let holder) = rehearsed { busy.append((job, holder)) } else { busy.append((job, nil)) }
                continue
            }
            let record = HealthRecord.from(job: resolved, report: HealthReport(checks: checks),
                                           at: now, kind: "rehearsal",
                                           trigger: trigger)
            healthStore.append(record)
            written.append(record)
        }
        return (written, busy)
    }
}
