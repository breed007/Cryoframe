//
//  DestinationHealth.swift
//  CryoframeKit
//
//  How each of a job's destinations has fared, run by run: whether the run's copies
//  landed there, how much it wrote, how long the run took, the room left after it.
//  The Storage window shows it as "Last 30 runs: 29 good, 1 failed" and a small
//  chart, so a drive that fails one run in five, or a share that has turned slow,
//  shows before it fails outright.
//
//  It is information only. Nothing here feeds the protection verdict or an alert:
//  the run history and the checks already do that, with rules of their own.
//
//  destination-health.json holds a ring of the last 100 runs for each (job,
//  destination). The app and the agent both add to it (see SharedJSONFile), and the
//  rings of jobs or destinations that are gone are dropped when it is read for the
//  window, so the file can't grow with every job ever made.
//

import Foundation

/// one run, as one destination saw it
public struct DestinationRun: Codable, Sendable, Equatable {
    /// when the run finished
    public var at: Date
    /// every copy the run made there landed (and passed verification, where asked)
    public var good: Bool
    /// bytes written there
    public var bytes: UInt64
    /// how long the whole run took; a run writes its destinations one after another,
    /// so this is the run's time, not this destination's alone
    public var seconds: Double
    /// free space on the destination after the run; nil when it couldn't be read
    public var freeAfter: UInt64?
    /// whether the job's latest finished check had passed when the run ended; nil: none yet
    public var checkPassed: Bool?

    public init(at: Date, good: Bool, bytes: UInt64, seconds: Double, freeAfter: UInt64?, checkPassed: Bool?) {
        self.at = at; self.good = good; self.bytes = bytes; self.seconds = seconds
        self.freeAfter = freeAfter; self.checkPassed = checkPassed
    }
}

/// What the Storage window says about a destination's recent runs.
public struct DestinationTrend: Sendable, Equatable {
    /// the runs looked at, oldest first (at most `window`)
    public let runs: [DestinationRun]
    public let good: Int
    public let failed: Int
    /// the newest run took over twice as long as the median of the ten good runs
    /// before it. Information only: a slow run is still a good one.
    public let slowerThanUsual: Bool

    public static let window = 30

    /// nil when the destination has no runs on record
    public init?(_ newestFirst: [DestinationRun]) {
        guard !newestFirst.isEmpty else { return nil }
        let recent = Array(newestFirst.prefix(Self.window))
        runs = recent.reversed()
        good = recent.filter(\.good).count
        failed = recent.count - good
        slowerThanUsual = Self.slower(newestFirst)
    }

    /// "Last 30 runs: 29 good, 1 failed"
    public var line: String {
        let n = runs.count
        let head = n == 1 ? "Last run" : "Last \(n) runs"
        if failed == 0 { return n == 1 ? "\(head): good" : "\(head): all good" }
        if good == 0 { return n == 1 ? "\(head): failed" : "\(head): all failed" }
        return "\(head): \(good) good, \(failed) failed"
    }

    static func slower(_ newestFirst: [DestinationRun]) -> Bool {
        guard let latest = newestFirst.first, latest.good else { return false }
        let before = newestFirst.dropFirst().filter(\.good).prefix(10).map(\.seconds).sorted()
        guard before.count >= 5 else { return false }
        let mid = before.count / 2
        let median = before.count % 2 == 1 ? before[mid] : (before[mid - 1] + before[mid]) / 2
        // a run of a few seconds taking a few more isn't news
        return median > 0 && latest.seconds > 2 * median && latest.seconds - median >= 60
    }
}

public final class DestinationHealthStore: @unchecked Sendable {
    struct File: Codable {
        /// "jobID|targetID" → runs, oldest first
        var rings: [String: [DestinationRun]] = [:]
    }

    private let file: SharedJSONFile<File>
    private let cap: Int
    public var fileURL: URL { file.url }

    public static let defaultCap = 100

    public init(url: URL, cap: Int = DestinationHealthStore.defaultCap) {
        file = SharedJSONFile(url: url, lockName: "destination-health.lock", empty: { File() })
        self.cap = cap
    }

    public static func standard() -> DestinationHealthStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.cryoframe", isDirectory: true)
        return DestinationHealthStore(url: base.appendingPathComponent("destination-health.json"))
    }

    public func append(_ run: DestinationRun, for key: DestinationKey) {
        file.update { f in
            var ring = f.rings[key.string] ?? []
            ring.append(run)
            if ring.count > cap { ring.removeFirst(ring.count - cap) }
            f.rings[key.string] = ring
            return (true, ())
        }
    }

    /// the destination's runs, newest first
    public func runs(for key: DestinationKey) -> [DestinationRun] {
        (file.read().rings[key.string] ?? []).reversed()
    }

    /// Every ring the jobs still have, newest first, with the rings of jobs and
    /// destinations that are gone dropped from the file.
    @discardableResult
    public func load(keeping keys: Set<DestinationKey>) -> [DestinationKey: [DestinationRun]] {
        let wanted = Dictionary(uniqueKeysWithValues: keys.map { ($0.string, $0) })
        return file.update { f in
            let before = f.rings.count
            f.rings = f.rings.filter { wanted[$0.key] != nil }
            var out: [DestinationKey: [DestinationRun]] = [:]
            for (k, ring) in f.rings { if let key = wanted[k] { out[key] = ring.reversed() } }
            return (f.rings.count != before, out)
        }
    }
}

/// What a finished run leaves behind beside its history record: a line in each
/// destination's trend, and its new versions in cloud folders on the list of
/// versions not yet known to be uploaded (see UploadLedger). The app and the agent
/// both call it after recording a run.
public enum RunFollowUp {
    public static func record(_ record: RunRecord, job: BackupJob, health: DestinationHealthStore,
                              uploads: UploadLedger?, lastCheck: HealthRecord?,
                              volumes: VolumeTable = SystemVolumeTable(),
                              freeSpace: (URL) -> UInt64? = { JobExecutor.freeSpace(for: $0) }) {
        let labels = job.destinationLabels
        let placed = DestinationResolver(volumes: volumes).resolve(job).job
        for t in placed.targets {
            // only runs that got as far as this destination: a run that failed before
            // writing anything (no snapshot, stopped) says nothing about the drive
            let name = labels[t.id] ?? t.displayName
            let outcomes = record.libraries.filter { $0.destination == name }
            guard !outcomes.isEmpty else { continue }
            let good = outcomes.allSatisfy { $0.status == "verified" || $0.status == "archived" }
            var isDir: ObjCBool = false
            let here = FileManager.default.fileExists(atPath: t.destinationDir.path, isDirectory: &isDir) && isDir.boolValue
            let run = DestinationRun(at: record.finishedAt, good: good, bytes: outcomes.reduce(0) { $0 + $1.bytes },
                                     seconds: record.duration, freeAfter: here ? freeSpace(t.destinationDir) : nil,
                                     checkPassed: lastCheck?.passed)
            health.append(run, for: DestinationKey(jobID: job.id, targetID: t.id))

            if let uploads, t.kind == .cloudSync, here, outcomes.contains(where: { $0.parts > 0 }) {
                let versions = job.libraries.compactMap { lib in
                    LibraryFolders.archives(job: job, library: lib, in: t.destinationDir).first { $0.version != nil }
                }
                uploads.record(versions.map { UploadEntry(version: $0.dir.path, runAt: $0.version ?? record.finishedAt) },
                               for: DestinationKey(jobID: job.id, targetID: t.id))
            }
        }
    }
}
