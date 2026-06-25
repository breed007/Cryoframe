//
//  HealthCheck.swift
//  CryoframeKit
//
//  Cold archives can rot — a flipped bit, a file a NAS quietly dropped. Health
//  monitoring re-hashes existing archives against the manifest written when they
//  were made, so corruption is caught long before a restore needs them. Checksums
//  are over the on-disk artifact bytes, so this works for encrypted archives too,
//  with no passphrase. Runs on demand per job and on a schedule.
//

import Foundation

public struct ArchiveCheck: Codable, Sendable, Equatable, Identifiable {
    public var id: String { library + (version.map { "@" + VersionStamp.string($0) } ?? "") }
    public var library: String
    public var version: Date?
    public var passed: Bool
    public var detail: String
}

public struct HealthReport: Sendable {
    public var checks: [ArchiveCheck]
    public var passed: Bool { checks.allSatisfy(\.passed) }
}

public struct HealthChecker: Sendable {
    let verifier: ChecksumVerifier
    public init(verifier: ChecksumVerifier = ChecksumVerifier()) { self.verifier = verifier }

    /// re-verify the job's archives against their checksum manifests. `latestOnly`
    /// checks just the newest version per library — far less I/O than re-hashing
    /// every version of a large library on a schedule.
    public func check(job: BackupJob, latestOnly: Bool = false) -> HealthReport {
        var checks: [ArchiveCheck] = []
        for library in job.libraries {
            let libDir = job.target.destinationDir.appendingPathComponent(library.displayName, isDirectory: true)
            var archives = RestoreDiscovery.scan(libDir)        // sorted newest-first per library
            if latestOnly {
                var seen = Set<String>()
                archives = archives.filter { seen.insert($0.libraryName).inserted }
            }
            for archive in archives {
                let report = try? verifier.reverify(archiveDir: archive.dir)
                checks.append(ArchiveCheck(library: archive.libraryName, version: archive.version,
                                           passed: report?.passed ?? false,
                                           detail: report?.details ?? "could not read manifest"))
            }
        }
        return HealthReport(checks: checks)
    }
}

public struct HealthRecord: Codable, Sendable, Identifiable {
    public var id: String
    public var jobID: String
    public var jobName: String
    public var checkedAt: Date
    public var archivesChecked: Int
    public var failures: [String]      // human lines: "Photos (2026-06-24): checksum mismatch …"

    public var passed: Bool { failures.isEmpty }

    public init(id: String = UUID().uuidString, jobID: String, jobName: String, checkedAt: Date,
                archivesChecked: Int, failures: [String]) {
        self.id = id; self.jobID = jobID; self.jobName = jobName; self.checkedAt = checkedAt
        self.archivesChecked = archivesChecked; self.failures = failures
    }

    public static func from(job: BackupJob, report: HealthReport, at date: Date, id: String = UUID().uuidString) -> HealthRecord {
        HealthRecord(id: id, jobID: job.id, jobName: job.name, checkedAt: date,
                     archivesChecked: report.checks.count,
                     failures: report.checks.filter { !$0.passed }.map { c in
                        let v = c.version.map { " (" + VersionStamp.string($0) + ")" } ?? ""
                        return "\(c.library)\(v): \(c.detail)"
                     })
    }
}

public final class HealthStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private let cap: Int

    public init(url: URL, cap: Int = 200) { self.url = url; self.cap = cap }

    public static func standard() -> HealthStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.cryoframe", isDirectory: true)
        return HealthStore(url: base.appendingPathComponent("archive-health.json"))
    }

    public func all() -> [HealthRecord] {                  // newest first
        lock.lock(); defer { lock.unlock() }
        return decode()
    }

    public func append(_ record: HealthRecord) {
        lock.lock(); defer { lock.unlock() }
        var list = decode()
        list.insert(record, at: 0)
        if list.count > cap { list = Array(list.prefix(cap)) }
        write(list)
    }

    public func latest(forJob jobID: String) -> HealthRecord? { all().first { $0.jobID == jobID } }

    private func decode() -> [HealthRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([HealthRecord].self, from: data)) ?? []
    }
    private func write(_ list: [HealthRecord]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(list) { try? data.write(to: url, options: .atomic) }
    }
}
