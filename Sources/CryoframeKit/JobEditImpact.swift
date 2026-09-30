//
//  JobEditImpact.swift
//  CryoframeKit
//
//  What saving an edited job does to its backups, said before the save.
//
//  Saving writes the job files and nothing else; the job's next run acts on the
//  change, at each destination it reaches: it makes folders for a new destination,
//  renames a library's folders, holds on to what a format change leaves, and deletes
//  the versions a lower Keep rule no longer keeps. Only that last deletes anything,
//  and it is counted with the rule retention itself runs (JobExecutor.prunePlan),
//  counting the version that run adds. A library or a destination taken out of the
//  job loses nothing: its backups stay where they are, and Restore still finds them.
//

import Foundation

public struct JobEditImpact: Sendable, Equatable {
    public struct Line: Sendable, Equatable, Hashable {
        public enum Kind: Sendable, Equatable, Hashable {
            /// folders or copies made
            case creates
            /// a folder renamed
            case renames
            /// something left as it is (kept, stays)
            case keeps
            /// backups deleted
            case deletes
            /// how the job works from now on
            case changes
        }
        public var kind: Kind
        public var text: String
    }

    public var lines: [Line]

    /// versions the next run deletes, over all destinations and libraries
    public var deletes: Int

    /// What saving `draft` over `base` (nil: a new job) does at the next run. Reads the
    /// destinations that are connected; changes nothing. `pending`: the interrupted
    /// transfers recorded (a folder one still writes into isn't renamed until it's done).
    public static func of(draft: BackupJob, base: BackupJob?, volumes: VolumeTable = SystemVolumeTable(),
                          checks: [HealthRecord] = [], pending: [PendingTransfer] = [], now: Date = Date()) -> JobEditImpact {
        var lines: [Line] = []
        var deletes = 0
        func say(_ kind: Line.Kind, _ text: String) { if !lines.contains(Line(kind: kind, text: text)) { lines.append(Line(kind: kind, text: text)) } }
        let resolver = DestinationResolver(volumes: volumes)
        let placed = resolver.resolve(draft)
        let labels = draft.destinationLabels
        func name(_ t: Target) -> String { labels[t.id] ?? t.displayName }
        let pendingDirs = pending.map { URL(fileURLWithPath: $0.targetDir, isDirectory: true) }

        // taken out of the job: nothing is deleted
        if let base {
            for t in base.targets where !draft.targets.contains(where: { $0.id == t.id }) {
                say(.keeps, "\(base.destinationLabels[t.id] ?? t.displayName) is no longer written to. Nothing there is deleted; Restore still finds its backups.")
            }
            for lib in base.libraries where !draft.libraries.contains(where: { $0.id == lib.id }) {
                say(.keeps, "\(lib.displayName) is no longer backed up. Its backups stay where they are; Restore still finds them.")
            }
            if base.targets.first?.id != draft.targets.first?.id, let main = draft.targets.first {
                say(.changes, "\(name(main)) is the main destination: a backup that can't reach it fails.")
            }
        }

        for t in placed.job.targets {
            let before = base?.targets.first { $0.id == t.id }
            let here = placed.presence[t.id]?.url
            // a destination new to the job
            guard let before else {
                if let here {
                    for line in DestinationRules.preview(here, job: draft) { say(.creates, "At \(name(t)): \(line)") }
                } else {
                    say(.creates, "\(name(t)) gets its folders the first time it's connected.")
                }
                continue
            }
            // drives it now takes turns with under one name
            let added = (t.otherVolumes ?? []).filter { v in !(before.otherVolumes ?? []).contains { $0.uuid == v.uuid } }
            for v in added { say(.changes, "\(name(t)) takes turns with the other drive named “\(v.name)”, at the same folder.") }
            let removed = (before.otherVolumes ?? []).filter { v in !(t.otherVolumes ?? []).contains { $0.uuid == v.uuid } }
            for v in removed { say(.keeps, "\(name(t)) no longer takes turns with the other drive named “\(v.name)”. Nothing on it is deleted.") }
            if t.rotation?.group != before.rotation?.group {
                let partners = placed.job.targets.filter { $0.id != t.id && $0.rotation != nil && $0.rotation?.group == t.rotation?.group }
                if t.rotation != nil, !partners.isEmpty {
                    say(.changes, "\(RotationRules.name(of: [t] + partners)) take turns: each backup goes to whichever is connected.")
                } else if before.rotation != nil {
                    say(.changes, "\(name(t)) no longer takes turns: every backup has to reach it.")
                }
            }

            for lib in draft.libraries {
                guard let old = base?.libraries.first(where: { $0.id == lib.id }) else {
                    if let here, let line = DestinationRules.preview(here, job: BackupJob.only(lib, of: draft)).first {
                        say(.creates, "At \(name(t)): \(line)")
                    }
                    continue
                }
                let folder = here.flatMap { LibraryFolders.folder(job: draft, library: lib, in: $0) }
                // renamed
                if !LibraryNames.same(old.displayName, lib.displayName) {
                    if let here, let folder, !LibraryFolderName.fits(folder.lastPathComponent, name: lib.displayName,
                                                                     key: LibraryIdentity.key(job: draft, library: lib)) {
                        let busy = pendingDirs.contains { DestinationRules.contains(folder, $0) }
                        say(.renames, "At \(name(t)), “\(folder.lastPathComponent)” is renamed “\(LibraryFolderName.choose(job: draft, library: lib, in: here))” "
                            + (busy ? "once its interrupted upload has finished." : "at the next backup."))
                    } else if here == nil {
                        say(.renames, "At \(name(t)), \(old.displayName)'s folder is renamed the next time it's connected.")
                    }
                }
                guard let folder, let base else { continue }
                // a format change holds on to what the other format made
                if base.format.isSealed != draft.format.isSealed {
                    if draft.format.isSealed, LibraryFolders.holdsMirror(folder) {
                        say(.keeps, "At \(name(t)), the up-to-date copy of \(lib.displayName) stays, marked kept; dated versions go beside it.")
                    } else if !draft.format.isSealed {
                        let n = LibraryFolders.versionNames(in: folder).count
                        if n > 0 { say(.keeps, "At \(name(t)), \(n) dated version\(n == 1 ? "" : "s") of \(lib.displayName) stay, marked kept.") }
                    }
                    continue
                }
                // a Keep rule that keeps fewer
                guard draft.format.isSealed, draft.retention != base.retention else { continue }
                let plan = JobExecutor.prunePlan(folders: [(lib, folder)], policy: draft.retention, checks: checks,
                                                 transferring: { d in pendingDirs.contains { DestinationRules.samePath($0, d) } },
                                                 upcoming: now)
                let was = JobExecutor.prunePlan(folders: [(lib, folder)], policy: base.retention, checks: checks,
                                                transferring: { d in pendingDirs.contains { DestinationRules.samePath($0, d) } },
                                                upcoming: now)
                if plan.versions.count > was.versions.count {
                    deletes += plan.versions.count
                    let n = plan.versions.count
                    say(.deletes, "At \(name(t)), \(n) version\(n == 1 ? "" : "s") of \(lib.displayName) \(n == 1 ? "is" : "are") deleted at the next backup, by the new Keep rule.")
                }
            }
        }
        if lines.isEmpty, base != nil { say(.changes, "Nothing on the destinations changes; the next backup follows the new settings.") }
        return JobEditImpact(lines: lines, deletes: deletes)
    }
}

