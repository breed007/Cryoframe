//
//  RunHistory.swift
//  CryoframeKit
//
//  A durable record of every run — manual or scheduled — so the result of a
//  backup survives quitting the app and a scheduled run isn't a black hole. The
//  GUI and the agent both append here; the GUI reads it for the last-run badge,
//  the activity log, and the History view.
//

import Foundation

public enum RunOutcomeKind: String, Codable, Sendable {
    case verified, completed, partial, deferred, failed, cancelled
}

public struct RunSummary: Sendable, Equatable {
    public let kind: RunOutcomeKind
    public let text: String
    public init(kind: RunOutcomeKind, text: String) { self.kind = kind; self.text = text }
}

/// roll a set of per-copy results up into one outcome + human summary. A "copy" is
/// one library written to one destination. Shared by the live badge and the persisted
/// record so they always agree. Single-destination wording is unchanged; only a mix
/// of success and failure produces the new `.partial` kind.
public func summarizeRun(_ results: [LibraryRunResult]) -> RunSummary {
    var done = 0, verified = 0, failed = 0, notFound = 0
    var dests = Set<String>(), libs = Set<String>()
    for r in results {
        switch r {
        case .completed(let lib, let dest, _, _, let v):
            libs.insert(lib); dests.insert(dest)
            if v == false { failed += 1 } else { done += 1; if v == true { verified += 1 } }
        case .notFound(let lib): libs.insert(lib); notFound += 1
        case .failed(let lib, let dest, _): libs.insert(lib); dests.insert(dest); failed += 1
        }
    }
    let total = results.count
    let multiDest = dests.count > 1
    func plural(_ n: Int) -> String { n == 1 ? "library" : "libraries" }
    func unit(_ n: Int) -> String { multiDest ? (n == 1 ? "copy" : "copies") : plural(n) }

    if (failed > 0 || notFound > 0) {
        if done > 0 {
            // some copies landed, some didn't — a degraded backup, not a dead one.
            var parts = ["\(done)/\(total) \(unit(total)) archived"]
            if notFound > 0 { parts.append("\(notFound) not found") }
            if failed > 0 { parts.append("\(failed) failed") }
            return RunSummary(kind: .partial, text: parts.joined(separator: ", "))
        }
        var parts = ["0/\(total) \(unit(total)) archived"]
        if notFound > 0 { parts.append("\(notFound) not found") }
        if failed > 0 { parts.append("\(failed) failed") }
        return RunSummary(kind: .failed, text: parts.joined(separator: ", "))
    }
    let suffix = multiDest ? " → \(dests.count) destinations" : ""
    if total > 0, verified == total { return RunSummary(kind: .verified, text: "\(libs.count) \(plural(libs.count)) verified\(suffix)") }
    return RunSummary(kind: .completed, text: "\(libs.count) \(plural(libs.count)) archived\(suffix)")
}

public struct LibraryOutcome: Codable, Sendable, Equatable, Identifiable {
    public var id: String { destination.isEmpty ? library : "\(library)→\(destination)" }
    public var library: String
    public var destination: String     // "" for a not-found library (no destination reached)
    public var status: String          // verified | archived | verify failed | not found | failed
    public var parts: Int
    public var bytes: UInt64
    public var error: String?

    public init(from r: LibraryRunResult) {
        destination = ""
        switch r {
        case .completed(let lib, let dest, let parts, let bytes, let v):
            library = lib; destination = dest; self.parts = parts; self.bytes = bytes
            switch v {
            case true:  status = "verified";      error = nil
            case false: status = "verify failed"; error = "verification did not pass"
            case nil:   status = "archived";      error = nil
            }
        case .notFound(let lib):
            library = lib; parts = 0; bytes = 0; status = "not found"; error = nil
        case .failed(let lib, let dest, let e):
            library = lib; destination = dest; parts = 0; bytes = 0; status = "failed"; error = e
        }
    }

