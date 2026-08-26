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
        guard last > 0 else { return true }                 // never run: do one
        return now.timeIntervalSince1970 - last >= month
    }

    /// rehearse every job's destinations and record the result like any other check.
    @discardableResult
    static func runIfDue(store: JobStore, now: Date) -> [HealthRecord] {
        guard isDue(now: now) else { return [] }
        let records = run(store: store, now: now)
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Prefs.lastRehearsal)
        return records
    }

    /// the rehearsal itself, without the schedule — also used by "Rehearse recovery".
    static func run(store: JobStore, now: Date, only jobID: String? = nil) -> [HealthRecord] {
        let registry = ContentTypeRegistry.withOverrides(LibraryOverrides.load())
        let healthStore = HealthStore.standard()
        let materializeCloud = UserDefaults.standard.bool(forKey: Prefs.verifyCloudArchives)
        var written: [HealthRecord] = []

        for job in store.load().jobs where jobID == nil || job.id == jobID {
            let resolved = job.resolvingLibraries(in: registry)
            let expecting = resolved.libraries.map(\.displayName)
            // one passphrase per library, from this Mac's Keychain — the same key a
            // restore would use. A job with no stored key rehearses as "locked".
            let key = resolved.encrypted ? KeychainArchiveKey.load(jobID: job.id) : nil
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
            let record = HealthRecord.from(job: resolved, report: HealthReport(checks: checks),
                                           at: now, kind: "rehearsal",
                                           trigger: jobID == nil ? "scheduled" : "manual")
            healthStore.append(record)
            written.append(record)
        }
        return written
    }
}
