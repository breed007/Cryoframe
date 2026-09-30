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

    public init(checks: [ArchiveCheck]) { self.checks = checks }
}

/// the outcome for ONE archive version, kept in the health record so the UI can say
/// "this version was verified" about a specific point in time. Without it we'd only
/// know a job was checked, not which versions — and since scheduled checks default
/// to latest-only, assuming "the job passed" means "every version passed" would
/// claim an unverified backup is verified. Deliberately compact: these are stored
/// per record, and records are capped, not unbounded.
public struct VerifiedArchive: Codable, Sendable, Equatable {
    public var library: String
    public var version: Date?
    public var passed: Bool
    public var skipped: Bool

    public init(library: String, version: Date?, passed: Bool, skipped: Bool = false) {
        self.library = library; self.version = version; self.passed = passed; self.skipped = skipped
    }
}

public struct HealthChecker: Sendable {
    let verifier: ChecksumVerifier
    /// the mounted volumes, to find each destination where it is now
    let volumes: VolumeTable
    public init(verifier: ChecksumVerifier = ChecksumVerifier(), volumes: VolumeTable = SystemVolumeTable()) {
        self.verifier = verifier; self.volumes = volumes
    }

    /// re-verify the job's archives against their checksum manifests. `latestOnly`
    /// checks just the newest version per library — far less I/O than re-hashing
    /// every version of a large library on a schedule.
    public func check(job saved: BackupJob, latestOnly: Bool = false, materializeCloud: Bool = false) -> HealthReport {
        var checks: [ArchiveCheck] = []
        let multiDest = saved.targets.count > 1
        // each destination where it is now; one that isn't connected (or is another
        // drive of its name) has nothing here to check
        let (job, presence) = DestinationResolver(volumes: self.volumes).resolve(saved)
        for t in job.targets {
            if let p = presence[t.id], !p.isPresent, t.volume != nil || t.rotation != nil { continue }   // away: nothing to check
            let isCloud = t.kind == .cloudSync   // by kind, so pre-1.2 cloud jobs (no provider field) count too
            for library in job.libraries {
                var archives = LibraryFolders.archives(job: job, library: library, in: t.destinationDir)   // newest first
                if latestOnly { archives = Array(archives.prefix(1)) }      // its newest version, or its mirror
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
                    // a checksum that wasn't compared isn't a verified archive: say so,
                    // and don't count it either way (see MirrorSeal)
                    let report = try? verifier.reverify(archiveDir: archive.dir)
                    // an open mirror whose checksum couldn't be compared: not verified,
                    // and not failed either, unless it has lost a band (see MirrorSeal)
                    if archive.format == .liveMirror, MirrorSeal.isOpen(archive.dir), report?.passed == true {
                        checks.append(ArchiveCheck(library: archive.libraryName, version: archive.version, passed: true,
                                                   detail: MirrorSeal.uncheckedDetail,
                                                   destination: multiDest ? t.displayName : nil, skipped: true))
                        continue
                    }
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
    public var skipped: Int            // not checked: cloud placeholders not downloaded, drills without room
    /// why each skipped archive wasn't checked, as "Library (version): why" lines
    /// (empty on records before 1.6, when a skip was always a cloud placeholder)
    public var skipNotes: [String]
    public var verified: [VerifiedArchive]   // per-version outcomes (empty on pre-1.4 records)
    public var trigger: String              // "manual" (you asked) | "scheduled" (the agent) — decides who alerts

    public var passed: Bool { failures.isEmpty }
    public var isDrill: Bool { kind == "drill" }
    public var isRehearsal: Bool { kind == "rehearsal" }

    /// what this check actually did, for anywhere it's reported. A rehearsal is not
    /// a drill and not a checksum pass, and calling it either would misdescribe what
    /// was proven.
    public var passedSummary: String {
        switch kind {
        case "drill":     return "Restore-drilled"
        case "rehearsal": return "Recovery-rehearsed"
        default:          return "Archives verified"
        }
    }
    public var failureNoun: String {
        switch kind {
        case "drill":     return "restore drill"
        case "rehearsal": return "recovery rehearsal"
        default:          return "archive"
        }
    }
    public var explanation: String {
        switch kind {
        case "drill":     return "Reassembled, opened, and reopened each archive"
        case "rehearsal": return "Looked at the destination the way a recovery would, and opened what it found"
        default:          return "Re-verified against checksums"
        }
    }

    public init(id: String = UUID().uuidString, jobID: String, jobName: String, checkedAt: Date,
                archivesChecked: Int, failures: [String], kind: String = "checksum", skipped: Int = 0,
                verified: [VerifiedArchive] = [], trigger: String = "manual", skipNotes: [String] = []) {
        self.id = id; self.jobID = jobID; self.jobName = jobName; self.checkedAt = checkedAt
        self.archivesChecked = archivesChecked; self.failures = failures; self.kind = kind
        self.skipped = skipped; self.verified = verified; self.trigger = trigger; self.skipNotes = skipNotes
    }

    /// What the skipped archives were, in a few words: "2 cloud archives not
    /// downloaded" when each was a cloud placeholder (or the record predates the
    /// reasons), else "1 not checked: " and the first reason. nil when none was skipped.
    public var skipPhrase: String? {
        guard skipped > 0 else { return nil }
        let cloud = skipNotes.allSatisfy { $0.contains(HealthRecord.notDownloaded) }
        if cloud { return "\(skipped) cloud archive\(skipped == 1 ? "" : "s") not downloaded" }
        let why = skipNotes.first { !$0.contains(HealthRecord.notDownloaded) } ?? ""
        return "\(skipped) not checked: \(why)"
    }

    /// how a cloud placeholder's skip is worded (see HealthChecker, RestoreDriller)
    static let notDownloaded = "not downloaded"

    enum CodingKeys: String, CodingKey { case id, jobID, jobName, checkedAt, archivesChecked, failures, kind, skipped, verified, trigger, skipNotes }

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
        verified = try c.decodeIfPresent([VerifiedArchive].self, forKey: .verified) ?? []   // pre-1.4 records
        trigger = try c.decodeIfPresent(String.self, forKey: .trigger) ?? "manual"          // pre-1.5 records
        skipNotes = try c.decodeIfPresent([String].self, forKey: .skipNotes) ?? []           // pre-1.6 records
    }

    public static func from(job: BackupJob, report: HealthReport, at date: Date,
                            kind: String = "checksum", id: String = UUID().uuidString,
                            trigger: String = "manual") -> HealthRecord {
        let checked = report.checks.filter { !$0.skipped }
        func line(_ c: ArchiveCheck) -> String {
            let v = c.version.map { " (" + VersionStamp.string($0) + ")" } ?? ""
            let d = c.destination.map { " → " + $0 } ?? ""
            return "\(c.library)\(v)\(d): \(c.detail)"
        }
        return HealthRecord(id: id, jobID: job.id, jobName: job.name, checkedAt: date,
                     archivesChecked: checked.count,
                     failures: checked.filter { !$0.passed }.map(line), kind: kind, skipped: report.checks.filter(\.skipped).count,
                     // keep every check (including skipped) so the UI can tell
                     // "verified" from "never checked" from "not downloaded".
                     verified: report.checks.map {
                        VerifiedArchive(library: $0.library, version: $0.version,
                                        passed: $0.passed && !$0.skipped, skipped: $0.skipped)
                     }, trigger: trigger, skipNotes: report.checks.filter(\.skipped).map(line))
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

/// "Has this exact version been checked, and how thoroughly?" — what the restore
/// timeline needs to put an honest badge on a point in time.
///
/// A DRILL reassembles, opens, and reopens the archive: it proves the restore path
/// works. A CHECKSUM re-hash only proves the bytes still match the manifest. They
/// are not the same promise, so they're reported separately rather than collapsed
/// into one "verified" claim.
public enum ArchiveAssurance {
    public enum Level: Equatable { case drill, checksum }

    public struct Result: Equatable {
        public let level: Level
        public let checkedAt: Date
    }

    /// the most recent PASSING check covering this library + version, or nil if this
    /// version has never been checked (a skipped cloud placeholder counts as never).
    /// Records are expected newest-first, as HealthStore.all() returns them.
    public static func lastVerified(library: String, version: Date?,
                                    in records: [HealthRecord]) -> Result? {
        // prefer a drill over a checksum, even if the checksum is more recent: the
        // stronger promise is the one worth showing.
        var best: Result?
        for r in records {
            // a multi-destination job checks this version once PER COPY. Only call it
            // verified when every copy checked in that run passed — otherwise we'd
            // vouch for a version whose copy on the drive you're restoring from is bad.
            let mine = r.verified.filter { matches($0, library: library, version: version) }
            guard !mine.isEmpty, mine.allSatisfy({ $0.passed && !$0.skipped })
            else { continue }
            let level: Level = r.isDrill ? .drill : .checksum
            let candidate = Result(level: level, checkedAt: r.checkedAt)
            switch best {
            case .none: best = candidate
            case .some(let b):
                if b.level == .checksum && level == .drill { best = candidate }      // upgrade
                else if b.level == level && candidate.checkedAt > b.checkedAt { best = candidate }
            }
        }
        return best
    }

    private static func matches(_ v: VerifiedArchive, library: String, version: Date?) -> Bool {
        guard v.library == library else { return false }
        // compare via the stamp string so two Dates parsed from the same folder name
        // always agree, regardless of sub-second representation.
        switch (v.version, version) {
        case (nil, nil): return true
        case let (a?, b?): return VersionStamp.string(a) == VersionStamp.string(b)
        default: return false
        }
    }
}

/// Which jobs a scheduled pass of checks (health checks, rehearsals) looks at.
///
/// Each job is checked holding its run lock, and one a run holds is skipped. It is
/// remembered, and looked at on the agent's next hourly pass, instead of going
/// unchecked until the next week or month.
public enum CheckRound {
    /// every job when the pass is due; otherwise only those skipped last time
    public static func jobs(_ all: [BackupJob], due: Bool, pending: Set<String>) -> [BackupJob] {
        due ? all : all.filter { pending.contains($0.id) }
    }
}
