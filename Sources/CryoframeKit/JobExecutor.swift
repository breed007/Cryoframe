//
//  JobExecutor.swift
//  CryoframeKit
//
//  Runs a whole job: one APFS snapshot, then each selected library archived to
//  its own subfolder at the target — directly, or staged-and-shipped in resumable
//  parts for fragile targets. All libraries come from the same snapshot, so they
//  are a consistent point-in-time set. Honors the run policy and cancellation.
//

import Foundation
import CryoframeShared

public enum LibraryRunResult: Sendable, Equatable {
    // a "copy" is one library written to one destination. notFound is a source-side
    // problem, so it has no destination (it fails for all of them at once).
    case completed(library: String, destination: String, parts: Int, bytes: UInt64, verified: Bool?)
    case notFound(library: String)
    case failed(library: String, destination: String, error: String)
}

public enum JobOutcome: Sendable {
    case deferred(String)
    case cancelled
    case finished(results: [LibraryRunResult], warning: String?)
}

public struct JobExecutor: Sendable {
    let helper: PrivilegedHelper
    let detector: ProcessDetector
    let probe: TargetProbe
    let locator: ContentLocator
    let scratchBase: URL
    let chunkSize: UInt64
    let pendingStore: PendingTransferStore?
    let jobStore: JobStore?
    let dataVolume: VolumeRef
    /// the mounted volumes, to find each destination and folder where it is now
    let volumes: VolumeTable
    /// the archive checks recorded so far, newest first: retention keeps the version
    /// last known to restore (see KnownGood)
    let healthRecords: @Sendable () -> [HealthRecord]
    /// the runs recorded so far: what a drive holding this job's 1.5 backups is told by
    /// (see LibraryFolders.holdsBackups)
    let runHistory: @Sendable () -> [RunRecord]

    public init(helper: PrivilegedHelper,
                detector: ProcessDetector,
                probe: TargetProbe = FileSystemTargetProbe(),
                locator: ContentLocator = ContentLocator(),
                scratchBase: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("app.cryoframe/scratch", isDirectory: true),
                chunkSize: UInt64 = 2 * 1_000_000_000,
                pendingStore: PendingTransferStore? = nil,
                jobStore: JobStore? = nil,
                dataVolume: VolumeRef = VolumeRef(mountPoint: "/System/Volumes/Data", bsdDevice: ""),
                passphraseProvider: @escaping @Sendable (String) -> String? = { _ in nil },
                healthRecords: @escaping @Sendable () -> [HealthRecord] = { [] },
                runHistory: @escaping @Sendable () -> [RunRecord] = { [] },
                volumes: VolumeTable = SystemVolumeTable()) {
        self.helper = helper; self.detector = detector; self.probe = probe; self.locator = locator
        self.volumes = volumes
        self.scratchBase = scratchBase; self.chunkSize = chunkSize
        self.pendingStore = pendingStore; self.jobStore = jobStore; self.dataVolume = dataVolume
        self.passphraseProvider = passphraseProvider; self.healthRecords = healthRecords; self.runHistory = runHistory
    }

    /// resolves the AES-256 passphrase for an encrypted job (jobID → passphrase),
    /// e.g. from the Keychain. Returns nil for plaintext jobs.
    let passphraseProvider: @Sendable (String) -> String?

    // a sealed archive built once (in scratch), to be distributed to every destination
    // without recompressing. Live mirrors don't use this — they rsync per destination.
    private struct SealedBuild: Sendable {
        let library: ContentType
        let jobID: String
        let index: Int
        let builtFile: URL          // the unsplit artifact in scratch
        let format: ArchiveFormat
        let byteSize: UInt64
        let contentDigest: String   // sha256 of the built artifact, to confirm copies match
        let verified: Bool?
        let encrypted: Bool
        let buildDir: URL           // scratch dir to clean once distribution is done
        let dests: [Target]         // the available destinations to copy/ship it to
    }

    /// where one library lives, and how to reach it once its disk is frozen.
    struct LibraryPlacement: Sendable {
        let library: ContentType
        let liveRoot: URL?
        let volume: SourceVolume?

        /// the library's root inside the snapshot of its own volume. A volume that
        /// couldn't be frozen falls back to reading the files live — safe only because
        /// the run refuses to start while that library's app is open.
        func root(in mounts: [String: String]) -> URL? {
            guard let live = liveRoot, let volume else { return nil }
            guard let snapshotMount = mounts[volume.mountPoint] else {
                return FileManager.default.fileExists(atPath: live.path) ? live : nil
            }
            guard let frozen = volume.frozenPath(live: live.path, snapshotMount: snapshotMount) else { return nil }
            let url = URL(fileURLWithPath: frozen)
            return FileManager.default.fileExists(atPath: frozen) ? url : nil
        }
    }

    /// Freeze every volume the job touches, then run `body` once with them all held —
    /// so a job spanning two disks still reads a single moment in time. Each snapshot
    /// is torn down as its scope unwinds, exactly as the single-volume path always did.
    private static func withFrozenVolumes(_ volumes: [SourceVolume],
                                          coordinator: SnapshotCoordinator,
                                          ownerUID: uid_t,
                                          mounts: [String: String] = [:],
                                          _ body: @escaping @Sendable ([String: String]) async throws -> SnapshotPass
    ) async throws -> SnapshotPass {
        guard let volume = volumes.first else { return try await body(mounts) }
        let rest = Array(volumes.dropFirst())
        let ref = VolumeRef(mountPoint: volume.mountPoint, bsdDevice: "")
        return try await coordinator.withFrozenSnapshot(of: ref, ownerUID: ownerUID) { mount in
            var next = mounts
            next[volume.mountPoint] = mount.mountPoint
            return try await withFrozenVolumes(rest, coordinator: coordinator, ownerUID: ownerUID,
                                               mounts: next, body)
        }
    }

