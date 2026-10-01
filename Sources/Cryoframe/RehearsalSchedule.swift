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
    /// A job a run holds is left for the next hourly pass (see HealthSchedule), and so
    /// is one whose rehearsal Stop ended: it isn't recorded, and stays due.
    @discardableResult
    static func runIfDue(store: JobStore, now: Date) -> [CheckRecording.Outcome] {
        guard enabled else { return [] }
        let due = isDue(now: now)
        let pending = Set(UserDefaults.standard.stringArray(forKey: Prefs.rehearsalPending) ?? [])
        let jobs = CheckRound.jobs(store.load().jobs, due: due, pending: pending)
        guard !jobs.isEmpty else { return [] }
        let done = run(store: store, now: now, jobs: Set(jobs.map(\.id)), wait: 30, trigger: "scheduled")
        let stopped = done.outcomes.compactMap { o -> String? in if case .canceled(let c) = o { return c.jobID }; return nil }
        UserDefaults.standard.set(done.busy.map(\.job.id) + stopped, forKey: Prefs.rehearsalPending)
        if due { UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Prefs.lastRehearsal) }
        return done.outcomes
    }

    /// the rehearsal itself, without the schedule — also used by "Rehearse recovery".
    /// Each job is rehearsed holding its run lock, recorded through CheckRecording;
    /// `busy` are the ones a run held throughout `wait`, not rehearsed. `control` is
    /// the Stop of a single job's rehearsal (the app's); without one each job gets
    /// its own, which Stop pressed in the app reaches (see RunLocks.whileChecking).
    static func run(store: JobStore, now: Date, jobs jobIDs: Set<String>? = nil, wait: TimeInterval = 0,
                    trigger: String = "manual", locks: RunLocks = .standard(), control: RunControl? = nil)
        -> (outcomes: [CheckRecording.Outcome], busy: [(job: BackupJob, holder: RunHolder?)]) {
        let registry = ContentTypeRegistry.withOverrides(LibraryOverrides.load())
        let healthStore = HealthStore.standard(), canceledStore = CanceledCheckStore.standard()
        let materializeCloud = UserDefaults.standard.bool(forKey: Prefs.verifyCloudArchives)
        var outcomes: [CheckRecording.Outcome] = []
        var busy: [(job: BackupJob, holder: RunHolder?)] = []

        for job in store.load().jobs where jobIDs?.contains(job.id) ?? true {
            let resolved = job.resolvingLibraries(in: registry)
            let expecting = resolved.libraries.map(\.displayName)
            // one passphrase per library, from this Mac's Keychain — the same key a
            // restore would use. A job with no stored key rehearses as "locked".
            let key = resolved.encrypted ? KeychainArchiveKey.load(jobID: job.id) : nil
            let control = control ?? RunControl()
            let rehearsal = RecoveryRehearsal(runner: ProcessCommandRunner(control: control))
            let rehearsed = locks.whileChecking(jobID: job.id, wait: wait, control: control) { () -> HealthReport in
                // each destination where it is now; one not connected has nothing to rehearse
                let placed = DestinationResolver().resolve(resolved)
                let places = placed.job.targets
                    .filter { ($0.volume == nil && $0.rotation == nil) || placed.presence[$0.id]?.isPresent == true }
                    .map { RecoveryRehearsal.Place(destination: $0.destinationDir, isCloud: $0.kind == .cloudSync) }
                return rehearsal.rehearse(places, expecting: expecting,
                                          alsoKnownAs: Dictionary(resolved.libraries.map { ($0.displayName, $0.formerNames ?? []) },
                                                                  uniquingKeysWith: +),
                                          materializeCloud: materializeCloud, multiDestination: resolved.targets.count > 1,
                                          passphrase: { _ in key })
            }
            guard case .done(let report) = rehearsed else {
                if case .busy(let holder) = rehearsed { busy.append((job, holder)) } else { busy.append((job, nil)) }
                continue
            }
            outcomes.append(CheckRecording.record(report, job: resolved, kind: "rehearsal", at: now, trigger: trigger,
                                                  health: healthStore, canceled: canceledStore))
        }
        return (outcomes, busy)
    }
}
