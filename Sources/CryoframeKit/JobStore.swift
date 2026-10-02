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
//  The app and the scheduled agent both write these files: the app when a job is
//  saved, the agent (and the app) when a run records what it found. Each write is a
//  load, a change and a save, and two of them at once lost one change: a job saved
//  while a run recorded its drive came back without the drive, or the run's record
//  undid the edit. Every write goes through `update`, which holds a lock on a file
//  beside jobs.json (flock(2), so it holds across processes) from the load to the
//  save. Readers don't take it: each file is replaced whole, all at once.
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

    /// the file beside jobs.json holding the plain-files jobs (see the top)
    var filesURL: URL {
        url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-files.json")
    }

    /// the file `update` locks (see the top). Never removed: a lock is the inode, and
    /// two processes locking two files of one name would each think it held it.
    var lockURL: URL {
        url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".lock")
    }

    /// how long `update` waits for the other process's write before going ahead: a
    /// write takes milliseconds, so this is a process stopped while holding the lock
    static let lockWait: TimeInterval = 30

    public func load() -> ScheduleState {
        lock.lock(); defer { lock.unlock() }
        return read()
    }

    /// Replace everything with `state`. Only for a state that was loaded and changed
    /// by someone who knows nothing else can be writing (tests, a migration); anything
    /// else changes what it means to through `update`.
    public func save(_ state: ScheduleState) {
        update { $0 = state }
    }

    /// Load, change and save, with no other write in between, in this process or the
    /// other one (see the top). `body` must not call the store: the lock isn't
    /// reentrant. Nothing is written when `body` changes nothing.
    @discardableResult
    public func update<T>(_ body: (inout ScheduleState) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        let fd = takeFileLock()
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        var state = read()
        let before = state
        let result = try body(&state)
        if state != before { write(state) }
        return result
    }

    public func upsert(_ job: BackupJob) {
        update { s in s.jobs.removeAll { $0.id == job.id }; s.jobs.append(job) }
    }
    public func remove(id: String) {
        update { s in s.jobs.removeAll { $0.id == id }; s.lastRun[id] = nil; s.lastCopy[id] = nil; s.adoptionReviews[id] = nil }
    }
    public func recordRun(id: String, at date: Date) {
        update { s in s.lastRun[id] = date }
    }
    /// record that each of `targetIDs` got a complete copy of `jobID`'s libraries
    public func recordCopies(jobID: String, targetIDs: [String], at date: Date) {
        guard !targetIDs.isEmpty else { return }
        update { s in for t in targetIDs { s.lastCopy[jobID, default: [:]][t] = date } }
    }
    /// record the volume a destination set up before 1.6 is on, if none is recorded yet
    public func recordVolume(jobID: String, targetID: String, _ volume: VolumeIdentity) {
        update { s in
            guard let j = s.jobs.firstIndex(where: { $0.id == jobID }),
                  let t = s.jobs[j].targets.firstIndex(where: { $0.id == targetID }), s.jobs[j].targets[t].volume == nil else { return }
            s.jobs[j].targets[t].volume = volume
        }
    }
    /// record another drive a destination takes turns on (see Target.otherVolumes)
    public func recordOtherVolume(jobID: String, targetID: String, _ volume: VolumeIdentity) {
        update { s in
            guard let j = s.jobs.firstIndex(where: { $0.id == jobID }),
                  let t = s.jobs[j].targets.firstIndex(where: { $0.id == targetID }),
                  s.jobs[j].targets[t].volume?.uuid != volume.uuid,
                  !(s.jobs[j].targets[t].otherVolumes ?? []).contains(where: { $0.uuid == volume.uuid }) else { return }
            s.jobs[j].targets[t].otherVolumes = (s.jobs[j].targets[t].otherVolumes ?? []) + [volume]
        }
    }

    // MARK: files

    private func read() -> ScheduleState {
        var state = ScheduleState()
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(ScheduleState.self, from: data) {
            state = decoded
            if let d = try? Data(contentsOf: drivesURL), let drives = try? JSONDecoder().decode(DriveRecords.self, from: d) {
                drives.fill(&state)
            }
        }
        if let data = try? Data(contentsOf: filesURL), let files = try? JSONDecoder().decode(ScheduleState.self, from: data) {
            state.merge(plainFiles: files)
        }
        return state
    }

    private func write(_ state: ScheduleState) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let (main, files) = state.splittingPlainFiles()
        // the sidecar first, then what 1.6.0 reads (see the top). Without a plain-files
        // job and without a file to empty, none is written.
        if !files.jobs.isEmpty || FileManager.default.fileExists(atPath: filesURL.path),
           let data = try? encoder.encode(files) { try? data.write(to: filesURL, options: .atomic) }
        if let data = try? encoder.encode(DriveRecords(main)) { try? data.write(to: drivesURL, options: .atomic) }
        if let data = try? encoder.encode(main) { try? data.write(to: url, options: .atomic) }
    }

    /// the lock file, locked, or -1 when it can't be opened or the wait ran out (the
    /// write goes ahead: losing a write to a stuck process is worse than the race)
    private func takeFileLock() -> Int32 {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return -1 }
        let deadline = Date().addingTimeInterval(Self.lockWait)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, Date() < deadline else { close(fd); return -1 }
            usleep(5_000)
        }
        return fd
    }
}

extension ScheduleState {
    /// `self` without its plain-files jobs (what jobs.json holds), and those jobs with
    /// what is recorded of them (what jobs-files.json holds; see JobStore)
    func splittingPlainFiles() -> (main: ScheduleState, files: ScheduleState) {
        let plain = Set(jobs.filter { $0.format.isPlainFiles }.map(\.id))
        var main = self, files = ScheduleState()
        main.jobs = jobs.filter { !plain.contains($0.id) }
        files.jobs = jobs.filter { plain.contains($0.id) }
        main.lastRun = lastRun.filter { !plain.contains($0.key) }
        files.lastRun = lastRun.filter { plain.contains($0.key) }
        main.lastCopy = lastCopy.filter { !plain.contains($0.key) }
        files.lastCopy = lastCopy.filter { plain.contains($0.key) }
        main.adoptionReviews = adoptionReviews.filter { !plain.contains($0.key) }
        files.adoptionReviews = adoptionReviews.filter { plain.contains($0.key) }
        main.droppedJobs = 0; files.droppedJobs = 0
        return (main, files)
    }

    /// the jobs of jobs-files.json added to those of jobs.json, with what is recorded
    /// of them; a job in both is taken from `files` (see JobStore)
    mutating func merge(plainFiles files: ScheduleState) {
        let ids = Set(files.jobs.map(\.id))
        jobs.removeAll { ids.contains($0.id) }
        jobs.append(contentsOf: files.jobs)
        for id in ids {
            lastRun[id] = files.lastRun[id]
            lastCopy[id] = files.lastCopy[id]
            adoptionReviews[id] = files.adoptionReviews[id]
        }
        droppedJobs += files.droppedJobs
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