    private struct SnapshotPass: Sendable {
        var results: [LibraryRunResult]
        var builds: [SealedBuild]
        var cancelled: Bool
        /// said in the run's warning: what a live mirror left out
        var notes: [String] = []
    }

    public func run(_ saved: BackupJob, ownerUID: uid_t, now: Date,
                    control: RunControl = RunControl(),
                    onStage: @escaping @Sendable (BackupStage) -> Void = { _ in },
                    onLibrary: @escaping @Sendable (String) -> Void = { _ in },
                    onProgress: @escaping @Sendable (RunProgress) -> Void = { _ in }) async throws -> JobOutcome {
        // Each destination where it is now, found by its volume: a renamed or
        // remounted drive is still itself, and another drive of the same name is
        // never written to (see DestinationResolver). A folder on a renamed drive is
        // found the same way (see ContentType.located).
        let resolved = DestinationResolver(volumes: self.volumes).resolve(saved)
        var presence = resolved.presence
        // A destination whose drive a run learned (set up before 1.6) meets another drive
        // of that name at its path. 1.5 knew a destination by its path alone, and the
        // only way to take turns between two drives was two drives of one name, as the
        // README suggests for an off-site copy; after the first 1.6 run recorded one of
        // them, the other was "a different drive" every week it was the one at home.
        // One that holds backups only this job can have made is the other drive of the
        // pair: it is recorded, and used. Anything else is refused as a different drive
        // and left untouched, a neighbor's drive of the same name above all.
        var turns: [(targetID: String, volume: VolumeIdentity)] = []
        let runs = saved.targets.contains { if case .otherDrive = presence[$0.id] { return true }; return false } ? runHistory() : []
        for t in saved.targets {
            guard case .otherDrive = presence[t.id], let id = t.volume, id.learnedAt != nil, !id.isShare,
                  let here = self.volumes.volume(containing: t.destinationDir), let uuid = here.uuid, uuid != id.uuid,
                  LibraryNames.same(here.name, id.name), LibraryFolders.holdsBackups(of: saved, in: t.destinationDir, runs: runs),
                  var other = DestinationResolver(volumes: self.volumes).identity(for: t.destinationDir) else { continue }
            other.learnedAt = now
            turns.append((t.id, other))
            presence[t.id] = .present(t.destinationDir)
        }
        for turn in turns { jobStore?.recordOtherVolume(jobID: saved.id, targetID: turn.targetID, turn.volume) }
        // a folder whose drive is another drive of its drive's name, or isn't here: not
        // backed up, and said why (by library id)
        var refused: [String: String] = [:], away = Set<String>()
        let labels = saved.destinationLabels
        let job: BackupJob = {
            var j = resolved.job
            // two destinations of one name are told apart in everything the run says,
            // and in which of them got a copy (see destinationLabels)
            j.targets = j.targets.map { t in labels[t.id].map { $0 == t.displayName ? t : t.named($0) } ?? t }
            j.libraries = j.libraries.map { lib in
                switch lib.whereabouts(volumes: self.volumes, home: locator.home) {
                case .here(let found): return found
                case .otherDrive(let why): refused[lib.id] = why; return lib
                case .away: away.insert(lib.id); return lib
                }
            }
            return j
        }()
        let refusedSources = refused, awaySources = away
        let decision = decide(job.runPolicy, libraries: job.libraries, detector: detector)
        if case .deferred(let reason) = decision { return .deferred(reason) }

        func availability(_ t: Target) -> TargetAvailability {
            if t.volume != nil, let p = presence[t.id], !p.isPresent {
                switch p {
                case .away(let why), .otherDrive(let why): return TargetAvailability(reachable: false, writable: false, reason: why)
                case .present: break
                }
            }
            return probe.availability(of: t)
        }

        // The primary place must be reachable: a run that can't write its first copy
        // is a real failure. Secondaries that are down degrade to partial success. A
        // rotation of drives is one place (see Rotation): the run writes to whichever
        // of them is connected, and one that's away is taking its turn off-site, not
        // failing, so it isn't reported at all. Only when none of them is connected is
        // the rotation down.
        var placed: [(target: Target, available: Bool, reason: String?)] = []
        for (i, place) in job.places.enumerated() {
            let checked = place.map { ($0, availability($0)) }
            if place[0].rotation == nil {
                let (t, a) = checked[0]
                if i == 0, !a.ok { throw TargetError.unavailable(a.reason ?? "\(t.displayName) is unavailable") }
                placed.append((t, a.ok, a.reason)); continue
            }
            guard checked.contains(where: { $0.1.ok }) else {
                // a drive of the rotation's that is connected but isn't the one it was
                // set up with (erased, say): say that, not that nothing is connected
                let other = place.compactMap { t -> String? in if case .otherDrive(let why)? = presence[t.id] { return why }; return nil }
                let why = other.isEmpty ? "none of \(RotationRules.name(of: place)) is connected"
                    : "none of \(RotationRules.name(of: place)) can be used: " + other.joined(separator: "; ")
                if i == 0 { throw TargetError.unavailable(why) }
                placed.append((place[0], false, why)); continue
            }
            for (t, a) in checked where a.ok || a.reachable {        // connected but not writable: a fault
                placed.append((t, a.ok, a.reason))
            }
        }
        let dests = placed
        // A destination set up before 1.6 has no volume on record. The first run that
        // writes to it records it, if the folder is known to be this job's (it already
        // holds one of its libraries' folders) or the job has never run: a drive of the
        // same name plugged in instead would otherwise be recorded as the destination.
        let neverRan = jobStore.map { $0.load().lastRun[job.id] == nil } ?? false
        let knownPlaces = Set(dests.filter { d in
            d.available && d.target.volume == nil
                && (neverRan || job.libraries.contains { !LibraryFolders.folders(job: job, library: $0, in: d.target.destinationDir).isEmpty })
        }.map(\.target.id))

        let runner = ProcessCommandRunner(control: control)
        let sealed = Self.sealedKind(job.format)
        let count = job.libraries.count
        let passphrase = job.encrypted ? passphraseProvider(job.id) : nil
        if job.encrypted, passphrase?.isEmpty ?? true { throw ArchiveError.passphraseUnavailable }

        // Each library's folder at each destination it can reach, found by identity:
        // taken over from 1.5 or made new (see LibraryFolders), before anything is
        // frozen. A folder that can't be got ready fails that one copy.
        let (folderOf, folderFailures, folderNotes) = Self.prepareFolders(job, at: dests.filter(\.available).map(\.target),
                                                                          jobs: (jobStore?.load().jobs ?? []).map { DestinationResolver(volumes: self.volumes).resolve($0).job })

        onStage(.preparing)

        // Where does each library actually live? A media library big enough to be
        // worth backing up is often on an external SSD, and freezing the boot disk
        // tells you nothing about it. Ask the kernel per library, then freeze every
        // distinct volume involved — all of them at once, so a job spanning two disks
        // still captures a single moment.
        let placements = job.libraries.map { lib -> LibraryPlacement in
            if refusedSources[lib.id] != nil || awaySources.contains(lib.id) { return LibraryPlacement(library: lib, liveRoot: nil, volume: nil) }
            let live = self.locator.liveRoots(of: lib).first
            return LibraryPlacement(library: lib, liveRoot: live,
                                    volume: live.flatMap { VolumeInspector.volume(for: $0) })
        }
        var volumes: [SourceVolume] = []
        for p in placements {
            guard let v = p.volume, v.canSnapshot, !volumes.contains(where: { $0.mountPoint == v.mountPoint })
            else { continue }
            volumes.append(v)
        }
        // A volume we can't snapshot (an exFAT or HFS+ media drive) has to be read
        // live, which is only safe with the owning app closed — enforced below.
        let unfreezable = placements.filter { $0.volume.map { !$0.canSnapshot } ?? false }
        if let blocked = unfreezable.first(where: { $0.library.owningProcess.map { self.detector.isRunning($0) } ?? false }) {
            let app = blocked.library.owningProcess?.displayName ?? "its app"
            let fs = blocked.volume?.fsType.uppercased() ?? "this drive's format"
            throw TargetError.unavailable(
                "\(blocked.library.displayName) is on a \(fs) volume, which can't be frozen. Quit \(app) so it can be copied safely, then run again.")
        }

        let coordinator = SnapshotCoordinator(helper: helper)
        let pass = try await Self.withFrozenVolumes(volumes, coordinator: coordinator, ownerUID: ownerUID) { mounts -> SnapshotPass in
            var results: [LibraryRunResult] = []
            var builds: [SealedBuild] = []
            var cancelled = false
            var notes: [String] = []
            libraryLoop: for (offset, library) in job.libraries.enumerated() {
                let idx = offset + 1
                if control.isCancelled { cancelled = true; break }
                onLibrary(library.displayName)
                if let why = refusedSources[library.id] {
                    for d in dests { results.append(.failed(library: library.displayName, destination: d.target.displayName, error: why)) }
                    continue
                }
                guard let placement = placements.first(where: { $0.library.id == library.id }),
                      let root = placement.root(in: mounts) else {
                    results.append(.notFound(library: library.displayName)); continue   // source problem: all destinations
                }
                let stats = Self.directoryStats(root, forDMG: sealed == .dmg, forZip: sealed == .zip, forMirror: sealed == nil)
                let sourceSize = stats.bytes
                let source = ArchiveSource(name: root.lastPathComponent, root: root, sizeHint: sourceSize)

                // An empty source seals into an archive that reports success and then
                // cannot be restored: RestoreEngine finds nothing to rebuild the bundle
                // from and throws libraryNotFound, while the checksum check passes the
                // artifact forever. A backup of nothing is not a backup, so say so now
                // rather than at the restore.
                //
                // Only when the walk could actually see the tree. A root the app may not
                // read also yields no files, and calling that "empty" sends someone
                // checking their folder when they should be checking permissions — the
                // archive tool reports that case correctly on its own, so let it.
                if stats.readable, stats.entries == 0 {
                    // one failure per destination we would have written to, the same way
                    // an unavailable destination is reported — a "" destination lands in
                    // the run summary's destination set and turns "libraries" into "copies"
                    for d in dests {
                        results.append(.failed(library: library.displayName, destination: d.target.displayName,
                                               error: "\(library.displayName) is empty — there is nothing to back up"))
                    }
                    continue
                }
                // hdiutil stops and waits for an administrator's password when it meets
                // some of these, and hdiutil and ditto both wait forever on a named pipe:
                // an unattended run waited all night with its snapshot held. Name them
                // now instead.
                if sealed != nil, !stats.dmgBlockers.isEmpty {
                    let why = stats.dmgBlockers.explanation(library: library.displayName, zip: sealed == .zip)
                    for d in dests {
                        results.append(.failed(library: library.displayName, destination: d.target.displayName, error: why))
                    }
                    continue
                }
                onStage(.archiving)

                if let sealed {
                    // SEALED: compress once to scratch, then copy/ship to each destination
                    // after the snapshot — no recompression per destination.
                    for d in dests where !d.available {
                        results.append(.failed(library: library.displayName, destination: d.target.displayName,
                                               error: "\(d.target.displayName) is unavailable — \(d.reason ?? "not reachable")"))
                    }
                    let reachable = dests.filter(\.available).map(\.target)
                    for t in reachable where folderOf[t.id]?[library.id] == nil {
                        results.append(.failed(library: library.displayName, destination: t.displayName,
                                               error: folderFailures[t.id]?[library.id] ?? "\(t.displayName) is unavailable"))
                    }
                    let live = reachable.filter { folderOf[$0.id]?[library.id] != nil }
                    if live.isEmpty { continue }
                    let needed = sourceSize + sourceSize / 20
                    if (Self.freeSpace(for: self.scratchBase) ?? .max) < needed {
                        for t in live {
                            results.append(.failed(library: library.displayName, destination: t.displayName,
                                error: "not enough space on the scratch volume: needs ~\(Self.human(sourceSize)), only \(Self.human(Self.freeSpace(for: self.scratchBase) ?? 0)) free"))
                        }
                        continue
                    }
                    let buildDir = self.scratchBase.appendingPathComponent("\(job.id)/build/\(Self.safe(library.id))", isDirectory: true)
                    let poller = self.archivePoller(total: sourceSize, outputDir: buildDir, idx: idx, count: count, onProgress: onProgress)
                    do {
                        builds.append(try self.buildSealed(job: job, library: library, index: idx, source: source,
                                                           sealed: sealed, buildDir: buildDir, dests: live,
                                                           runner: runner, passphrase: passphrase, onStage: onStage))
                        poller.cancel()
                    } catch is CancelledError { poller.cancel(); cancelled = true; break }
                    catch {
                        poller.cancel()
                        for t in live { results.append(.failed(library: library.displayName, destination: t.displayName, error: Self.failureText(error))) }
                    }
                } else {
                    // LIVE MIRROR: an in-place incremental rsync per destination, from
                    // the snapshot. Cheap to repeat, so each destination is its own mirror.
                    if let note = stats.dmgBlockers.leftOutOfMirror(library: library.displayName) { notes.append(note) }
                    for d in dests {
                        if control.isCancelled { cancelled = true; break libraryLoop }
                        let t = d.target
                        guard d.available else {
                            results.append(.failed(library: library.displayName, destination: t.displayName,
                                                   error: "\(t.displayName) is unavailable — \(d.reason ?? "not reachable")"))
                            continue
                        }
                        guard let libDir = folderOf[t.id]?[library.id] else {
                            results.append(.failed(library: library.displayName, destination: t.displayName,
                                                   error: folderFailures[t.id]?[library.id] ?? "\(t.displayName) is unavailable"))
                            continue
                        }
                        let mirrorExists = FileManager.default.fileExists(atPath: libDir.appendingPathComponent(source.name + ".sparsebundle").path)
                        if !mirrorExists {
                            let needed = sourceSize + sourceSize / 20
                            if (Self.freeSpace(for: t.destinationDir) ?? .max) < needed {
                                results.append(.failed(library: library.displayName, destination: t.displayName,
                                    error: "not enough space on \(t.displayName): needs ~\(Self.human(sourceSize)), only \(Self.human(Self.freeSpace(for: t.destinationDir) ?? 0)) free"))
                                continue
                            }
                        }
                        let poller = self.archivePoller(total: sourceSize, outputDir: libDir, idx: idx, count: count, onProgress: onProgress)
                        do {
                            results.append(try self.direct(job: job, library: library, source: source,
                                                           dest: libDir, target: t, runner: runner,
                                                           passphrase: passphrase, onStage: onStage))
                            poller.cancel()
                        } catch is CancelledError {
                            poller.cancel(); cancelled = true; break libraryLoop
                        } catch {
                            poller.cancel()
                            results.append(.failed(library: library.displayName, destination: t.displayName, error: Self.failureText(error)))
                        }
                    }
                }
            }
            return SnapshotPass(results: results, builds: builds, cancelled: cancelled, notes: notes)
        }

        if pass.cancelled {
            pass.builds.forEach(cleanupBuild)
            if sealed != nil {
                Self.pruneVersions(folders: Self.prunable(job, folderOf), policy: job.retention, checks: healthRecords())
            }
            return .cancelled
        }
        var results = pass.results

        // choose a version-folder name that doesn't collide with an existing one — two
        // runs of the same job in the same second would otherwise overwrite. Bump by
        // whole seconds so the name stays a parseable timestamp.
        var versionDate = now
        if !pass.builds.isEmpty {
            let folders = folderOf.values.flatMap(\.values)
            while folders.contains(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent(VersionStamp.string(versionDate)).path) }) {
                versionDate = versionDate.addingTimeInterval(1)
            }
        }
        let versionStamp = VersionStamp.string(versionDate)

        // distribute each built sealed archive to its destinations (snapshot released).
        // A resumable destination ships in parts; everything else is a copy + split +
        // manifest. No recompression: the artifact was built once above.
        for build in pass.builds {
            if control.isCancelled { pass.builds.forEach(cleanupBuild); return .cancelled }
            var keepBuild = false      // a dropped resumable ship leaves a pending → keep the artifact for resume
            for dest in build.dests {
                if control.isCancelled { pass.builds.forEach(cleanupBuild); return .cancelled }
                let needed = build.byteSize + build.byteSize / 20
                if (Self.freeSpace(for: dest.destinationDir) ?? .max) < needed {
                    results.append(.failed(library: build.library.displayName, destination: dest.displayName,
                        error: "not enough space on \(dest.displayName): needs ~\(Self.human(build.byteSize)), only \(Self.human(Self.freeSpace(for: dest.destinationDir) ?? 0)) free"))
                    continue
                }
                guard let libFolder = folderOf[dest.id]?[build.library.id] else { continue }     // dests were those with one
                let destDir = libFolder.appendingPathComponent(versionStamp, isDirectory: true)
                do {
                    if dest.constraints.resumableTransfer {
                        onStage(.transferring)
                        let key = "\(build.jobID):\(Self.safe(dest.id)):\(build.library.id)"
                        let pending = PendingTransfer(jobID: key, sourceFile: build.builtFile.path,
                                                      baseName: build.builtFile.lastPathComponent, totalBytes: build.byteSize,
                                                      chunkSize: chunkSize, targetDir: destDir.path, format: build.format,
                                                      encrypted: build.encrypted)
                        pendingStore?.save(pending)
                        let tStart = Date(); let chunk = pending.chunkSize, totalBytes = pending.totalBytes
                        let manifest = try ChunkedShipper().ship(pending, persist: { pendingStore?.save($0) }, control: control,
                            onPart: { done, total in
                                let bytesDone = min(UInt64(done) * chunk, totalBytes)
                                let elapsed = Date().timeIntervalSince(tStart)
                                let rate: Double? = elapsed > 0 ? Double(bytesDone) / elapsed : nil
                                let remaining = totalBytes > bytesDone ? totalBytes - bytesDone : 0
                                let eta: TimeInterval? = (rate ?? 0) > 0 ? Double(remaining) / rate! : nil
                                onProgress(RunProgress(stage: .transferring, libraryIndex: build.index, libraryCount: count,
                                                       fraction: total > 0 ? Double(done) / Double(total) : nil,
                                                       detail: "\(dest.displayName): part \(done) of \(total)",
                                                       speed: rate, eta: eta, elapsed: elapsed))
                            })
                        pendingStore?.remove(jobID: key)
                        results.append(.completed(library: build.library.displayName, destination: dest.displayName,
                                                  parts: manifest.artifacts.count, bytes: build.byteSize, verified: build.verified))
                    } else {
                        onStage(.transferring)
                        // poll the copy's growth so a large local copy shows progress.
                        let poller = self.archivePoller(total: build.byteSize, outputDir: destDir, idx: build.index, count: count, onProgress: onProgress)
                        let engine = SealedArchiveEngine(build.format == .sealedDMG ? .dmg : .zip,
                                                         split: dest.constraints.splitPolicy, runner: runner)
                        let result = try engine.distribute(builtFile: build.builtFile, into: destDir, encrypted: build.encrypted)
                        poller.cancel()
                        // confirm the copy matches the verified build, so a copy that was
                        // corrupted in transit can't masquerade as a good backup.
                        guard Self.copyMatches(result, expectedDigest: build.contentDigest, expectedBytes: build.byteSize) else {
                            results.append(.failed(library: build.library.displayName, destination: dest.displayName,
                                error: "the copy at \(dest.displayName) didn't match the source — it may have been corrupted in transit"))
                            continue
                        }
                        results.append(.completed(library: build.library.displayName, destination: dest.displayName,
                                                  parts: result.artifacts.count, bytes: build.byteSize, verified: build.verified))
                    }
                } catch is CancelledError {
                    pass.builds.forEach(cleanupBuild); return .cancelled
                } catch {
                    if dest.constraints.resumableTransfer { keepBuild = true }     // pending saved → resume later
                    results.append(.failed(library: build.library.displayName, destination: dest.displayName, error: Self.failureText(error)))
                }
            }
            if !keepBuild { cleanupBuild(build) }
        }

        var pruneFailures: [String] = []
        if sealed != nil {      // prune old sealed versions per the retention policy, per destination
            pruneFailures = Self.pruneVersions(folders: Self.prunable(job, folderOf), policy: job.retention, checks: healthRecords())
        }
        // the note on how to restore without Cryoframe, brought up to date in each
        // destination this run reached; a note that can't be written is logged, never
        // a failure (see RecoveryNote)
        for d in dests where d.available { RecoveryNote.write(in: d.target.destinationDir) }
        // each destination that got every library, for its "last copy" (a rotating
        // drive's age, see RotationRules)
        let copied = dests.filter { d in
            d.available && job.libraries.allSatisfy { lib in
                results.contains { if case .completed(lib.displayName, d.target.displayName, _, _, let v) = $0 { return v != false }; return false }
            }
        }.map(\.target.id)
        jobStore?.recordCopies(jobID: job.id, targetIDs: copied, at: now)
        let reached = Set(results.compactMap { r -> String? in if case .completed(_, let dest, _, _, _) = r { return dest }; return nil })
        for d in dests where knownPlaces.contains(d.target.id) && reached.contains(d.target.displayName) {
            if var identity = DestinationResolver(volumes: self.volumes).identity(for: d.target.destinationDir) {
                identity.learnedAt = now
                jobStore?.recordVolume(jobID: job.id, targetID: d.target.id, identity)
            }
        }
        onStage(.completed)
        jobStore?.recordRun(id: job.id, at: now)
        // a run that backed up fine but could not prune still succeeded — say so in the
        // warning rather than failing it, but do not let it pass in silence.
        let pruneNote = pruneFailures.isEmpty ? nil
            : "couldn't remove \(pruneFailures.count) old version\(pruneFailures.count == 1 ? "" : "s") — \(pruneFailures.joined(separator: "; "))"
        let warning = ([decision.warning, pruneNote].compactMap { $0 } + folderNotes + pass.notes).joined(separator: " · ")
        return .finished(results: results, warning: warning.isEmpty ? nil : warning)
    }

    /// sweep empty/partial sealed-version folders left by failed or cancelled runs,
    /// then delete completed versions the retention policy doesn't keep. Only version
    /// folders with a manifest count as real versions — otherwise a failed run's empty
    /// husk could occupy a "keep" slot and evict a good archive.
    /// Returns what it could NOT delete. Retention failing is not cosmetic: the
    /// destination keeps growing while the app, and the storage-pressure warning,
    /// both go on believing the job is bounded. A share that dropped, a file still
    /// held open, a permissions change — all silent before 1.5.2.
    @discardableResult
    ///
    /// The version of each library last known to restore (a passed drill, else a
    /// passed checksum check, in `checks`) is never deleted, whatever the policy says.
    static func pruneVersions(target: URL, libraries: [ContentType], policy: RetentionPolicy,
                              checks: [HealthRecord] = []) -> [String] {
        pruneVersions(folders: libraries.map { ($0, target.appendingPathComponent($0.displayName, isDirectory: true)) },
                      policy: policy, checks: checks)
    }

    /// the same, for each library's own folder (see LibraryFolders): only a folder a
    /// run writes to is pruned, never a 1.5 folder left for reading
    @discardableResult
    static func pruneVersions(folders: [(library: ContentType, folder: URL)], policy: RetentionPolicy,
                              checks: [HealthRecord] = []) -> [String] {
        let fm = FileManager.default
        var failures: [String] = []
        for (library, libDir) in folders {
            let entries = (try? fm.contentsOfDirectory(at: libDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            var complete: [(url: URL, date: Date)] = []
            for e in entries {
                guard (try? e.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                      let d = VersionStamp.date(e.lastPathComponent) else { continue }
                if fm.fileExists(atPath: e.appendingPathComponent(ArchiveManifest.sidecarName).path) {
                    complete.append((e, d))
                } else {
                    try? fm.removeItem(at: e)        // junk from a failed/cancelled run
                }
            }
            guard policy != .keepAll else { continue }
            let identity = LibraryIdentity.read(in: libDir)
            let known = KnownGood.version(of: library.displayName, key: identity?.key, formerNames: identity?.formerNames ?? [],
                                          among: complete.map(\.date), records: checks)
            let prune = retentionPrune(complete.map(\.date), policy: policy, keeping: Set([known].compactMap { $0 }))
            for v in complete where prune.contains(v.date) {
                do { try fm.removeItem(at: v.url) }
                catch { failures.append("\(library.displayName) \(VersionStamp.string(v.date)): \((error as NSError).localizedDescription)") }
            }
        }
        return failures
    }

    /// every library's folder at every destination `targets` names, ready to write to;
    /// why for each that couldn't be got ready; and what the run should say about it
    static func prepareFolders(_ job: BackupJob, at targets: [Target], jobs: [BackupJob])
        -> (folders: [String: [String: URL]], failures: [String: [String: String]], notes: [String]) {
        var folders: [String: [String: URL]] = [:], failures: [String: [String: String]] = [:], notes: [String] = []
        for t in targets {
            for lib in job.libraries {
                do {
                    let p = try LibraryFolders.prepare(job: job, library: lib, in: t.destinationDir, jobs: jobs)
                    folders[t.id, default: [:]][lib.id] = p.folder
                    for n in p.notes where !notes.contains(n) { notes.append(n) }
                } catch {
                    failures[t.id, default: [:]][lib.id] = "couldn't get \(lib.displayName)'s folder at \(t.displayName) ready — \(failureText(error))"
                }
            }
        }
        return (folders, failures, notes)
    }

    /// the folders retention prunes: the ones this run wrote to
    static func prunable(_ job: BackupJob, _ folderOf: [String: [String: URL]]) -> [(library: ContentType, folder: URL)] {
        job.targets.flatMap { t in job.libraries.compactMap { lib in folderOf[t.id]?[lib.id].map { (lib, $0) } } }
    }

    /// confirm a distributed copy matches the verified build. A single file is hashed
    /// against the build's digest; split parts must sum to the build's byte size (their
    /// per-part manifest covers content integrity at restore/health time).
    private static func copyMatches(_ result: ArchiveResult, expectedDigest: String, expectedBytes: UInt64) -> Bool {
        if result.artifacts.count == 1 {
            guard let d = try? Checksum.sha256(of: result.artifacts[0]) else { return false }
            return expectedDigest.isEmpty || d == expectedDigest   // empty = couldn't hash at build; don't block
        }
        let total = result.artifacts.reduce(UInt64(0)) { $0 + ((try? FileManager.default.attributesOfItem(atPath: $1.path)[.size]) as? UInt64 ?? 0) }
        return total == expectedBytes
    }

    /// remove sealed build artifacts left in scratch by a crash or a one-time job —
    /// any `scratchBase/<job>/build/<lib>` whose artifact no pending transfer still
    /// references. With `locks`, a job that is running (in this process or the
    /// scheduled agent) is skipped: its build folder is a half-written archive, not
    /// a leftover. Without them, only safe when nothing can be running.
    public static func sweepOrphanedScratch(scratchBase: URL, pendingStore: PendingTransferStore, locks: RunLocks? = nil) {
        let fm = FileManager.default
        let referenced = Set(pendingStore.all().map(\.sourceFile))
        guard let jobDirs = try? fm.contentsOfDirectory(at: scratchBase, includingPropertiesForKeys: nil) else { return }
        for jobDir in jobDirs {
            let buildRoot = jobDir.appendingPathComponent("build", isDirectory: true)
            guard let libDirs = try? fm.contentsOfDirectory(at: buildRoot, includingPropertiesForKeys: nil) else { continue }
            var lease: RunLease?
            if let locks {
                guard let held = try? locks.acquire(jobID: jobDir.lastPathComponent, trigger: .cleanup) else { continue }
                lease = held
            }
            defer { lease?.release() }
            for libDir in libDirs {
                let artifacts = (try? fm.contentsOfDirectory(at: libDir, includingPropertiesForKeys: nil)) ?? []
                if !artifacts.contains(where: { referenced.contains($0.path) }) { try? fm.removeItem(at: libDir) }
            }
            if (try? fm.contentsOfDirectory(atPath: buildRoot.path))?.isEmpty == true { try? fm.removeItem(at: buildRoot) }
        }
    }

    /// usable free space at `url` (or its nearest existing ancestor), for preflight.
    /// Returns nil when the filesystem doesn't report it — network shares (SMB/AFP)
    /// and many non-APFS volumes return 0 for the "important usage" key, which must
    /// be read as "unknown," never as "full," or we'd false-fail valid backups.
    public static func freeSpace(for url: URL) -> UInt64? {
        var dir = url
        for _ in 0..<8 {
            // A URL keeps the resource values it has read. The app holds a job's
            // destination URL for as long as it runs, so without this it went on
            // reporting the free space it saw the first time, however full the drive
            // had since become.
            dir.removeAllCachedResourceValues()
            // first existing ancestor IS the target volume — read it and stop, even if
            // it answers "unknown" (nil). Walking further would cross into /Volumes on
            // the boot disk and report the wrong volume's free space.
            if let v = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                         .volumeAvailableCapacityKey]) {
                return usableFree(importantUsage: v.volumeAvailableCapacityForImportantUsage,
                                  available: v.volumeAvailableCapacity)
            }
            let parent = dir.deletingLastPathComponent()
            if parent == dir { break }
            dir = parent
        }
        return nil
    }

    /// Free space at `url`'s volume right now, not counting what the system could purge
    /// (local snapshots, caches). `freeSpace` counts purgeable space on the startup
    /// disk, which is right for "will this fit eventually" but not for sizing a disk
    /// image: purging happens on demand, after a write needs the room, and a sparse
    /// image whose band write finds no room loses it. nil when the volume won't say.
    public static func freeNow(for url: URL) -> UInt64? {
        var dir = url
        for _ in 0..<8 {
            dir.removeAllCachedResourceValues()
            if let v = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityKey]) {
                return v.volumeAvailableCapacity.flatMap { $0 > 0 ? UInt64($0) : nil }
            }
            let parent = dir.deletingLastPathComponent()
            if parent == dir { break }
            dir = parent
        }
        return nil
    }

    /// pick a trustworthy free-space figure: APFS "important usage" when it's a real
    /// number, else plain available capacity, else nil. A reported 0 means "this
    /// filesystem doesn't answer," so we keep walking to the parent / give up rather
    /// than treat the target as full.
    static func usableFree(importantUsage: Int64?, available: Int?) -> UInt64? {
        if let imp = importantUsage, imp > 0 { return UInt64(imp) }
        if let avail = available, avail > 0 { return UInt64(avail) }
        return nil
    }

    // MARK: progress

    /// polls the output directory's size against the (known) source size while an
    /// archive runs, so the UI shows a moving bytes-written bar.
    private func archivePoller(total: UInt64, outputDir: URL, idx: Int, count: Int,
                               onProgress: @escaping @Sendable (RunProgress) -> Void) -> Task<Void, Never> {
        Task.detached {
            let start = Date()
            var lastBytes: UInt64 = 0
            var lastTime = start
            var rate: Double?                            // bytes/sec, EWMA-smoothed
            while !Task.isCancelled {
                let written = Self.directorySize(outputDir)
                let now = Date()
                let dt = now.timeIntervalSince(lastTime)
                if dt >= 0.1 {
                    let delta = written >= lastBytes ? Double(written - lastBytes) : 0
                    let instant = delta / dt
                    rate = rate.map { 0.65 * $0 + 0.35 * instant } ?? instant
                    lastBytes = written; lastTime = now
                }
                let remaining = total > written ? total - written : 0
                let eta: TimeInterval? = (rate ?? 0) > 0 ? Double(remaining) / rate! : nil
                // the denominator is the SOURCE size, and a sealed archive can exceed
                // it, so "5.2 MB of 4.5 MB" was reachable beside a bar pinned at 99%.
                // Past the estimate, just report what's been written.
                let haveEstimate = total > 0 && written <= total
                let fraction = total > 0 ? min(0.99, Double(written) / Double(total)) : nil
                let detail = haveEstimate ? "\(Self.human(written)) of \(Self.human(total))" : Self.human(written)
                onProgress(RunProgress(stage: .archiving, libraryIndex: idx, libraryCount: count, fraction: fraction,
                                       detail: detail, speed: rate, eta: eta, elapsed: now.timeIntervalSince(start)))
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
        }
    }

    /// what one walk of a source tells the run: allocated bytes, how many things
    /// worth backing up it holds (regular files and symlinks — a folder of links is
    /// not nothing), and whether the walk could see the tree at all.
    /// With `forDMG`, also what in it would make a sealed DMG's build stop and ask for
    /// a password (see DMGBlockers), found on the same walk.
    struct DirectoryStats {
        var bytes: UInt64 = 0; var entries = 0; var readable = true
        var dmgBlockers = DMGBlockers()
    }

    /// With `forZip`, what a sealed zip can't hold (named pipes, sockets, devices);
    /// with `forMirror`, the same, which a live mirror leaves out (see MirrorCopy.isLeftOut).
    static func directoryStats(_ url: URL, forDMG: Bool = false, forZip: Bool = false,
                               forMirror: Bool = false) -> DirectoryStats {
        var out = DirectoryStats()
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        let root = url.standardizedFileURL.path
        // a folder that can't be listed is found by inspecting it, before the walk
        // tries to go in (see DMGBlockers.inspect)
        guard FileManager.default.isReadableFile(atPath: url.path),
              let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [],
                                                     errorHandler: { _, _ in out.readable = false; return true }) else {
            out.readable = false; return out
        }
        var groups = DMGBlockers.Membership()
        let sealed = forDMG || forZip || forMirror
        if sealed { out.dmgBlockers.inspect(url.path, relative: url.lastPathComponent, groups: &groups, forDMG: forDMG) }   // copied too
        for case let u as URL in e {
            if sealed { out.dmgBlockers.inspect(u.path, relative: DMGBlockers.relative(u.path, to: root), groups: &groups, forDMG: forDMG) }
            guard let v = try? u.resourceValues(forKeys: keys) else { continue }
            if v.isSymbolicLink == true { out.entries += 1; continue }
            guard v.isRegularFile == true else { continue }
            out.entries += 1
            out.bytes += UInt64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        return out
    }

    /// true when a readable source holds nothing to back up (empty folders don't
    /// count). An unreadable one is NOT empty — it is unreadable, and says so elsewhere.
    static func isEmptyTree(_ url: URL) -> Bool {
        let s = directoryStats(url)
        return s.readable && s.entries == 0
    }

    public static func directorySize(_ url: URL) -> UInt64 { directoryStats(url).bytes }

    /// what a failed library says on the job row, in History, and in alerts. Every
    /// Kit error is a LocalizedError with a sentence written for this; String(describing:)
    /// printed the enum case instead ("toolFailed(tool: \"hdiutil\", status: 1, …)"),
    /// and none of those sentences ever reached a per-library failure.
    static func failureText(_ error: Error) -> String { error.localizedDescription }

    static func human(_ bytes: UInt64) -> String {
        let f = ByteCountFormatter(); f.countStyle = .file
        return f.string(fromByteCount: Int64(bytes))
    }

    // MARK: per-library

    /// compress a library into one sealed artifact in scratch (unsplit), verifying it
    /// once. The distribution step copies/ships it to each destination afterward.
    private func buildSealed(job: BackupJob, library: ContentType, index: Int, source: ArchiveSource,
                             sealed: SealedArchiveEngine.Sealed, buildDir: URL, dests: [Target], runner: CommandRunner,
                             passphrase: String?, onStage: @escaping @Sendable (BackupStage) -> Void) throws -> SealedBuild {
        let fm = FileManager.default
        try? fm.removeItem(at: buildDir)
        try fm.createDirectory(at: buildDir, withIntermediateDirectories: true)
        let archive = try SealedArchiveEngine(sealed, split: .none, runner: runner, passphrase: passphrase).archive(source, to: buildDir)
        guard let file = archive.artifacts.first,
              let size = (try? fm.attributesOfItem(atPath: file.path)[.size]) as? UInt64 else {
            throw ArchiveError.noArtifactProduced(buildDir)
        }
        var verified: Bool?
        if job.verification == .mountAndOpen {
            onStage(.verifying)
            verified = try StrongVerifier(runner: runner).verify(archive, type: library, passphrase: passphrase).passed
        }
        let digest = (try? Checksum.sha256(of: file)) ?? ""
        return SealedBuild(library: library, jobID: job.id, index: index, builtFile: file, format: archive.format,
                           byteSize: size, contentDigest: digest, verified: verified, encrypted: passphrase != nil,
                           buildDir: buildDir, dests: dests)
    }

    private func direct(job: BackupJob, library: ContentType, source: ArchiveSource, dest: URL, target: Target,
                        runner: CommandRunner, passphrase: String?,
                        onStage: @escaping @Sendable (BackupStage) -> Void) throws -> LibraryRunResult {
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        // the mirror engine writes its own manifest: it has to re-seal the image after
        // a run that stops part-way, too (see MirrorSeal)
        let archive = try EngineFactory.engine(for: job.format, target: target, runner: runner,
                                               passphrase: passphrase).archive(source, to: dest)
        if archive.format != .liveMirror {
            onStage(.checksumming)
            try ArchiveManifest.write(try ArchiveManifest.build(for: archive, encrypted: passphrase != nil), toDir: dest)
        }
        var verified: Bool?
        if job.verification == .mountAndOpen {
            onStage(.verifying)
            verified = try StrongVerifier(runner: runner).verify(archive, type: library, passphrase: passphrase).passed
        }
        let bytes = archive.artifacts.reduce(UInt64(0)) { sum, url in
            sum + ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? UInt64 ?? 0)
        }
        return .completed(library: library.displayName, destination: target.displayName,
                          parts: archive.artifacts.count, bytes: bytes, verified: verified)
    }

    private func cleanupBuild(_ b: SealedBuild) {
        try? FileManager.default.removeItem(at: b.buildDir)
        for d in b.dests { pendingStore?.remove(jobID: "\(b.jobID):\(Self.safe(d.id)):\(b.library.id)") }
    }

    private static func sealedKind(_ format: FormatChoice) -> SealedArchiveEngine.Sealed? {
        switch format {
        case .sealedDMG: return .dmg
        case .sealedZip: return .zip
        case .liveMirror: return nil
        }
    }

    private static func safe(_ s: String) -> String { s.replacingOccurrences(of: "/", with: "_") }
}