extension BackupJob {
    /// this job, backing up `library` alone (for what a run would make of it)
    static func only(_ library: ContentType, of job: BackupJob) -> BackupJob {
        var j = job; j.libraries = [library]; return j
    }
}

/// What a job has on its destinations, as the delete confirmation and Storage show it.
public struct JobFootprint: Sendable, Equatable {
    public struct Folder: Sendable, Equatable {
        public var url: URL
        public var library: String
        /// dated versions in it
        public var versions: Int
        /// whether it holds an up-to-date copy (a mirror)
        public var hasCopy: Bool
        /// what it keeps that the job no longer writes or prunes (see LibraryFolders.Kept)
        public var kept: LibraryFolders.Kept
        /// its size on disk
        public var bytes: UInt64
    }
    public struct Place: Sendable, Equatable {
        public var name: String
        /// nil when it isn't connected
        public var dir: URL?
        public var folders: [Folder]
        public var bytes: UInt64 { folders.reduce(0) { $0 + $1.bytes } }
    }
    public var places: [Place]

    /// Measure `job`'s folders at each destination that is connected. Walks them, so
    /// off the main thread.
    public static func measure(_ job: BackupJob, volumes: VolumeTable = SystemVolumeTable()) -> JobFootprint {
        let resolved = DestinationResolver(volumes: volumes).resolve(job)
        let labels = job.destinationLabels
        return JobFootprint(places: resolved.job.targets.map { t in
            guard let dir = resolved.presence[t.id]?.url else { return Place(name: labels[t.id] ?? t.displayName, dir: nil, folders: []) }
            var folders: [Folder] = []
            for lib in job.libraries {
                for f in LibraryFolders.folders(job: job, library: lib, in: dir) where !folders.contains(where: { $0.url == f }) {
                    folders.append(Folder(url: f, library: lib.displayName, versions: LibraryFolders.versionNames(in: f).count,
                                          hasCopy: LibraryFolders.holdsMirror(f), kept: LibraryFolders.kept(in: f),
                                          bytes: JobExecutor.directorySize(f)))
                }
            }
            return Place(name: labels[t.id] ?? t.displayName, dir: dir, folders: folders)
        })
    }
}
