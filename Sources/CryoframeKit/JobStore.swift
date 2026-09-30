//
//  JobStore.swift
//  CryoframeKit
//
//  Persists scheduled jobs + last-run times as JSON. Shared by the GUI (edits
//  jobs) and the scheduled agent (reads jobs, records runs).
//

import Foundation

public final class JobStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    public init(url: URL) { self.url = url }

    /// default location under Application Support.
    public static func standard() -> JobStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.cryoframe", isDirectory: true)
        return JobStore(url: base.appendingPathComponent("jobs.json"))
    }

    public func load() -> ScheduleState {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(ScheduleState.self, from: data) else {
            return ScheduleState()
        }
        return state
    }

    public func save(_ state: ScheduleState) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(state) { try? data.write(to: url, options: .atomic) }
    }

    public func upsert(_ job: BackupJob) {
        var s = load(); s.jobs.removeAll { $0.id == job.id }; s.jobs.append(job); save(s)
    }
    public func remove(id: String) {
        var s = load(); s.jobs.removeAll { $0.id == id }; s.lastRun[id] = nil; save(s)
    }
    public func recordRun(id: String, at date: Date) {
        var s = load(); s.lastRun[id] = date; save(s)
    }
    /// record that each of `targetIDs` got a complete copy of `jobID`'s libraries
    public func recordCopies(jobID: String, targetIDs: [String], at date: Date) {
        guard !targetIDs.isEmpty else { return }
        var s = load()
        for t in targetIDs { s.lastCopy[jobID, default: [:]][t] = date }
        save(s)
    }
    /// record the volume a destination set up before 1.6 is on, if none is recorded yet
    public func recordVolume(jobID: String, targetID: String, _ volume: VolumeIdentity) {
        var s = load()
        guard let j = s.jobs.firstIndex(where: { $0.id == jobID }),
              let t = s.jobs[j].targets.firstIndex(where: { $0.id == targetID }), s.jobs[j].targets[t].volume == nil else { return }
        s.jobs[j].targets[t].volume = volume
        save(s)
    }
}
