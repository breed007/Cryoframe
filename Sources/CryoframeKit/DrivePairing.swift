//
//  DrivePairing.swift
//  CryoframeKit
//
//  "Is this one of your drives?": a destination set up before 1.6 meets another
//  drive of its drive's name at its folder.
//
//  Through 1.5 the only way to take turns between two drives was two drives of one
//  name, since a destination was a path. 1.6 knows a destination by its drive, so
//  the drive that wasn't plugged in at the first 1.6 run is "a different drive"
//  from then on. A sealed job's run can tell its own drive by the versions its runs
//  made (see LibraryFolders.holdsBackups); a mirror job's can't (a mirror carries
//  no run's stamp), so it asks. What it shows is what saying yes does, library by
//  library: the up-to-date copy that is replaced, and the dated versions that now
//  follow the job's Keep rule, with how many of them that deletes. A drive holding
//  another job's backups (by their identity files: another job of this Mac, a
//  deleted one, another Mac's) isn't offered at all: it is some other drive, however
//  it's named.
//

import Foundation

public struct DrivePairing: Sendable, Equatable {
    /// What one library has on the drive, and what taking turns does to it.
    public struct Library: Sendable, Equatable {
        public var name: String
        /// the up-to-date copy there (a mirror): when it was last brought up to date,
        /// and its size on disk
        public var copy: Copy?
        /// the dated versions there, newest first
        public var versions: [Date]
        public var versionBytes: UInt64
        /// of `versions`, how many the next run deletes (this job's Keep rule)
        public var deletes: Int
        /// what the next run does, in words
        public var effects: [String]

        public struct Copy: Sendable, Equatable {
            public var date: Date?
            public var bytes: UInt64
        }
    }

    /// the drive, as recorded once the pairing is saved
    public var drive: VolumeIdentity
    public var libraries: [Library]
    /// why it can't be one of this job's drives; nil when it can
    public var refusal: String?

    /// What pairing `target` of `job` with the other drive of its name connected at
    /// its folder would do; nil when there is no such drive. `jobs`: every saved job
    /// (whose backups on the drive are whose). `checks`: the archive checks recorded,
    /// for what retention keeps (see KnownGood). Reads the drive; changes nothing.
    public static func look(_ target: Target, job: BackupJob, jobs: [BackupJob], volumes: VolumeTable = SystemVolumeTable(),
                            checks: [HealthRecord] = [], now: Date = Date()) -> DrivePairing? {
        let resolver = DestinationResolver(volumes: volumes)
        guard let own = target.volume, !own.isShare, case .otherDrive = resolver.locate(target),
              let here = volumes.volume(containing: target.destinationDir), let uuid = here.uuid, uuid != own.uuid,
              !(target.otherVolumes ?? []).contains(where: { $0.uuid == uuid }),
              let drive = resolver.identity(for: target.destinationDir) else { return nil }
        let dir = target.destinationDir
        let entries = LibraryFolders.listing(dir)

        // backups of anything but this job, by identity: not one of its drives. Another
        // job of this Mac that already knows this very drive doesn't count against it.
        let knowing = Set(jobs.filter { j in
            j.targets.contains { t in t.volume?.uuid == uuid || (t.otherVolumes ?? []).contains { $0.uuid == uuid } }
        }.map(\.id))
        if let foreign = entries.first(where: { e in e.identity.map { $0.jobID != job.id && !knowing.contains($0.jobID) } ?? false }),
           let who = foreign.identity {
            let whose = jobs.contains { $0.id == who.jobID } ? "another of your jobs (“\(who.jobName)”)"
                : "a job that isn't on this Mac (“\(who.jobName)”)"
            return DrivePairing(drive: drive, libraries: [], refusal:
                "“\(foreign.url.lastPathComponent)” on this drive holds backups made by \(whose), so it isn't \(target.displayName)'s other drive. To use it too, rename it and add it as a destination of its own.")
        }

        let all = jobs.filter { $0.id != job.id } + [job]
        let libraries = job.libraries.map { lib -> Library in
            let key = LibraryIdentity.key(job: job, library: lib)
            let mine = entries.first { $0.identity?.key == key }
            let legacy = entries.first { $0.identity == nil && lib.answers(to: $0.url.lastPathComponent) }
            guard let folder = mine?.url ?? legacy?.url else {
                return Library(name: lib.displayName, copy: nil, versions: [], versionBytes: 0, deletes: 0,
                               effects: ["The next backup makes its folder there."])
            }
            let adopted = mine != nil || LibraryFolders.owner(of: folder, in: dir, jobs: all) == key
            let top = RestoreDiscovery.archive(at: folder).flatMap { $0.format == .liveMirror && $0.version == nil ? $0 : nil }
            let copy = top.map { _ in
                Library.Copy(date: modified(folder.appendingPathComponent(ArchiveManifest.sidecarName)),
                             bytes: LibraryFolders.mirrorImage(in: folder).map { JobExecutor.directorySize(folder.appendingPathComponent($0)) } ?? 0)
            }
            let found = RestoreDiscovery.scan(folder, maxDepth: 1).filter { $0.version != nil }
            let versions = found.compactMap(\.version).sorted(by: >)
            let versionBytes = found.reduce(UInt64(0)) { $0 + $1.bytes }
            var effects: [String] = []
            var deletes = 0
            if !adopted {
                effects.append("The folder there isn't only this job's to take, so it stays as it is and the next backup makes a new one beside it.")
            } else if job.format.isSealed {
                if copy != nil { effects.append("Its up-to-date copy there stays as it is.") }
                if !versions.isEmpty {
                    let plan = JobExecutor.prunePlan(folders: [(lib, folder)], policy: job.retention, checks: checks, upcoming: now)
                    deletes = plan.versions.count
                    effects.append("\(versions.count) dated version\(versions.count == 1 ? "" : "s") now follow this job's Keep rule"
                                   + (deletes > 0 ? "; \(deletes) \(deletes == 1 ? "is" : "are") deleted at the next backup." : "; none are deleted."))
                }
            } else {
                if let c = copy {
                    effects.append("The next backup replaces the copy from \(c.date.map(Self.day) ?? "an unknown date") (\(Self.size(c.bytes))) with an up-to-date one.")
                } else {
                    effects.append("The next backup makes an up-to-date copy there.")
                }
                if !versions.isEmpty {
                    effects.append("\(versions.count) dated version\(versions.count == 1 ? "" : "s") there stay as they are.")
                }
            }
            return Library(name: lib.displayName, copy: copy, versions: versions, versionBytes: versionBytes,
                           deletes: deletes, effects: effects)
        }
        return DrivePairing(drive: drive, libraries: libraries, refusal: nil)
    }

    static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    static func day(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .omitted) }

    static func size(_ bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
}
