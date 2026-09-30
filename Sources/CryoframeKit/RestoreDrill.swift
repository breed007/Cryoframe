//
//  RestoreDrill.swift
//  CryoframeKit
//
//  A restore drill is a deeper check than a checksum re-hash: it actually reassembles
//  the parts, mounts or extracts the archive, and reopens the library (a SQLite
//  integrity check on database libraries). That proves the whole restore path works —
//  the failure mode a checksum can't catch, where the bytes are intact but the archive
//  won't open. Reuses the same HealthReport/ArchiveCheck shape as the checksum health
//  check, so it surfaces through the same job row, History, notifications, and alerts.
//

import Foundation

public struct RestoreDriller: Sendable {
    let runner: CommandRunner
    /// free bytes on the drive holding a folder (nil: unknown); injectable for tests
    let freeSpace: @Sendable (URL) -> UInt64?
    /// the mounted volumes, to find each destination where it is now
    let volumes: VolumeTable
    public init(runner: CommandRunner = ProcessCommandRunner(),
                freeSpace: @escaping @Sendable (URL) -> UInt64? = { JobExecutor.freeSpace(for: $0) },
                volumes: VolumeTable = SystemVolumeTable()) {
        self.runner = runner; self.freeSpace = freeSpace; self.volumes = volumes
    }

    /// drill the job's archives: `latestOnly` checks just the newest version per library
    /// per destination; `passphrase` opens an encrypted job's archives.
    public func drill(job saved: BackupJob, latestOnly: Bool = false, passphrase: String? = nil,
                      materializeCloud: Bool = false) -> HealthReport {
        var checks: [ArchiveCheck] = []
        let multiDest = saved.targets.count > 1
        // each destination where it is now; one that isn't connected (or is another
        // drive of its name) has nothing here to drill
        let (job, presence) = DestinationResolver(volumes: self.volumes).resolve(saved)
        for t in job.targets {
            if let p = presence[t.id], !p.isPresent, t.volume != nil || t.rotation != nil { continue }   // away: nothing to drill
            let isCloud = t.kind == .cloudSync   // by kind, so pre-1.2 cloud jobs (no provider field) count too
            for library in job.libraries {
                var archives = LibraryFolders.archives(job: job, library: library, in: t.destinationDir)   // newest first
                if latestOnly { archives = Array(archives.prefix(1)) }      // its newest version, or its mirror
                for archive in archives {
                    // a drill restores the whole archive, so an evicted cloud placeholder
                    // would pull it all down — skip unless the user opted to download.
                    if isCloud, CloudFile.anyDataless(in: archive.dir) {
                        if !materializeCloud {
                            checks.append(ArchiveCheck(library: archive.libraryName, version: archive.version, passed: true,
                                                       detail: "not downloaded from \(t.cloudProvider?.displayName ?? "the cloud folder") — skipped",
                                                       destination: multiDest ? t.displayName : nil, skipped: true))
                            continue
                        }
                        CloudFile.materialize(archive.dir)
                    }
                    let type = library
                    let (passed, detail, skipped) = drillOne(archive, type: type, passphrase: job.encrypted ? passphrase : nil)
                    checks.append(ArchiveCheck(library: archive.libraryName, version: archive.version,
                                               passed: passed, detail: detail,
                                               destination: multiDest ? t.displayName : nil, skipped: skipped))
                }
            }
        }
        return HealthReport(checks: checks)
    }

    /// passed, what to say, and whether it was skipped rather than checked
    func drillOne(_ archive: RestorableArchive, type: ContentType, passphrase: String?) -> (Bool, String, Bool) {
        // 1. the bytes still match the manifest
        guard let checksum = try? ChecksumVerifier().reverify(archiveDir: archive.dir) else {
            return (false, "couldn't read the checksum manifest", false)
        }
        guard checksum.passed else { return (false, "checksum — \(checksum.details)", false) }

        // 2. it reassembles, opens, and the library reopens clean
        do {
            let r = try StrongVerifier(runner: runner, freeSpace: freeSpace).verify(archive.archiveResult(), type: type, passphrase: passphrase)
            return (r.passed, r.passed ? "restored and reopened clean" : r.details, false)
        } catch let RestoreError.notEnoughRoom(needed, free, volume, _) {
            // Split parts are joined, and a zip unpacked, on the startup disk first. One
            // without the room for that is refused before anything is written, which says
            // nothing about the archive: it was a failed check, blaming the passphrase,
            // and an alert, for every drill of a large split or zipped archive.
            let f = ByteCountFormatter()
            return (true, "not drilled: not enough room on \(volume) (it needs about \(f.string(fromByteCount: Int64(clamping: needed))) free and has \(f.string(fromByteCount: Int64(clamping: free)))); the checksum passed", true)
        } catch let e as RestoreError {
            return (false, RestoreFailureText.restoreMessage(e, encrypted: archive.encrypted), false)
        } catch let e as DiskImageInUse {
            return (false, e.localizedDescription, false)
        } catch {
            let why = archive.encrypted ? "couldn't open — check the passphrase" : "couldn't open the archive"
            return (false, why, false)
        }
    }
}