    enum CodingKeys: String, CodingKey { case library, destination, status, parts, bytes, error }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        library = try c.decode(String.self, forKey: .library)
        destination = try c.decodeIfPresent(String.self, forKey: .destination) ?? ""   // pre-1.1 records
        status = try c.decode(String.self, forKey: .status)
        parts = try c.decode(Int.self, forKey: .parts)
        bytes = try c.decode(UInt64.self, forKey: .bytes)
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
}

public struct RunRecord: Codable, Sendable, Identifiable {
    public var id: String
    public var jobID: String
    public var jobName: String
    public var startedAt: Date
    public var finishedAt: Date
    public var trigger: String          // "manual" | "scheduled"
    public var outcome: RunOutcomeKind
    public var summary: String
    public var libraries: [LibraryOutcome]
    public var bytes: UInt64
    public var warning: String?

    public var duration: TimeInterval { max(0, finishedAt.timeIntervalSince(startedAt)) }

    public init(id: String, jobID: String, jobName: String, startedAt: Date, finishedAt: Date,
                trigger: String, outcome: RunOutcomeKind, summary: String,
                libraries: [LibraryOutcome], bytes: UInt64, warning: String?) {
        self.id = id; self.jobID = jobID; self.jobName = jobName
        self.startedAt = startedAt; self.finishedAt = finishedAt; self.trigger = trigger
        self.outcome = outcome; self.summary = summary
        self.libraries = libraries; self.bytes = bytes; self.warning = warning
    }

    /// build from a completed run.
    public static func make(job: BackupJob, outcome: JobOutcome, startedAt: Date, finishedAt: Date,
                            trigger: String, id: String = UUID().uuidString) -> RunRecord {
        switch outcome {
        case .deferred(let reason):
            return RunRecord(id: id, jobID: job.id, jobName: job.name, startedAt: startedAt, finishedAt: finishedAt,
                             trigger: trigger, outcome: .deferred, summary: reason, libraries: [], bytes: 0, warning: nil)
        case .cancelled:
            return RunRecord(id: id, jobID: job.id, jobName: job.name, startedAt: startedAt, finishedAt: finishedAt,
                             trigger: trigger, outcome: .cancelled, summary: "stopped", libraries: [], bytes: 0, warning: nil)
        case .finished(let results, let warning):
            let s = summarizeRun(results)
            let libs = results.map(LibraryOutcome.init(from:))
            return RunRecord(id: id, jobID: job.id, jobName: job.name, startedAt: startedAt, finishedAt: finishedAt,
                             trigger: trigger, outcome: s.kind, summary: s.text, libraries: libs,
                             bytes: libs.reduce(0) { $0 + $1.bytes }, warning: warning)
        }
    }

    /// build for a run that threw before producing an outcome.
    public static func failure(job: BackupJob, error: String, startedAt: Date, finishedAt: Date,
                               trigger: String, id: String = UUID().uuidString) -> RunRecord {
        RunRecord(id: id, jobID: job.id, jobName: job.name, startedAt: startedAt, finishedAt: finishedAt,
                  trigger: trigger, outcome: .failed, summary: error, libraries: [], bytes: 0, warning: nil)
    }
}

public final class RunHistoryStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private let cap: Int

    public init(url: URL, cap: Int = 200) { self.url = url; self.cap = cap }

    public static func standard() -> RunHistoryStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.cryoframe", isDirectory: true)
        return RunHistoryStore(url: base.appendingPathComponent("run-history.json"))
    }

    /// newest first.
    public func all() -> [RunRecord] {
        lock.lock(); defer { lock.unlock() }
        return decode()
    }

    public func append(_ record: RunRecord) {
        lock.lock(); defer { lock.unlock() }
        var list = decode()
        list.insert(record, at: 0)
        if list.count > cap { list = Array(list.prefix(cap)) }
        write(list)
    }

    public func latest(forJob jobID: String) -> RunRecord? { all().first { $0.jobID == jobID } }

    private func decode() -> [RunRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([RunRecord].self, from: data)) ?? []
    }
    private func write(_ list: [RunRecord]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(list) { try? data.write(to: url, options: .atomic) }
    }
}
