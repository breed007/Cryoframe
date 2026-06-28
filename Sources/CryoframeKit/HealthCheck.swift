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
    public var id: String { library + (version.map { "@" + VersionStamp.string($0) } ?? "") + (destination.map { "→" + $0 } ?? "") }
    public var library: String
    public var version: Date?
    public var passed: Bool
    public var detail: String
    public var destination: String?      // which copy; nil for a single-destination job
    public var skipped: Bool = false     // a cloud placeholder we chose not to download — not checked, not failed

    public init(library: String, version: Date?, passed: Bool, detail: String,
                destination: String? = nil, skipped: Bool = false) {
        self.library = library; self.version = version; self.passed = passed
        self.detail = detail; self.destination = destination; self.skipped = skipped
    }
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
    public func check(job: BackupJob, latestOnly: Bool = false, materializeCloud: Bool = false) -> HealthReport {
        var checks: [ArchiveCheck] = []
        let multiDest = job.targets.count > 1
        for t in job.targets {
            let isCloud = t.kind == .cloudSync   // by kind, so pre-1.2 cloud jobs (no provider field) count too
            for library in job.libraries {
                let libDir = t.destinationDir.appendingPathComponent(library.displayName, isDirectory: true)
                var archives = RestoreDiscovery.scan(libDir)        // sorted newest-first per library
                if latestOnly {
                    var seen = Set<String>()
                    archives = archives.filter { seen.insert($0.libraryName).inserted }
                }
                for archive in archives {
                    // a cloud archive evicted to a placeholder: skip it (don't trigger a
                    // surprise re-download) unless the user opted to download for checks.
                    if isCloud, CloudFile.anyDataless(in: archive.dir) {
                        if !materializeCloud {
                            checks.append(ArchiveCheck(library: archive.libraryName, version: archive.version, passed: true,
                                                       detail: "not downloaded from \(t.cloudProvider?.displayName ?? "the cloud folder") — skipped",
                                                       destination: multiDest ? t.displayName : nil, skipped: true))
                            continue
                        }
                        CloudFile.materialize(archive.dir)
                    }
                    let report = try? verifier.reverify(archiveDir: archive.dir)
                    checks.append(ArchiveCheck(library: archive.libraryName, version: archive.version,
                                               passed: report?.passed ?? false,
                                               detail: report?.details ?? "could not read manifest",
                                               destination: multiDest ? t.displayName : nil))
                }
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
    public var kind: String            // "checksum" (re-hash) | "drill" (restore + reopen)
    public var skipped: Int            // cloud placeholders not downloaded, so not checked

    public var passed: Bool { failures.isEmpty }
    public var isDrill: Bool { kind == "drill" }

    public init(id: String = UUID().uuidString, jobID: String, jobName: String, checkedAt: Date,
                archivesChecked: Int, failures: [String], kind: String = "checksum", skipped: Int = 0) {
        self.id = id; self.jobID = jobID; self.jobName = jobName; self.checkedAt = checkedAt
        self.archivesChecked = archivesChecked; self.failures = failures; self.kind = kind; self.skipped = skipped
    }

    enum CodingKeys: String, CodingKey { case id, jobID, jobName, checkedAt, archivesChecked, failures, kind, skipped }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        jobID = try c.decode(String.self, forKey: .jobID)
        jobName = try c.decode(String.self, forKey: .jobName)
        checkedAt = try c.decode(Date.self, forKey: .checkedAt)
        archivesChecked = try c.decode(Int.self, forKey: .archivesChecked)
        failures = try c.decode([String].self, forKey: .failures)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "checksum"   // pre-1.1 records
        skipped = try c.decodeIfPresent(Int.self, forKey: .skipped) ?? 0          // pre-1.2 records
    }

    public static func from(job: BackupJob, report: HealthReport, at date: Date,
                            kind: String = "checksum", id: String = UUID().uuidString) -> HealthRecord {
        let checked = report.checks.filter { !$0.skipped }
        return HealthRecord(id: id, jobID: job.id, jobName: job.name, checkedAt: date,
                     archivesChecked: checked.count,
                     failures: checked.filter { !$0.passed }.map { c in
                        let v = c.version.map { " (" + VersionStamp.string($0) + ")" } ?? ""
                        let d = c.destination.map { " → " + $0 } ?? ""
                        return "\(c.library)\(v)\(d): \(c.detail)"
                     }, kind: kind, skipped: report.checks.filter(\.skipped).count)
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
