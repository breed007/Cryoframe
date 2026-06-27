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
                passphraseProvider: @escaping @Sendable (String) -> String? = { _ in nil }) {
        self.helper = helper; self.detector = detector; self.probe = probe; self.locator = locator
        self.scratchBase = scratchBase; self.chunkSize = chunkSize
        self.pendingStore = pendingStore; self.jobStore = jobStore; self.dataVolume = dataVolume
        self.passphraseProvider = passphraseProvider
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

    private struct SnapshotPass: Sendable {
        var results: [LibraryRunResult]
        var builds: [SealedBuild]
        var cancelled: Bool
    }

    public func run(_ job: BackupJob, ownerUID: uid_t, now: Date,
                    control: RunControl = RunControl(),
                    onStage: @escaping @Sendable (BackupStage) -> Void = { _ in },
                    onLibrary: @escaping @Sendable (String) -> Void = { _ in },
                    onProgress: @escaping @Sendable (RunProgress) -> Void = { _ in }) async throws -> JobOutcome {
        let decision = decide(job.runPolicy, libraries: job.libraries, detector: detector)
        if case .deferred(let reason) = decision { return .deferred(reason) }

        // the primary destination must be reachable — a run that can't write its first
        // copy is a real failure. Secondaries that are down degrade to partial success.
        let primaryAvail = probe.availability(of: job.target)
        guard primaryAvail.ok else {
            throw TargetError.unavailable(primaryAvail.reason ?? "\(job.target.displayName) is unavailable")
        }
        let dests: [(target: Target, available: Bool, reason: String?)] = job.targets.enumerated().map { i, t in
            if i == 0 { return (t, true, nil) }
            let a = probe.availability(of: t)
            return (t, a.ok, a.reason)
        }

        let runner = ProcessCommandRunner(control: control)
        let sealed = Self.sealedKind(job.format)
        let count = job.libraries.count
        let passphrase = job.encrypted ? passphraseProvider(job.id) : nil
        if job.encrypted, passphrase?.isEmpty ?? true { throw ArchiveError.passphraseUnavailable }

        onStage(.preparing)
        let coordinator = SnapshotCoordinator(helper: helper)
        let pass = try await coordinator.withFrozenSnapshot(of: dataVolume, ownerUID: ownerUID) { mount -> SnapshotPass in
            var results: [LibraryRunResult] = []
            var builds: [SealedBuild] = []
            var cancelled = false
            libraryLoop: for (offset, library) in job.libraries.enumerated() {
                let idx = offset + 1
                if control.isCancelled { cancelled = true; break }
                onLibrary(library.displayName)
                guard let root = self.locator.frozenRoots(of: library, mountPoint: mount.mountPoint).first else {
                    results.append(.notFound(library: library.displayName)); continue   // source problem: all destinations
                }
                let source = ArchiveSource(name: root.lastPathComponent, root: root)
                let sourceSize = Self.directorySize(root)
                onStage(.archiving)

                if let sealed {
                    // SEALED: compress once to scratch, then copy/ship to each destination
                    // after the snapshot — no recompression per destination.
                    for d in dests where !d.available {
                        results.append(.failed(library: library.displayName, destination: d.target.displayName,
                                               error: "\(d.target.displayName) is unavailable — \(d.reason ?? "not reachable")"))
                    }
                    let live = dests.filter(\.available).map(\.target)
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
                        for t in live { results.append(.failed(library: library.displayName, destination: t.displayName, error: String(describing: error))) }
                    }
                } else {
                    // LIVE MIRROR: an in-place incremental rsync per destination, from
                    // the snapshot. Cheap to repeat, so each destination is its own mirror.
                    for d in dests {
                        if control.isCancelled { cancelled = true; break libraryLoop }
                        let t = d.target
                        guard d.available else {
                            results.append(.failed(library: library.displayName, destination: t.displayName,
                                                   error: "\(t.displayName) is unavailable — \(d.reason ?? "not reachable")"))
                            continue
                        }
                        let libDir = t.destinationDir.appendingPathComponent(library.displayName, isDirectory: true)
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
                            results.append(.failed(library: library.displayName, destination: t.displayName, error: String(describing: error)))
                        }
                    }
                }
            }
            return SnapshotPass(results: results, builds: builds, cancelled: cancelled)
        }

        if pass.cancelled {
            pass.builds.forEach(cleanupBuild)
            if sealed != nil { for t in job.targets { Self.pruneVersions(target: t.destinationDir, libraries: job.libraries, policy: job.retention) } }
            return .cancelled
        }
        var results = pass.results

        // choose a version-folder name that doesn't collide with an existing one — two
        // runs of the same job in the same second would otherwise overwrite. Bump by
        // whole seconds so the name stays a parseable timestamp.
        var versionDate = now
        if !pass.builds.isEmpty {
            let probeLib = job.libraries.first?.displayName ?? "Library"
            let primaryLibDir = job.target.destinationDir.appendingPathComponent(probeLib, isDirectory: true)
            while FileManager.default.fileExists(atPath: primaryLibDir.appendingPathComponent(VersionStamp.string(versionDate)).path) {
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
                let destDir = dest.destinationDir.appendingPathComponent(build.library.displayName, isDirectory: true)
                    .appendingPathComponent(versionStamp, isDirectory: true)
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
                    results.append(.failed(library: build.library.displayName, destination: dest.displayName, error: String(describing: error)))
                }
            }
            if !keepBuild { cleanupBuild(build) }
        }

        if sealed != nil {      // prune old sealed versions per the retention policy, per destination
            for t in job.targets { Self.pruneVersions(target: t.destinationDir, libraries: job.libraries, policy: job.retention) }
        }
        onStage(.completed)
        jobStore?.recordRun(id: job.id, at: now)
        return .finished(results: results, warning: decision.warning)
    }

    /// sweep empty/partial sealed-version folders left by failed or cancelled runs,
    /// then delete completed versions the retention policy doesn't keep. Only version
    /// folders with a manifest count as real versions — otherwise a failed run's empty
    /// husk could occupy a "keep" slot and evict a good archive.
    static func pruneVersions(target: URL, libraries: [ContentType], policy: RetentionPolicy) {
        let fm = FileManager.default
        for library in libraries {
            let libDir = target.appendingPathComponent(library.displayName, isDirectory: true)
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
            let prune = retentionPrune(complete.map(\.date), policy: policy)
            for v in complete where prune.contains(v.date) { try? fm.removeItem(at: v.url) }
        }
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
    /// references. Safe to call at launch, before any run starts.
    public static func sweepOrphanedScratch(scratchBase: URL, pendingStore: PendingTransferStore) {
        let fm = FileManager.default
        let referenced = Set(pendingStore.all().map(\.sourceFile))
        guard let jobDirs = try? fm.contentsOfDirectory(at: scratchBase, includingPropertiesForKeys: nil) else { return }
        for jobDir in jobDirs {
            let buildRoot = jobDir.appendingPathComponent("build", isDirectory: true)
            guard let libDirs = try? fm.contentsOfDirectory(at: buildRoot, includingPropertiesForKeys: nil) else { continue }
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
    static func freeSpace(for url: URL) -> UInt64? {
        var dir = url
        for _ in 0..<8 {
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
                let fraction = total > 0 ? min(0.99, Double(written) / Double(total)) : nil
                onProgress(RunProgress(stage: .archiving, libraryIndex: idx, libraryCount: count, fraction: fraction,
                                       detail: total > 0 ? "\(Self.human(written)) of \(Self.human(total))" : Self.human(written),
                                       speed: rate, eta: eta, elapsed: now.timeIntervalSince(start)))
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
        }
    }

    static func directorySize(_ url: URL) -> UInt64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: UInt64 = 0
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
            total += UInt64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        return total
    }

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
        let archive = try EngineFactory.engine(for: job.format, target: target, runner: runner,
                                               passphrase: passphrase).archive(source, to: dest)
        onStage(.checksumming)
        try ArchiveManifest.write(try ArchiveManifest.build(for: archive, encrypted: passphrase != nil), toDir: dest)
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
