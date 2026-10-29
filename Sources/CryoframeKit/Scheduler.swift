//
//  Scheduler.swift
//  CryoframeKit
//
//  Computes which jobs are due. A job is due when its next fire after its
//  reference point (last run, or creation if never run) has arrived. Pure +
//  date-injected, so it's fully testable.
//

import Foundation

public struct ScheduleState: Codable, Sendable, Equatable {
    public var jobs: [BackupJob]
    public var lastRun: [String: Date]
    /// job id → destination (target) id → when it last got a complete copy of every
    /// library; how long a rotating drive has been away (see RotationRules)
    public var lastCopy: [String: [String: Date]] = [:]
    /// job id → adopted versions its runs left alone until the person says yes (see
    /// AdoptionReview)
    public var adoptionReviews: [String: [AdoptionReview]] = [:]
    /// the jobs that failed to decode (most likely written by a newer version), as they
    /// were on disk. They are written back unchanged: dropping them erased them at the
    /// next write, which the agent makes within the hour of a return to this version.
    var undecodedJobs: [JSONValue] = []
    /// the same, from jobs-files.json, and written back there (see JobStore)
    var undecodedPlainFilesJobs: [JSONValue] = []
    /// number of jobs that failed to decode and were skipped on the last load — so the
    /// UI can tell the user "3 jobs couldn't be read" instead of silently showing none.
    public var droppedJobs: Int { undecodedJobs.count + undecodedPlainFilesJobs.count }
    /// the job files that are there but couldn't be read at all (see JobStore): nothing
    /// is written to either file, and no job is due, until they can be. Never saved.
    public var unreadableFiles: [String] = []

    public init(jobs: [BackupJob] = [], lastRun: [String: Date] = [:]) {
        self.jobs = jobs; self.lastRun = lastRun
    }

    enum CodingKeys: String, CodingKey { case jobs, lastRun, lastCopy, adoptionReviews }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // decode jobs through a wrapper so ONE malformed or schema-incompatible job
        // can't wipe the whole list (the old whole-array decode did exactly that). A bad
        // element is kept as it was, to be written back. A "jobs" that isn't a list is
        // a file this version can't read, and throws.
        let wrapped = try c.decodeIfPresent([Failable<BackupJob>].self, forKey: .jobs) ?? []
        self.jobs = wrapped.compactMap(\.value)
        self.undecodedJobs = wrapped.compactMap(\.raw)
        self.lastRun = (try? c.decode([String: Date].self, forKey: .lastRun)) ?? [:]
        self.lastCopy = (try? c.decode([String: [String: Date]].self, forKey: .lastCopy)) ?? [:]   // before 1.6: none
        self.adoptionReviews = (try? c.decode([String: [AdoptionReview]].self, forKey: .adoptionReviews)) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        var list = c.nestedUnkeyedContainer(forKey: .jobs)
        for job in jobs { try list.encode(job) }
        for raw in undecodedJobs { try list.encode(raw) }
        try c.encode(lastRun, forKey: .lastRun)
        if !lastCopy.isEmpty { try c.encode(lastCopy, forKey: .lastCopy) }
        if !adoptionReviews.isEmpty { try c.encode(adoptionReviews, forKey: .adoptionReviews) }
    }
}

/// wraps a Decodable so a single bad element decodes to nil, kept as the JSON it was,
/// instead of throwing and taking the whole array down with it.
private struct Failable<T: Decodable>: Decodable {
    let value: T?
    let raw: JSONValue?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
        raw = value == nil ? try JSONValue(from: decoder) : nil
    }
}

/// Any JSON value, decoded and encoded back as it was (key order and number spelling
/// aside), for what this version can't read but mustn't lose.
enum JSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), int(Int64), double(Double), string(String)
    case array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int64.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

public struct Scheduler: Sendable {
    public init() {}

    public func isDue(_ job: BackupJob, lastRun: Date?, now: Date, calendar: Calendar = .current) -> Bool {
        let reference = lastRun ?? job.createdAt
        guard let next = job.frequency.nextFireDate(after: reference, calendar: calendar) else { return false }
        return next <= now
    }

    /// none while a job file can't be read: no run could be recorded, so every pass
    /// would start the same jobs again
    public func dueJobs(_ state: ScheduleState, now: Date, calendar: Calendar = .current) -> [BackupJob] {
        guard state.unreadableFiles.isEmpty else { return [] }
        return state.jobs.filter { $0.enabled && isDue($0, lastRun: state.lastRun[$0.id], now: now, calendar: calendar) }
    }

    /// How long until the soonest enabled job that isn't due yet comes due, when that
    /// is no more than `window` away; nil otherwise. A wake set for a scheduled run
    /// starts the agent a couple of minutes before the job's time, and the Mac may be
    /// asleep again by the next pass, so that pass waits for it.
    public func waitForNextDue(_ state: ScheduleState, now: Date, within window: TimeInterval,
                               calendar: Calendar = .current) -> TimeInterval? {
        guard state.unreadableFiles.isEmpty else { return nil }
        let soonest = state.jobs.filter(\.enabled)
            .compactMap { $0.frequency.nextFireDate(after: state.lastRun[$0.id] ?? $0.createdAt, calendar: calendar) }
            .filter { $0 > now }
            .min()
        guard let soonest, soonest.timeIntervalSince(now) <= window else { return nil }
        return soonest.timeIntervalSince(now)
    }

    /// the jobs a scheduled pass starts: due, and not already running here or in the
    /// app (that run records the result and moves the schedule on). Nor a job whose
    /// interrupted transfer the user stopped earlier in this pass: the new run would
    /// clear that Stop and back the whole job up again, straight after being told not to.
    public func jobsToStart(_ state: ScheduleState, now: Date, running: Set<String>,
                            stoppedThisPass: Set<String>, calendar: Calendar = .current) -> [BackupJob] {
        dueJobs(state, now: now, calendar: calendar)
            .filter { !running.contains($0.id) && !stoppedThisPass.contains($0.id) }
    }
}
