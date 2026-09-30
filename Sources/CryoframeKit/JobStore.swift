//
//  JobStore.swift
//  CryoframeKit
//
//  Persists scheduled jobs + last-run times as JSON. Shared by the GUI (edits
//  jobs) and the scheduled agent (reads jobs, records runs).
//
//  What 1.6 knows about drives is also kept in a file of its own beside jobs.json
//  (jobs-drives.json): each destination's drive, the drives it takes turns on and
//  its rotation, each folder's drive, and each destination's last copy. 1.5.6
//  re-saves jobs.json with its own types every time it records a run, and drops
//  all of these; one scheduled run after a return to 1.5.6 turned a rotation back
//  into destinations that each had to be connected. 1.5.6 never touches the other
//  file, so on loading, whatever jobs.json is missing of these is put back from
//  it, for a destination or folder still at the path it was recorded for. It is
//  written first: a crash between the two writes leaves jobs.json as it was, and
//  what it holds wins over the other file.
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

    /// the file beside jobs.json holding what 1.6 knows about drives (see the top)
    var drivesURL: URL {
        url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-drives.json")
    }

    public func load() -> ScheduleState {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url),
              var state = try? JSONDecoder().decode(ScheduleState.self, from: data) else {
            return ScheduleState()
        }
        if let d = try? Data(contentsOf: drivesURL), let drives = try? JSONDecoder().decode(DriveRecords.self, from: d) {
            drives.fill(&state)
        }
        return state
    }

    public func save(_ state: ScheduleState) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(DriveRecords(state)) { try? data.write(to: drivesURL, options: .atomic) }
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
    /// record another drive a destination takes turns on (see Target.otherVolumes)
    public func recordOtherVolume(jobID: String, targetID: String, _ volume: VolumeIdentity) {
        var s = load()
        guard let j = s.jobs.firstIndex(where: { $0.id == jobID }),
              let t = s.jobs[j].targets.firstIndex(where: { $0.id == targetID }),
              !(s.jobs[j].targets[t].otherVolumes ?? []).contains(where: { $0.uuid == volume.uuid }) else { return }
        s.jobs[j].targets[t].otherVolumes = (s.jobs[j].targets[t].otherVolumes ?? []) + [volume]
        save(s)
    }
}

/// What 1.6 knows about the drives of every job, kept apart from jobs.json (see
/// JobStore).
struct DriveRecords: Codable, Equatable {
    struct TargetDrives: Codable, Equatable {
        /// the folder these were recorded for
        var dir: String
        var volume: VolumeIdentity?
        var otherVolumes: [VolumeIdentity]?
        var rotation: Rotation?
    }
    struct LibraryDrive: Codable, Equatable {
        var paths: [LibraryPath]
        var volume: VolumeIdentity
    }
    struct JobDrives: Codable, Equatable {
        var targets: [String: TargetDrives] = [:]
        var libraries: [String: LibraryDrive] = [:]
    }
    var jobs: [String: JobDrives] = [:]
    var lastCopy: [String: [String: Date]] = [:]

    init(_ state: ScheduleState) {
        for job in state.jobs {
            var j = JobDrives()
            for t in job.targets where t.volume != nil || t.otherVolumes != nil || t.rotation != nil {
                j.targets[t.id] = TargetDrives(dir: t.destinationDir.path, volume: t.volume, otherVolumes: t.otherVolumes, rotation: t.rotation)
            }
            for lib in job.libraries { if let v = lib.volume { j.libraries[lib.id] = LibraryDrive(paths: lib.paths, volume: v) } }
            if !j.targets.isEmpty || !j.libraries.isEmpty { jobs[job.id] = j }
        }
        lastCopy = state.lastCopy
    }

    /// put into `state` what it's missing of these, for a destination or folder still
    /// at the path they were recorded for
    func fill(_ state: inout ScheduleState) {
        for i in state.jobs.indices {
            guard let j = jobs[state.jobs[i].id] else { continue }
            for k in state.jobs[i].targets.indices {
                let t = state.jobs[i].targets[k]
                guard let r = j.targets[t.id], r.dir == t.destinationDir.path else { continue }
                if t.volume == nil { state.jobs[i].targets[k].volume = r.volume }
                if t.otherVolumes == nil { state.jobs[i].targets[k].otherVolumes = r.otherVolumes }
                if t.rotation == nil { state.jobs[i].targets[k].rotation = r.rotation }
            }
            for k in state.jobs[i].libraries.indices {
                let lib = state.jobs[i].libraries[k]
                guard lib.volume == nil, let r = j.libraries[lib.id], r.paths == lib.paths else { continue }
                state.jobs[i].libraries[k].volume = r.volume
            }
        }
        let known = Set(state.jobs.map(\.id))
        for (job, copies) in lastCopy where known.contains(job) {
            for (target, date) in copies where (state.lastCopy[job]?[target]).map({ $0 < date }) ?? true {
                state.lastCopy[job, default: [:]][target] = date
            }
        }
    }
}
