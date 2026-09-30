//
//  JobRemoval.swift
//  CryoframeKit
//
//  Deleting a job: what it leaves, and doing it without pulling anything out from
//  under a run.
//
//  A job's backups are the point of it, so deleting the job deletes none of them:
//  its folders at every destination stay, and Restore still finds them. Its
//  passphrase stays in the Keychain, or an encrypted job's backups would stop
//  opening the moment it was deleted. What goes is the job itself (its schedule, its
//  last run, its destinations' last copies), its interrupted uploads' records and
//  the copies staged locally for them. The parts an upload already put on a
//  destination stay there without a manifest: Restore can't read them and nothing
//  tidies them up, so the confirmation names them, and where they are.
//
//  Delete used to stop the job's run and delete at once. The run was then still
//  tearing down (its snapshot, its mounts, its half-written version) while the job
//  it was writing for was gone, and the passphrase went with it. Now a busy job
//  isn't deleted at all: the delete takes the job's run lock, so nothing (a run
//  here or in the scheduled agent, a transfer being finished, a check) is using it,
//  and nothing can start until it's done.
//

import Foundation

public enum JobRemoval {
    /// What deleting a job does, as the confirmation shows it. Deleting checks it is
    /// still so (see `delete`).
    public struct Plan: Sendable, Equatable {
        /// One destination's folders of the job's, which stay.
        public struct Place: Sendable, Equatable {
            public var name: String
            /// where it is now; nil when it isn't connected
            public var dir: URL?
            /// the job's library folders there (connected only)
            public var folders: [URL]
        }
        /// An upload that was interrupted: its parts so far stay on the destination.
        public struct Unfinished: Sendable, Equatable {
            public var destination: String
            /// the version folder the parts are in
            public var dir: URL
            public var bytesReached: UInt64
            public var totalBytes: UInt64
        }
        public var jobID: String
        public var jobName: String
        public var places: [Place]
        public var unfinished: [Unfinished]
        /// the local folder holding the job's staged copies, removed (nil: none)
        public var staged: URL?
        /// the job's passphrase stays in the Keychain
        public var encrypted: Bool
    }

    public enum Refusal: Error, Equatable, LocalizedError {
        /// a run, a transfer being finished or a check holds the job
        case busy(RunHolder)
        /// a run of it is waiting to start
        case queued
        /// what it would do isn't what was shown any more
        case changed(Plan)
        /// whether it's in use can't be told
        case unavailable(String)

        public var errorDescription: String? {
            switch self {
            case .busy(let h): "It wasn't deleted: \(h.busyDoing). Try again once it's done."
            case .queued: "It wasn't deleted: a backup of it is waiting to start. Stop it first."
            case .changed: "It wasn't deleted: what it has on its destinations changed. Look it over again."
            case .unavailable(let why): "It wasn't deleted: \(why)."
            }
        }
    }

    /// What deleting `job` would do now. Reads its destinations (it lists folders).
    public static func plan(for job: BackupJob, pending: PendingTransferStore, scratchBase: URL,
                            volumes: VolumeTable = SystemVolumeTable()) -> Plan {
        let resolved = DestinationResolver(volumes: volumes).resolve(job)
        let labels = job.destinationLabels
        let places = resolved.job.targets.map { t -> Plan.Place in
            let name = labels[t.id] ?? t.displayName
            guard let dir = resolved.presence[t.id]?.url else { return Plan.Place(name: name, dir: nil, folders: []) }
            var folders: [URL] = []
            for lib in job.libraries {
                for f in LibraryFolders.folders(job: job, library: lib, in: dir) where !folders.contains(f) { folders.append(f) }
            }
            return Plan.Place(name: name, dir: dir, folders: folders)
        }
        let unfinished = pending.all().filter { $0.owningJobID == job.id }.map { p -> Plan.Unfinished in
            let reached = p.completed.reduce(UInt64(0)) { $0 + $1.size }
            let dir = URL(fileURLWithPath: p.targetDir, isDirectory: true)
            let target = job.targets.first { DestinationRules.contains($0.destinationDir, dir) }
            return Plan.Unfinished(destination: target.map { labels[$0.id] ?? $0.displayName } ?? dir.deletingLastPathComponent().lastPathComponent,
                                   dir: dir, bytesReached: reached, totalBytes: p.totalBytes)
        }.sorted { $0.dir.path < $1.dir.path }
        let staged = stagedFolder(job.id, scratchBase: scratchBase).flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        return Plan(jobID: job.id, jobName: job.name, places: places, unfinished: unfinished,
                    staged: staged, encrypted: job.encrypted)
    }

    /// Delete `job`, if it isn't in use and deleting it still does what `expected`
    /// (the confirmation's plan) says. Holding the job's run lock throughout: its
    /// interrupted uploads' records and staged copies go first, then the job. Its
    /// folders at its destinations, and its passphrase, stay (see the top).
    /// `isQueued`: whether a run of it is waiting to start in this process, asked
    /// under the lock.
    public static func delete(_ job: BackupJob, expected: Plan, store: JobStore, pending: PendingTransferStore,
                              scratchBase: URL, locks: RunLocks, isQueued: () -> Bool = { false },
                              volumes: VolumeTable = SystemVolumeTable()) throws {
        let lease: RunLease
        do {
            lease = try locks.acquire(jobID: job.id, trigger: .cleanup)
        } catch RunLockError.alreadyRunning(let holder) {
            throw Refusal.busy(holder)
        } catch {
            throw Refusal.unavailable(error.localizedDescription)
        }
        defer { lease.release() }
        guard !isQueued() else { throw Refusal.queued }
        let now = plan(for: job, pending: pending, scratchBase: scratchBase, volumes: volumes)
        guard now == expected else { throw Refusal.changed(now) }
        for p in pending.all() where p.owningJobID == job.id { pending.remove(jobID: p.jobID) }
        if let staged = stagedFolder(job.id, scratchBase: scratchBase) { try? FileManager.default.removeItem(at: staged) }
        store.update { s in
            s.jobs.removeAll { $0.id == job.id }
            s.lastRun[job.id] = nil
            s.lastCopy[job.id] = nil
            s.adoptionReviews[job.id] = nil
        }
    }

    /// where a job's sealed archives are staged before they're copied (see
    /// JobExecutor's build folder); nil for an id that isn't one folder's name, which
    /// no job the app made has
    static func stagedFolder(_ jobID: String, scratchBase: URL) -> URL? {
        guard !jobID.isEmpty, !jobID.contains("/"), jobID != ".", jobID != ".." else { return nil }
        return scratchBase.appendingPathComponent(jobID, isDirectory: true)
    }
}
