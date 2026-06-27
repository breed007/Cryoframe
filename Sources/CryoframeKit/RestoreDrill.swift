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
    public init(runner: CommandRunner = ProcessCommandRunner()) { self.runner = runner }

    /// drill the job's archives: `latestOnly` checks just the newest version per library
    /// per destination; `passphrase` opens an encrypted job's archives.
    public func drill(job: BackupJob, latestOnly: Bool = false, passphrase: String? = nil) -> HealthReport {
        var checks: [ArchiveCheck] = []
        let multiDest = job.targets.count > 1
        let typeByName = Dictionary(job.libraries.map { ($0.displayName, $0) }, uniquingKeysWith: { a, _ in a })
        for t in job.targets {
            for library in job.libraries {
                let libDir = t.destinationDir.appendingPathComponent(library.displayName, isDirectory: true)
                var archives = RestoreDiscovery.scan(libDir)        // newest-first per library
                if latestOnly {
                    var seen = Set<String>()
                    archives = archives.filter { seen.insert($0.libraryName).inserted }
                }
                for archive in archives {
                    let type = typeByName[archive.libraryName] ?? library
                    let (passed, detail) = drillOne(archive, type: type, passphrase: job.encrypted ? passphrase : nil)
                    checks.append(ArchiveCheck(library: archive.libraryName, version: archive.version,
                                               passed: passed, detail: detail,
                                               destination: multiDest ? t.displayName : nil))
                }
            }
        }
        return HealthReport(checks: checks)
    }

    private func drillOne(_ archive: RestorableArchive, type: ContentType, passphrase: String?) -> (Bool, String) {
        // 1. the bytes still match the manifest
        guard let checksum = try? ChecksumVerifier().reverify(archiveDir: archive.dir) else {
            return (false, "couldn't read the checksum manifest")
        }
        guard checksum.passed else { return (false, "checksum — \(checksum.details)") }

        // 2. it reassembles, opens, and the library reopens clean
        do {
            let r = try StrongVerifier(runner: runner).verify(archive.archiveResult(), type: type, passphrase: passphrase)
            return (r.passed, r.passed ? "restored and reopened clean" : r.details)
        } catch {
            let why = archive.encrypted ? "couldn't open — check the passphrase" : "couldn't open the archive"
            return (false, why)
        }
    }
}
