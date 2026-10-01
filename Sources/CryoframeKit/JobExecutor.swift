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
import CryptoKit
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
    /// where an encrypted job's copy of a library without its pipes and sockets is
    /// made (see FilteredCopy): the system cache on the startup disk, whatever
    /// scratch location Settings names
    let plaintextScratch: URL
    /// whether this Mac's disk image tool builds from locked items (see
    /// FilteredCopy.diskImageKeepsLocks); tests set it
    let diskImageKeepsLocks: Bool
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
                plaintextScratch: URL? = nil,
                diskImageKeepsLocks: Bool? = nil,
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
        self.plaintextScratch = plaintextScratch ?? scratchBase
        self.diskImageKeepsLocks = diskImageKeepsLocks ?? FilteredCopy.diskImageKeepsLocks
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
        var notes: [String] = []    // what the run says about how it was built
        /// the version's file list in scratch, copied beside each copy (see ContentsListing)
        var contents: StagedContents?
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
        // A copy of a library a crash left mid-build is a plaintext copy of it, an
        // encrypted job's included: gone before anything else, not only at the app's
        // next launch (the scheduled agent may run this job many times before that).
        // The caller holds this job's run lock, so none of this job's builds is live.
        FilteredCopy.removeLeftovers(jobID: saved.id, under: [scratchBase, plaintextScratch])
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
        // a folder an interrupted transfer still writes into keeps its name until it's done
        let transferDirs = (pendingStore?.all() ?? []).map { URL(fileURLWithPath: $0.targetDir, isDirectory: true) }
        let (folderOf, folderFailures, folderNotes) = Self.prepareFolders(job, at: dests.filter(\.available).map(\.target),
                                                                          jobs: (jobStore?.load().jobs ?? []).map { DestinationResolver(volumes: self.volumes).resolve($0).job },
                                                                          transferring: { folder in transferDirs.contains { DestinationRules.contains(folder, $0) } })

        // A version a folder adopted (taken over from 1.5, or moved in) is pruned only
        // once the person has let the Keep rule apply to it (see AdoptedVersions.swift)
        var folderOwners: [String: (targetID: String, libraryID: String)] = [:]
        for (tid, libs) in folderOf { for (lid, folder) in libs { folderOwners[folder.path] = (tid, lid) } }
        let owners = folderOwners
        func adoptionConfirmed(_ by: BackupJob) -> (URL, String) -> Bool {
            { folder, name in owners[folder.path].map { by.confirmsAdoption(of: name, target: $0.targetID, library: $0.libraryID) } ?? false }
        }
        func adoptionShown(_ by: BackupJob) -> (URL, String) -> Bool {
            { folder, name in owners[folder.path].map { by.hasShownAdoption(of: name, target: $0.targetID, library: $0.libraryID) } ?? false }
        }
        // The Keep rule and the go-aheads as saved when retention runs, not when the run
        // began: a yes given on the dashboard while the run went on is counted (or the
        // run put the card just answered back), and a Keep rule raised meanwhile is
        // what the run prunes by. Read under the store's lock, as a yes is written.
        let jobStore = self.jobStore
        func keepingNow() -> BackupJob {
            var j = job
            if let stored = jobStore?.update({ s in s.jobs.first { $0.id == saved.id } }) {
                j.retention = stored.retention; j.adoptionConsents = stored.adoptionConsents
            }
            return j
        }
        // and before each deletion, that both still hold: one changed while retention
        // ran stops it there, and the next run prunes by what is saved then
        func stillKeeping(_ by: BackupJob) -> () -> Bool {
            {
                guard let jobStore else { return true }
                return jobStore.update { s in
                    guard let stored = s.jobs.first(where: { $0.id == saved.id }) else { return true }
                    return stored.retention == by.retention
                        && (by.adoptionConsents ?? []).allSatisfy { (stored.adoptionConsents ?? []).contains($0) }
                }
            }
        }

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

        // The version folder's name, chosen now: each version's file list says which
        // version it is, and is written as the archive is built. Not one an earlier
        // run's version already has: two runs of the same job in the same second would
        // otherwise overwrite. Bump by whole seconds so the name stays a parseable
        // timestamp. Asked again once the archives are built (see below).
        let allFolders = folderOf.values.flatMap(\.values)
        func freeStamp(from date: Date) -> Date {
            var d = date
            while allFolders.contains(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent(VersionStamp.string(d)).path) }) {
                d = d.addingTimeInterval(1)
            }
            return d
        }
        let plannedDate = sealed == nil ? now : freeStamp(from: now)
        let plannedStamp = VersionStamp.string(plannedDate)
        // an encrypted job's lists are sealed with a key from its passphrase, derived
        // once per run (see ContentsCrypto); without one, its versions get no list
        let listKey = sealed != nil ? passphrase.flatMap { ContentsCrypto.masterKey(passphrase: $0, jobID: job.id) } : nil

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
                // a sealed version's file list, gathered on this walk (see ContentsListing).
                // A library read live, not from a snapshot, may change between this walk
                // and the build, so its list can't say what the archive lacks.
                let listing = sealed == nil ? nil
                    : ContentsListing.Collector(binding: ContentsCrypto.Binding(jobID: job.id, libraryID: library.id, version: plannedStamp))
                if let listing, placement.volume.map({ mounts[$0.mountPoint] == nil }) ?? true { listing.markPartial() }
                let stats = Self.directoryStats(root, forDMG: sealed == .dmg, forZip: sealed == .zip, forMirror: sealed == nil,
                                                listing: listing)
                let sourceSize = stats.bytes
                // a mirror writes every file out whole (see copySize); a sealed archive
                // compresses, and is held to the bytes the library takes on disk
                let source = ArchiveSource(name: root.lastPathComponent, root: root,
                                           sizeHint: sealed == nil ? stats.copyBytes : sourceSize)

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
                // some of these: an unattended run waited all night with its snapshot
                // held. Name them now instead.
                if sealed != nil, !stats.dmgBlockers.refusing.isEmpty {
                    let why = stats.dmgBlockers.refusing.explanation(library: library.displayName)
                    for d in dests {
                        results.append(.failed(library: library.displayName, destination: d.target.displayName, error: why))
                    }
                    continue
                }
                // What's left are named pipes, sockets and devices, on which hdiutil and
                // ditto both hang or fail, and locks: the build may read a copy without
                // them (see SealedReadPlan).
                let plan = sealed.map { SealedReadPlan.of(stats.dmgBlockers, $0, diskImageKeepsLocks: self.diskImageKeepsLocks) } ?? .direct
                let filtered = plan.fromCopy
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
                    let buildDir = self.scratchBase.appendingPathComponent("\(job.id)/build/\(Self.safe(library.id))", isDirectory: true)
                    // a filtered build holds the copy and the archive at once; an
                    // encrypted job's copy is made on the startup disk (see plaintextScratch)
                    let copyBase = passphrase != nil ? self.plaintextScratch : self.scratchBase
                    let copyDir = copyBase.appendingPathComponent("\(job.id)/build/\(Self.safe(library.id))", isDirectory: true)
                    // the same check, copy included, before a refused direct build falls back to a copy
                    let scratchBase = self.scratchBase, copyBytes = stats.copyBytes
                    let copyRoomRefusal = { Self.scratchRefusal(archive: sourceSize, copy: copyBytes, scratch: scratchBase, copyScratch: copyBase) }
                    if let refusal = Self.scratchRefusal(archive: sourceSize, copy: filtered ? stats.copyBytes : nil,
                                                         scratch: self.scratchBase, copyScratch: copyBase) {
                        for t in live { results.append(.failed(library: library.displayName, destination: t.displayName, error: refusal)) }
                        continue
                    }
                    let poller = self.archivePoller(total: sourceSize, outputDir: buildDir, copyDir: copyDir, idx: idx, count: count,
                                                    onProgress: onProgress)
                    do {
                        builds.append(try self.buildSealed(job: job, library: library, index: idx, source: source,
                                                           sealed: sealed, plan: plan, found: stats.dmgBlockers,
                                                           buildDir: buildDir, copyDir: copyDir, copyRoomRefusal: copyRoomRefusal,
                                                           dests: live, runner: runner, passphrase: passphrase,
                                                           listing: listing.map { ($0, listKey) }, onStage: onStage))
                        poller.cancel()
                        notes.append(contentsOf: builds.last?.notes ?? [])
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
                            let copySize = stats.copyBytes
                            let needed = copySize + copySize / 20
                            if (Self.freeSpace(for: t.destinationDir) ?? .max) < needed {
                                results.append(.failed(library: library.displayName, destination: t.displayName,
                                    error: "not enough space on \(t.displayName): needs ~\(Self.human(copySize)), only \(Self.human(Self.freeSpace(for: t.destinationDir) ?? 0)) free"))
                                continue
                            }
                        }
                        let poller = self.archivePoller(total: stats.copyBytes, outputDir: libDir, idx: idx, count: count, onProgress: onProgress)
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

        // a version folder an interrupted transfer (this run's or an earlier one's) is
        // still to finish into isn't a leftover; asked when retention runs
        let pendingStore = self.pendingStore
        let stillTransferring = Self.transferring(job, folderOf, records: { pendingStore?.all() ?? [] }, volumes: self.volumes)
        if pass.cancelled {
            pass.builds.forEach(cleanupBuild)
            if sealed != nil {
                let keeping = keepingNow()
                Self.pruneVersions(folders: Self.prunable(job, folderOf), policy: keeping.retention, checks: healthRecords(),
                                   transferring: stillTransferring, confirmed: adoptionConfirmed(keeping), shown: adoptionShown(keeping),
                                   proceed: stillKeeping(keeping))
            }
            return .cancelled
        }
        var results = pass.results

        // the name chosen before the build, unless a folder of it has turned up since:
        // then the next free one, and the lists, which name the other, aren't copied
        var builds = pass.builds
        let versionDate = builds.isEmpty ? now : freeStamp(from: plannedDate)
        let versionStamp = VersionStamp.string(versionDate)
        if versionStamp != plannedStamp {
            for i in builds.indices { builds[i].contents = nil }
        }

        // distribute each built sealed archive to its destinations (snapshot released).
        // A resumable destination ships in parts; everything else is a copy + split +
        // manifest. No recompression: the artifact was built once above.
        for build in builds {
            if control.isCancelled { builds.forEach(cleanupBuild); return .cancelled }
            var keepBuild = false      // a dropped resumable ship leaves a pending → keep the artifact for resume
            for dest in build.dests {
                if control.isCancelled { builds.forEach(cleanupBuild); return .cancelled }
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
                        // the drive it goes to, so it is finished on that drive and no other
                        var pending = PendingTransfer(jobID: key, sourceFile: build.builtFile.path,
                                                      baseName: build.builtFile.lastPathComponent, totalBytes: build.byteSize,
                                                      chunkSize: chunkSize, targetDir: destDir.path, format: build.format,
                                                      encrypted: build.encrypted,
                                                      volumeUUID: DestinationResolver(volumes: self.volumes).identity(for: dest.destinationDir)?.uuid)
                        // the list beside the staged archive, as it is now: a resume
                        // copies it only if it is still this file
                        pending.contents = build.contents?.digest
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
                        let result = try engine.distribute(builtFile: build.builtFile, into: destDir, encrypted: build.encrypted,
                                                           contents: build.contents)
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
                    builds.forEach(cleanupBuild); return .cancelled
                } catch {
                    if dest.constraints.resumableTransfer { keepBuild = true }     // pending saved → resume later
                    results.append(.failed(library: build.library.displayName, destination: dest.displayName, error: Self.failureText(error)))
                }
            }
            if !keepBuild { cleanupBuild(build) }
        }

        var pruneFailures: [String] = []
        let keeping = keepingNow()
        if sealed != nil {      // prune old sealed versions per the retention policy, per destination
            pruneFailures = Self.pruneVersions(folders: Self.prunable(job, folderOf), policy: keeping.retention, checks: healthRecords(),
                                               transferring: stillTransferring, confirmed: adoptionConfirmed(keeping),
                                               shown: adoptionShown(keeping), proceed: stillKeeping(keeping))
        }
        // what was left alone for the person to say yes to, said in the run's warning
        // and kept for the dashboard: counted with the go-aheads as saved now, and not
        // one a yes given since has answered
        let counted = sealed == nil ? [] : Self.adoptionReviews(keeping, folderOf, checks: healthRecords(), transferring: stillTransferring,
                                                                 confirmed: adoptionConfirmed(keeping), shown: adoptionShown(keeping), now: now)
        let reviews = jobStore?.recordAdoptionReviews(jobID: job.id, counted, reached: Set(folderOf.keys)) ?? counted
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
        let warning = ([decision.warning, pruneNote].compactMap { $0 } + folderNotes + reviews.map(\.text) + pass.notes).joined(separator: " · ")
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
    ///
    /// The version of each library last known to restore (a passed drill, else a
    /// passed checksum check, in `checks`) is never deleted, whatever the policy says.
    /// `confirmed`: see prunePlan; there is no default, so no caller deletes adopted
    /// versions without saying which it may.
    @discardableResult
    static func pruneVersions(target: URL, libraries: [ContentType], policy: RetentionPolicy,
                              checks: [HealthRecord] = [], confirmed: @escaping (URL, String) -> Bool) -> [String] {
        pruneVersions(folders: libraries.map { ($0, target.appendingPathComponent($0.displayName, isDirectory: true)) },
                      policy: policy, checks: checks, confirmed: confirmed)
    }

    /// the same, for each library's own folder (see LibraryFolders): only a folder a
    /// run writes to is pruned, never a 1.5 folder left for reading. `transferring`:
    /// whether an interrupted transfer is still to finish into a folder (see prunePlan).
    /// `confirmed`, `shown`: see prunePlan. `confirmed` has no default: nothing
    /// deletes an adopted version unless its caller says which it may. `proceed`:
    /// asked before each deletion; once it says no, nothing more is deleted.
    @discardableResult
    static func pruneVersions(folders: [(library: ContentType, folder: URL)], policy: RetentionPolicy,
                              checks: [HealthRecord] = [], transferring: (URL) -> Bool = { _ in false },
                              confirmed: @escaping (URL, String) -> Bool, shown: ((URL, String) -> Bool)? = nil,
                              proceed: () -> Bool = { true }) -> [String] {
        let plan = prunePlan(folders: folders, policy: policy, checks: checks, transferring: transferring, confirmed: confirmed, shown: shown)
        let fm = FileManager.default
        for husk in plan.husks {        // junk from a failed/canceled run
            guard proceed() else { return [] }
            try? fm.removeItem(at: husk)
        }
        var failures: [String] = []
        for v in plan.versions {
            guard proceed() else { return failures }
            do { try fm.removeItem(at: v.url) }
            catch { failures.append("\(v.library) \(VersionStamp.string(v.date)): \((error as NSError).localizedDescription)") }
        }
        return failures
    }

    /// What retention deletes, without deleting anything.
    public struct PrunePlan: Sendable, Equatable {
        public struct Version: Sendable, Equatable {
            public var library: String
            public var url: URL
            public var date: Date
        }
        /// version folders with no manifest: a failed or stopped run's leftovers
        public var husks: [URL] = []
        /// complete versions the policy doesn't keep
        public var versions: [Version] = []
    }

    /// One library's versions as retention reads them: those in its folder and, for
    /// saying what a run does before it has run, those the run moves in first (see
    /// LibraryFolders.next).
    struct Shelf {
        var library: ContentType
        var folder: URL
        var identity: LibraryIdentity?
        /// the version folders, wherever each is now
        var entries: [URL]
        /// the names of those the folder adopted (see LibraryIdentity.adoptedVersions)
        var adopted: Set<String>
    }

    /// `library`'s folder `folder` as it is on disk
    static func shelf(_ library: ContentType, _ folder: URL) -> Shelf {
        let identity = LibraryIdentity.read(in: folder)
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return Shelf(library: library, folder: folder, identity: identity, entries: entries, adopted: Set(identity?.adoptedVersions ?? []))
    }

    /// `library`'s folder at `destination` as `job`'s next run leaves it once it is
    /// ready to write to (see LibraryFolders.next): the folder it takes over, with
    /// every version in it adopted, and the versions it moves in. Reads; changes nothing.
    static func nextShelf(job: BackupJob, library: ContentType, in destination: URL, jobs: [BackupJob]) -> (shelf: Shelf, next: LibraryFolders.Next) {
        let next = LibraryFolders.next(job: job, library: library, in: destination, jobs: jobs)
        let folder = next.folder ?? destination.appendingPathComponent(LibraryFolderName.choose(job: job, library: library, in: destination), isDirectory: true)
        var s = next.folder == nil || next.takesOver ? Shelf(library: library, folder: folder, identity: LibraryIdentity(job: job, library: library),
                                                             entries: [], adopted: [])
            : shelf(library, folder)
        if next.takesOver { s.entries = shelf(library, folder).entries }
        s.entries += next.movesIn
        s.adopted.formUnion(next.adopts)
        return (s, next)
    }

    /// The one rule for what retention deletes, for a run and for showing it before a
    /// save. Only version folders with a manifest are versions; one without is a
    /// failed run's leftover, unless an interrupted transfer is still to finish into
    /// it (`transferring`): the manifest is its last part. Held versions are never
    /// touched (see LibraryIdentity.heldVersions), nor the version of each library
    /// last known to restore (see KnownGood). `upcoming`: a version the next run
    /// adds, counted by the policy (it takes a place) but not itself in the plan, for
    /// saying what the next run deletes before it has run.
    ///
    /// `confirmed`: whether the person was told the next backup deletes a version a
    /// folder adopted, and said yes (the folder, the version's name; see
    /// AdoptedVersions.swift): only such a one is ever deleted. `shown`: whether they
    /// were shown it at all (nil: the same as `confirmed`). One they were shown takes
    /// its place among the versions the rule keeps; one they weren't is left out
    /// altogether, as a held one is: never deleted, taking no place. `confirmed` nil:
    /// every adopted version counts and may go, for counting what saying yes deletes.
    static func prunePlan(folders: [(library: ContentType, folder: URL)], policy: RetentionPolicy,
                          checks: [HealthRecord] = [], transferring: (URL) -> Bool = { _ in false },
                          upcoming: Date? = nil, confirmed: ((URL, String) -> Bool)? = nil,
                          shown: ((URL, String) -> Bool)? = nil) -> PrunePlan {
        prunePlan(shelves: folders.map { shelf($0.library, $0.folder) }, policy: policy, checks: checks,
                  transferring: transferring, upcoming: upcoming, confirmed: confirmed, shown: shown)
    }

    static func prunePlan(shelves: [Shelf], policy: RetentionPolicy, checks: [HealthRecord] = [],
                          transferring: (URL) -> Bool = { _ in false }, upcoming: Date? = nil,
                          confirmed: ((URL, String) -> Bool)? = nil, shown: ((URL, String) -> Bool)? = nil) -> PrunePlan {
        let fm = FileManager.default
        var plan = PrunePlan()
        for shelf in shelves {
            let identity = shelf.identity
            var complete: [(url: URL, date: Date, mayGo: Bool)] = []
            for e in shelf.entries {
                let name = e.lastPathComponent
                // held versions aren't provably this library's (see heldVersions)
                guard (try? e.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                      let d = VersionStamp.date(name), identity?.holds(name) != true else { continue }
                var mayGo = true
                if let confirmed, shelf.adopted.contains(name) {
                    // adopted, and never shown to the person under this rule
                    guard (shown ?? confirmed)(shelf.folder, name) else { continue }
                    // shown: kept unless they were told the next backup deletes it
                    mayGo = confirmed(shelf.folder, name)
                }
                if fm.fileExists(atPath: e.appendingPathComponent(ArchiveManifest.sidecarName).path) {
                    complete.append((e, d, mayGo))
                } else if mayGo, !transferring(e) {
                    plan.husks.append(e)
                }
            }
            guard policy != .keepAll else { continue }
            let known = KnownGood.version(of: shelf.library.displayName, key: identity?.key, formerNames: identity?.formerNames ?? [],
                                          among: complete.map(\.date), records: checks)
            let prune = retentionPrune(complete.map(\.date) + [upcoming].compactMap { $0 }, policy: policy,
                                       keeping: Set([known].compactMap { $0 }))
            for v in complete where v.mayGo && prune.contains(v.date) {
                plan.versions.append(.init(library: shelf.library.displayName, url: v.url, date: v.date))
            }
        }
        return plan
    }

    /// every library's folder at every destination `targets` names, ready to write to;
    /// why for each that couldn't be got ready; and what the run should say about it
    static func prepareFolders(_ job: BackupJob, at targets: [Target], jobs: [BackupJob],
                               transferring: (URL) -> Bool = { _ in false })
        -> (folders: [String: [String: URL]], failures: [String: [String: String]], notes: [String]) {
        var folders: [String: [String: URL]] = [:], failures: [String: [String: String]] = [:], notes: [String] = []
        for t in targets {
            for lib in job.libraries {
                do {
                    let p = try LibraryFolders.prepare(job: job, library: lib, in: t.destinationDir, jobs: jobs, transferring: transferring)
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
    /// Whether an interrupted transfer is still to finish into a version folder of
    /// `job`'s library folders (`folderOf`: destination id → library id → folder),
    /// by what each transfer is for (see PendingTransfer.writesInto).
    static func transferring(_ job: BackupJob, _ folderOf: [String: [String: URL]], records: @escaping () -> [PendingTransfer],
                             volumes: VolumeTable) -> (URL) -> Bool {
        let owners = folderOf.flatMap { dest, libs in libs.map { (folder: $0.value, key: "\(job.id):\(safe(dest)):\($0.key)") } }
        return { dir in
            let records = records()
            guard !records.isEmpty else { return false }
            let parent = dir.deletingLastPathComponent()
            let key = owners.first { DestinationRules.samePath($0.folder, parent) }?.key
            let volume = volumes.volume(containing: dir)
            return records.contains { $0.writesInto(dir, key: key, volume: volume) }
        }
    }

    /// What to ask about the versions `shelf` adopted, under `policy` with the next
    /// backup at `upcoming`: every one of them there, and of them what saying yes lets
    /// that backup delete, counted with every one of them in its place, and (under a
    /// rule that keeps the last so many) what later backups delete after it. nil when
    /// there's nothing to ask: each was shown to the person under this rule (`shown`,
    /// by name), and the rule deletes none they weren't told it would (`confirmed`).
    static func adoptionQuestion(_ shelf: Shelf, policy: RetentionPolicy, checks: [HealthRecord] = [],
                                 transferring: (URL) -> Bool = { _ in false }, upcoming: Date,
                                 shown: (String) -> Bool, confirmed: (String) -> Bool) -> AdoptionQuestion? {
        let waiting = Set(shelf.entries.map(\.lastPathComponent)).intersection(shelf.adopted).filter { shelf.identity?.holds($0) != true }
        guard !waiting.isEmpty else { return nil }
        let yes = prunePlan(shelves: [shelf], policy: policy, checks: checks, transferring: transferring, upcoming: upcoming)
        let gone = Set(yes.versions.map(\.url.lastPathComponent)).intersection(waiting)
        let unfinished = Set(yes.husks.map(\.lastPathComponent)).intersection(waiting)
        // Keeping the last so many, every finished one older than the next backup is
        // pushed out in turn as new versions arrive, the oldest first (one known to
        // restore stays until a newer one is; see KnownGood): nothing about which goes
        // when is unknown now, so one yes names them all.
        var later = Set<String>()
        if case .keepLast = policy {
            for e in shelf.entries {
                let name = e.lastPathComponent
                guard waiting.contains(name), !gone.contains(name), !unfinished.contains(name),
                      let d = VersionStamp.date(name), d < upcoming,
                      FileManager.default.fileExists(atPath: e.appendingPathComponent(ArchiveManifest.sidecarName).path) else { continue }
                later.insert(name)
            }
        }
        if waiting.allSatisfy(shown), gone.union(unfinished).union(later).allSatisfy(confirmed) { return nil }
        // of those, the one known to restore stays until a newer one is: said apart
        var kept: [String] = []
        if !later.isEmpty {
            let complete = shelf.entries.filter {
                shelf.identity?.holds($0.lastPathComponent) != true
                    && FileManager.default.fileExists(atPath: $0.appendingPathComponent(ArchiveManifest.sidecarName).path)
            }
            let dated = complete.compactMap { e in VersionStamp.date(e.lastPathComponent).map { (name: e.lastPathComponent, date: $0) } }
            if let known = KnownGood.version(of: shelf.library.displayName, key: shelf.identity?.key,
                                             formerNames: shelf.identity?.formerNames ?? [], among: dated.map(\.date), records: checks) {
                kept = dated.filter { $0.date == known && later.contains($0.name) }.map(\.name)
            }
        }
        return AdoptionQuestion(versions: waiting.sorted(), deletes: gone.sorted(), unfinished: unfinished.sorted(), later: later.sorted(),
                                keptKnownGood: kept.sorted())
    }

    /// What there is to ask about the versions `job`'s folders (`folderOf`) adopted
    /// (see adoptionQuestion), with what the person said yes to (`confirmed`, and
    /// `shown`: nil, the same) and the next backup at `upcoming` (nil: when it's
    /// scheduled after a run at `now`). None under a rule that keeps everything:
    /// nothing is deleted either way.
    static func adoptionReviews(_ job: BackupJob, _ folderOf: [String: [String: URL]], checks: [HealthRecord],
                                transferring: (URL) -> Bool, confirmed: (URL, String) -> Bool,
                                shown: ((URL, String) -> Bool)? = nil, now: Date, upcoming: Date? = nil) -> [AdoptionReview] {
        guard job.format.isSealed, job.retention != .keepAll else { return [] }
        let next = upcoming ?? job.nextBackup(lastRun: now, now: now)
        var out: [AdoptionReview] = []
        for t in job.targets {
            for lib in job.libraries {
                guard let folder = folderOf[t.id]?[lib.id],
                      let q = adoptionQuestion(shelf(lib, folder), policy: job.retention, checks: checks, transferring: transferring,
                                               upcoming: next, shown: { shown?(folder, $0) ?? confirmed(folder, $0) },
                                               confirmed: { confirmed(folder, $0) }) else { continue }
                out.append(AdoptionReview(jobID: job.id, targetID: t.id, libraryID: lib.id, destination: t.displayName,
                                          library: lib.displayName, question: q, rule: job.retention, foundAt: now))
            }
        }
        return out
    }

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

    /// Remove sealed build artifacts left in scratch by a crash or a one-time job:
    /// any `scratchBase/<job>/build/<lib>` whose artifact no pending transfer still
    /// references, in a job folder that is provably Cryoframe's (see ScratchLayout).
    /// Nothing else in `scratchBase` is touched or looked into: a scratch location
    /// chosen in Settings is the user's folder, and a 1.5 build in one carries no
    /// mark. `knownJobIDs`: the jobs Cryoframe knows, whose folders count as a job's
    /// whatever their names (every job's ID is a UUID). With `locks`, a job that is
    /// running (in this process or the scheduled agent) is skipped: its build folder
    /// is a half-written archive, not a leftover. Without them, only safe when
    /// nothing can be running.
    public static func sweepOrphanedScratch(scratchBase: URL, pendingStore: PendingTransferStore, locks: RunLocks? = nil,
                                            knownJobIDs: Set<String> = []) {
        let fm = FileManager.default
        let pending = pendingStore.all()
        let referenced = Set(pending.map(\.sourceFile))
        let known = knownJobIDs.union(pending.map(\.owningJobID))
        guard let names = try? fm.contentsOfDirectory(atPath: scratchBase.path) else { return }
        for name in names where ScratchLayout.isJobID(name, known: known) {
            let jobDir = scratchBase.appendingPathComponent(name, isDirectory: true)
            guard ScratchLayout.isOurs(jobDir, jobID: name) else { continue }
            var lease: RunLease?
            if let locks {
                guard let held = try? locks.acquire(jobID: name, trigger: .cleanup) else { continue }
                lease = held
            }
            defer { lease?.release() }
            let buildRoot = jobDir.appendingPathComponent("build", isDirectory: true)
            if ScratchLayout.isRealFolder(buildRoot) {
                for lib in (try? fm.contentsOfDirectory(atPath: buildRoot.path)) ?? [] {
                    let libDir = buildRoot.appendingPathComponent(lib, isDirectory: true)
                    guard ScratchLayout.isRealFolder(libDir) else { continue }
                    // a filtered copy (see FilteredCopy) is never referenced: a crash
                    // mid-build left it, and it holds a whole copy of the library
                    FilteredCopy.remove(in: libDir, runner: ProcessCommandRunner())
                    let artifacts = (try? fm.contentsOfDirectory(at: libDir, includingPropertiesForKeys: nil)) ?? []
                    if !artifacts.contains(where: { referenced.contains($0.path) }) { try? fm.removeItem(at: libDir) }
                }
            }
            ScratchLayout.tidy(jobDir: jobDir)
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
    private func archivePoller(total: UInt64, outputDir: URL, copyDir: URL? = nil, idx: Int, count: Int,
                               onProgress: @escaping @Sendable (RunProgress) -> Void) -> Task<Void, Never> {
        let copyFolder = (copyDir ?? outputDir).appendingPathComponent(FilteredCopy.folderName)
        return Task.detached {
            let start = Date()
            var lastBytes: UInt64 = 0
            var lastTime = start
            var rate: Double?                            // bytes/sec, EWMA-smoothed
            while !Task.isCancelled {
                // a sealed build's copy of the library without its pipes and sockets
                // (see FilteredCopy) isn't the archive: measured apart, and while it is
                // all there is, said instead of a bar that doesn't move
                let written = Self.directorySize(outputDir, skipping: FilteredCopy.folderName)
                if written == 0, FileManager.default.fileExists(atPath: copyFolder.path) {
                    onProgress(RunProgress(stage: .archiving, libraryIndex: idx, libraryCount: count, fraction: nil,
                                           detail: "Copying the folder without its named pipes and sockets",
                                           elapsed: Date().timeIntervalSince(start)))
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    continue
                }
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
        /// what a copy of the tree written out by the mirror's copier takes (see
        /// `copySize`): more than `bytes` where files are stored compressed
        var copyBytes: UInt64 = 0
    }

    /// What one file takes once copied by the mirror's copier (MirrorCopy.sync), which
    /// writes every file out whole except a sparse one, copied with its holes. A file
    /// APFS or HFS+ keeps compressed takes a fraction of its length on disk, and its
    /// copy takes all of it: measured, a 20 MB text file holding 172 KB on disk took
    /// 20 MB after `rsync -aE`. The room checks counted the 172 KB, so a library of
    /// such files passed them and then filled the drive part-way through the copy.
    static func copySize(allocated: UInt64, length: UInt64, path: String) -> UInt64 {
        guard length > allocated else { return allocated }
        var st = stat()
        if lstat(path, &st) == 0, MirrorCopy.isSparse(path, st) { return allocated }
        return (length + 4095) / 4096 * 4096
    }

    /// With `forZip`, what a sealed zip can't hold (named pipes, sockets, devices);
    /// with `forMirror`, the same, which a live mirror leaves out (see MirrorCopy.isLeftOut).
    /// With `listing`, the version's file list is gathered on the same walk (see
    /// ContentsListing): every folder, file and link, and none of what is left out.
    static func directoryStats(_ url: URL, forDMG: Bool = false, forZip: Bool = false,
                               forMirror: Bool = false, listing: ContentsListing.Collector? = nil) -> DirectoryStats {
        var out = DirectoryStats()
        var keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
                                         .totalFileSizeKey]
        if listing != nil { keys.formUnion([.isDirectoryKey, .contentModificationDateKey]) }
        let root = url.standardizedFileURL.path
        let prefix = url.path.hasSuffix("/") ? url.path : url.path + "/"
        func relative(_ u: URL) -> String {
            let p = u.path
            return p.hasPrefix(prefix) ? String(p.dropFirst(prefix.count)) : DMGBlockers.relative(p, to: root)
        }
        // a folder that can't be listed is found by inspecting it, before the walk
        // tries to go in (see DMGBlockers.inspect)
        guard FileManager.default.isReadableFile(atPath: url.path),
              let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [],
                                                     errorHandler: { _, _ in out.readable = false; return true }) else {
            out.readable = false; listing?.markPartial(); return out
        }
        // what the walk couldn't see isn't listed, so the list can't say it isn't there
        defer { if !out.readable { listing?.markPartial() } }
        var groups = DMGBlockers.Membership()
        let sealed = forDMG || forZip || forMirror
        // a mirror keeps locks (MirrorCopy.copyFlags); a sealed build may not
        let locks = forDMG || forZip
        if sealed { out.dmgBlockers.inspect(url.path, relative: url.lastPathComponent, groups: &groups, forDMG: forDMG, locks: locks) }   // copied too
        for case let u as URL in e {
            if sealed {
                out.dmgBlockers.inspect(u.path, relative: DMGBlockers.relative(u.path, to: root), groups: &groups, forDMG: forDMG, locks: locks)
            }
            guard let v = try? u.resourceValues(forKeys: keys) else { listing?.markPartial(); continue }
            if v.isSymbolicLink == true {
                out.entries += 1
                listing?.add(relative(u), size: 0, modified: v.contentModificationDate, kind: .link)
                continue
            }
            if v.isDirectory == true {
                listing?.add(relative(u), size: 0, modified: v.contentModificationDate, kind: .folder)
                continue
            }
            // named pipes, sockets and devices: in no archive, so in no list
            guard v.isRegularFile == true else { continue }
            out.entries += 1
            let allocated = UInt64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            out.bytes += allocated
            out.copyBytes += copySize(allocated: allocated, length: UInt64(max(v.totalFileSize ?? 0, 0)), path: u.path)
            listing?.add(relative(u), size: UInt64(max(v.totalFileSize ?? 0, 0)), modified: v.contentModificationDate, kind: .file)
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

    /// what the files under `url` take, less anything in its child folder `skipped`
    static func directorySize(_ url: URL, skipping skipped: String) -> UInt64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var bytes: UInt64 = 0
        for case let u as URL in e {
            if e.level == 1, u.lastPathComponent == skipped { e.skipDescendants(); continue }
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            bytes += UInt64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        return bytes
    }

    /// the room a sealed build takes on the scratch volume: the archive, which can
    /// be as big as the library, and 5% over; a filtered build (see FilteredCopy)
    /// holds a copy of the library as well. `said`: the size a refusal names.
    static func scratchRoom(_ sourceSize: UInt64, filtered: Bool) -> (needed: UInt64, said: UInt64) {
        scratchRoom(archive: sourceSize, copy: filtered ? sourceSize : nil)
    }

    /// The same, from the bytes the library takes on disk (`archive`) and what its
    /// copy takes written out (`copy`, see copySize), which a compressed library makes
    /// far more.
    static func scratchRoom(archive: UInt64, copy: UInt64?) -> (needed: UInt64, said: UInt64) {
        let said = archive + (copy ?? 0)
        return (said + archive / 20, said)
    }

    /// Why a sealed build can't be made in scratch, or nil when there is room. The
    /// copy of a filtered build is made in `copyScratch`, which for an encrypted job
    /// is the startup disk's system cache and may be another volume than `scratch`:
    /// then each is checked for its own part.
    static func scratchRefusal(archive: UInt64, copy: UInt64?, scratch: URL, copyScratch: URL) -> String? {
        let free = freeSpace(for: scratch)
        guard let copy, !sameVolume(scratch, copyScratch) else {
            let room = scratchRoom(archive: archive, copy: copy)
            guard (free ?? .max) < room.needed else { return nil }
            return "not enough space on the scratch volume: needs ~\(human(room.said)), only \(human(free ?? 0)) free"
        }
        let room = scratchRoom(archive: archive, copy: nil)
        if (free ?? .max) < room.needed {
            return "not enough space on the scratch volume: needs ~\(human(room.said)), only \(human(free ?? 0)) free"
        }
        let copyFree = freeSpace(for: copyScratch)
        if (copyFree ?? .max) < copy + copy / 20 {
            return "not enough space on the startup disk for the copy a disk image of this folder is built from (an encrypted job's copy is made there, never in the scratch location): needs ~\(human(copy)), only \(human(copyFree ?? 0)) free"
        }
        return nil
    }

    /// whether two folders (or their nearest existing parents) are on one volume
    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        func device(_ url: URL) -> dev_t? {
            var dir = url
            for _ in 0..<64 {
                var st = stat()
                if stat(dir.path, &st) == 0 { return st.st_dev }
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { return nil }
                dir = parent
            }
            return nil
        }
        guard let x = device(a), let y = device(b) else { return false }
        return x == y
    }

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
    /// `plan`: whether the build reads a copy of the library (see SealedReadPlan),
    /// made in `copyDir` and removed once it is built; `found`: what the run's walk of
    /// the library found; `copyRoomRefusal`: the room check for a copy a refused
    /// direct build falls back to.
    private func buildSealed(job: BackupJob, library: ContentType, index: Int, source: ArchiveSource,
                             sealed: SealedArchiveEngine.Sealed, plan: SealedReadPlan, found: DMGBlockers,
                             buildDir: URL, copyDir: URL, copyRoomRefusal: () -> String?, dests: [Target],
                             runner: CommandRunner, passphrase: String?,
                             listing: (ContentsListing.Collector, SymmetricKey?)? = nil,
                             onStage: @escaping @Sendable (BackupStage) -> Void) throws -> SealedBuild {
        let fm = FileManager.default
        // marked as this job's before anything goes in (see ScratchLayout)
        try ScratchLayout.claim(libraryDir: buildDir)
        FilteredCopy.remove(in: buildDir, runner: runner.forTeardown)
        FilteredCopy.remove(in: copyDir, runner: runner.forTeardown)
        try? fm.removeItem(at: buildDir)
        try fm.createDirectory(at: buildDir, withIntermediateDirectories: true)
        let (archive, notes) = try FilteredCopy.sealedArchive(
            SealedArchiveEngine(sealed, split: .none, runner: runner, passphrase: passphrase), source: source, found: found,
            plan: plan, buildDir: buildDir, copyDir: copyDir, library: library.displayName, runner: runner,
            copyRoomRefusal: copyRoomRefusal)
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
        // the version's file list, beside the archive in scratch: an encrypted job's
        // only ever sealed, so no plaintext of it is written (see ContentsListing).
        // One that can't be written leaves the version without a list, nothing more.
        let contents = listing.flatMap { ContentsListing.write($0.0, master: $0.1, encrypted: passphrase != nil, into: buildDir) }
        return SealedBuild(library: library, jobID: job.id, index: index, builtFile: file, format: archive.format,
                           byteSize: size, contentDigest: digest, verified: verified, encrypted: passphrase != nil,
                           buildDir: buildDir, dests: dests, notes: notes, contents: contents)
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
        FilteredCopy.remove(in: b.buildDir, runner: ProcessCommandRunner())
        try? FileManager.default.removeItem(at: b.buildDir)
        ScratchLayout.tidy(jobDir: b.buildDir.deletingLastPathComponent().deletingLastPathComponent())
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
