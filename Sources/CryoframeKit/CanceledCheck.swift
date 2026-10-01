//
//  CanceledCheck.swift
//  CryoframeKit
//
//  A check of a job's archives (checksums, a restore drill, a recovery rehearsal)
//  that Stop ended part-way is not a check of the job, and is never recorded as one.
//
//  archive-health.json holds finished checks only. HealthStore.latest(forJob:) is the
//  job's newest record there and feeds the verdict, the alerts and the job row, and
//  a record that checked 0 archives raises "no archives found… is the target
//  connected?". So a stopped check written there would have counted as the job's
//  latest check: passed if nothing it got to failed, or an alert if it got to
//  nothing. 1.5.6 reads that same file and would ignore any marker a stopped record
//  carried. A stopped check goes to canceled-checks.json instead, which nothing that
//  judges a job reads, and the job's last finished check stands.
//

import Foundation

/// what a stopped check got through, for the Health list: "Stopped after 3 of 7;
/// those 3 opened"
public struct CanceledCheck: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var jobID: String
    public var jobName: String
    /// "checksum" | "drill" | "rehearsal", as HealthRecord.kind
    public var kind: String
    public var stoppedAt: Date
    /// archives finished before Stop, skipped ones included
    public var finished: Int
    /// archives the check set out to look at
    public var planned: Int
    public var failures: [String]
    public var skipped: Int
    public var trigger: String

    public init(id: String = UUID().uuidString, jobID: String, jobName: String, kind: String, stoppedAt: Date,
                finished: Int, planned: Int, failures: [String], skipped: Int, trigger: String) {
        self.id = id; self.jobID = jobID; self.jobName = jobName; self.kind = kind; self.stoppedAt = stoppedAt
        self.finished = finished; self.planned = planned; self.failures = failures; self.skipped = skipped
        self.trigger = trigger
    }

    public static func from(job: BackupJob, report: HealthReport, at date: Date, kind: String,
                            trigger: String) -> CanceledCheck {
        let record = HealthRecord.from(job: job, report: report, at: date, kind: kind, trigger: trigger)
        return CanceledCheck(jobID: job.id, jobName: job.name, kind: kind, stoppedAt: date,
                             finished: report.checks.count, planned: max(report.planned, report.checks.count),
                             failures: record.failures, skipped: record.skipped, trigger: trigger)
    }

    /// "Stopped after 3 of 7; those 3 opened", in the words of what the check does
    public var summary: String {
        let noun = kind == "rehearsal" ? "library" : "archive"
        let nouns = kind == "rehearsal" ? "libraries" : "archives"
        guard finished > 0 else {
            return planned > 0 ? "Stopped before any of its \(planned) \(planned == 1 ? noun : nouns) was checked" : "Stopped before anything was checked"
        }
        let done = kind == "checksum" ? "matched its checksums" : "opened"
        let doneMany = kind == "checksum" ? "matched their checksums" : "opened"
        let failed = failures.count
        let good = finished - failed - skipped
        var said = "Stopped after \(finished) of \(planned)"
        if failed == 0, skipped == 0 {
            said += finished == 1 ? "; it \(done)" : "; those \(finished) \(doneMany)"
        } else {
            var parts: [String] = []
            if good > 0 { parts.append("\(good) \(good == 1 ? done : doneMany)") }
            if failed > 0 { parts.append("\(failed) failed") }
            if skipped > 0 { parts.append("\(skipped) skipped") }
            said += "; " + parts.joined(separator: ", ")
        }
        return said
    }
}

/// canceled-checks.json: the last few stopped checks, newest first. The app and the
/// scheduled agent both write it, so each write is a read, change and write under a
/// lock file, written whole.
public final class CanceledCheckStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private let cap: Int

    public static let defaultCap = 20

    public init(url: URL, cap: Int = CanceledCheckStore.defaultCap) { self.url = url; self.cap = cap }

    public static func standard() -> CanceledCheckStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.cryoframe", isDirectory: true)
        return CanceledCheckStore(url: base.appendingPathComponent("canceled-checks.json"))
    }

    public func all() -> [CanceledCheck] {
        lock.lock(); defer { lock.unlock() }
        return decode()
    }

    public func append(_ check: CanceledCheck) {
        lock.lock(); defer { lock.unlock() }
        let fd = takeFileLock()
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        var list = decode()
        list.insert(check, at: 0)
        if list.count > cap { list = Array(list.prefix(cap)) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(list) { try? data.write(to: url, options: .atomic) }
    }

    private func decode() -> [CanceledCheck] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([CanceledCheck].self, from: data)) ?? []
    }

    /// the lock file beside the store, locked, or -1 when it can't be had within a
    /// few seconds (the write goes ahead: a lost entry here costs a line in a list)
    private func takeFileLock() -> Int32 {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.deletingPathExtension().appendingPathExtension("lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return -1 }
        let deadline = Date().addingTimeInterval(5)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, Date() < deadline else { close(fd); return -1 }
            usleep(5_000)
        }
        return fd
    }
}

/// Where a check's report goes: a finished one into the health store as the job's
/// latest check, a stopped one only into the list of stopped checks. Every check the
/// app or the agent makes is recorded through here, so a stopped one can't become a
/// job's latest check by any path.
public enum CheckRecording {
    public enum Outcome: Sendable {
        /// recorded as the job's latest check: report it, notify, alert as usual
        case recorded(HealthRecord)
        /// not a check: no record, no alert, and a scheduled check stays due
        case canceled(CanceledCheck)
    }

    public static func record(_ report: HealthReport, job: BackupJob, kind: String, at date: Date,
                              trigger: String = "manual", health: HealthStore,
                              canceled: CanceledCheckStore) -> Outcome {
        if report.canceled {
            let stopped = CanceledCheck.from(job: job, report: report, at: date, kind: kind, trigger: trigger)
            canceled.append(stopped)
            return .canceled(stopped)
        }
        let record = HealthRecord.from(job: job, report: report, at: date, kind: kind, trigger: trigger)
        health.append(record)
        return .recorded(record)
    }
}
