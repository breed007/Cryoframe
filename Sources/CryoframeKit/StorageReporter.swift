//
//  StorageReporter.swift
//  CryoframeKit
//
//  How much space each job's archives use, and how much is free on the volume they
//  land on — so the user can see what versioning is keeping and tune retention
//  before a disk fills up. Sizes are measured on disk (du-style), so this is run
//  off the main thread.
//

import Foundation

public struct ArchiveSize: Sendable, Identifiable {
    public var id: String { library + (version.map { "@" + VersionStamp.string($0) } ?? "") }
    public var library: String
    public var version: Date?
    public var bytes: UInt64
    /// kept from before its job changed kind (see LibraryFolders.isKept)
    public var kept: Bool = false
    /// a plain-files copy's Removed items (see PlainCopy): this folder, which only the
    /// person empties, in Storage
    public var removedItems: URL? = nil
}

public struct JobStorage: Sendable, Identifiable {
    public var id: String { jobID + "@" + targetPath }   // one row per (job, destination)
    public var jobID: String
    public var jobName: String
    public var targetName: String
    public var targetPath: String
    public var archiveBytes: UInt64     // total on-disk size of this job's archives (all libraries + versions)
    public var versionCount: Int
    public var archives: [ArchiveSize]  // per-version breakdown, newest first
    public var volumeFree: UInt64?
    public var volumeTotal: UInt64?
    /// the destination's id in its job ("" when built without one)
    public var targetID: String = ""

    public init(jobID: String, jobName: String, targetName: String, targetPath: String,
                archiveBytes: UInt64, versionCount: Int, archives: [ArchiveSize], volumeFree: UInt64?, volumeTotal: UInt64?) {
        self.jobID = jobID; self.jobName = jobName; self.targetName = targetName; self.targetPath = targetPath
        self.archiveBytes = archiveBytes; self.versionCount = versionCount; self.archives = archives
        self.volumeFree = volumeFree; self.volumeTotal = volumeTotal
    }
}

public enum StorageReporter {
    public static func report(_ jobs: [BackupJob], volumes: VolumeTable = SystemVolumeTable()) -> [JobStorage] {
        // one row per (job, destination) so each copy's footprint is visible, each
        // destination where it is now (a renamed drive)
        jobs.map { DestinationResolver(volumes: volumes).resolve($0).job }.flatMap { job in
            job.targets.map { t in
                var archives: [ArchiveSize] = []
                for library in job.libraries {
                    // without reading an evicted manifest: that would download it, and
                    // undo what the cloud upload check looks for (see CloudUpload)
                    for a in LibraryFolders.archives(job: job, library: library, in: t.destinationDir, downloading: false) {
                        if a.format == .plainFiles {
                            // the copy, and what was deleted from the library, kept beside it
                            archives.append(ArchiveSize(library: a.libraryName, version: nil,
                                                        bytes: JobExecutor.directorySize(a.dir.appendingPathComponent(a.bundleName))))
                            let removed = a.dir.appendingPathComponent(PlainCopyLayout.removedFolder, isDirectory: true)
                            if FileManager.default.fileExists(atPath: removed.path) {
                                archives.append(ArchiveSize(library: "\(a.libraryName) · Removed items", version: nil,
                                                            bytes: JobExecutor.directorySize(removed), removedItems: removed))
                            }
                            continue
                        }
                        archives.append(ArchiveSize(library: a.libraryName, version: a.version,
                                                    bytes: JobExecutor.directorySize(a.dir), kept: LibraryFolders.isKept(a)))
                    }
                    // the up-to-date copy a format change left: not the job's current
                    // backup, but on its destination all the same
                    if let f = LibraryFolders.folder(job: job, library: library, in: t.destinationDir),
                       let kept = LibraryFolders.kept(in: f).mirror {
                        archives.append(ArchiveSize(library: library.displayName, version: nil,
                                                    bytes: JobExecutor.directorySize(f.appendingPathComponent(kept.name)), kept: true))
                    }
                }
                let v = volume(of: t.destinationDir)
                let name = job.targets.count > 1 ? "\(job.name) → \(t.displayName)" : job.name
                var row = JobStorage(jobID: job.id, jobName: name, targetName: t.displayName,
                                     targetPath: t.destinationDir.path,
                                     archiveBytes: archives.reduce(0) { $0 + $1.bytes }, versionCount: archives.count,
                                     archives: archives, volumeFree: v.free, volumeTotal: v.total)
                row.targetID = t.id
                return row
            }
        }
    }

    public static func volume(of url: URL) -> (free: UInt64?, total: UInt64?) {
        var dir = url
        for _ in 0..<8 {
            dir.removeAllCachedResourceValues()     // a URL keeps what it read; see JobExecutor.freeSpace
            // the first EXISTING ancestor is the volume being asked about. Read it and
            // stop, even when it answers "unknown" — walking further would step off an
            // external drive into /Volumes on the boot disk and report a free-space
            // figure belonging to an entirely different volume.
            if let v = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                         .volumeAvailableCapacityKey,
                                                         .volumeTotalCapacityKey]) {
                // "important usage" only means anything on the volume holding the home
                // directory. External drives, disk images, and network shares answer 0,
                // and 0 has to be read as "this filesystem doesn't say" rather than
                // "full" — otherwise every external destination looks like it has no
                // room for the next run, which is the alarm nobody can act on.
                return capacity(importantUsage: v.volumeAvailableCapacityForImportantUsage,
                                available: v.volumeAvailableCapacity,
                                total: v.volumeTotalCapacity)
            }
            let parent = dir.deletingLastPathComponent()
            if parent == dir { break }
            dir = parent
        }
        return (nil, nil)
    }

    /// map what a filesystem reports into what the UI may claim. Split out from the
    /// directory walk so the "0 means unknown" rule can be tested without a volume
    /// that answers 0 — which, being an external drive, is the awkward one to conjure.
    static func capacity(importantUsage: Int64?, available: Int?, total: Int?) -> (free: UInt64?, total: UInt64?) {
        (JobExecutor.usableFree(importantUsage: importantUsage, available: available),
         total.flatMap { $0 > 0 ? UInt64($0) : nil })
    }
}
