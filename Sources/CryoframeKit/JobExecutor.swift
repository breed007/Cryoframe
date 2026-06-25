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
    case completed(library: String, parts: Int, verified: Bool?)
    case notFound(library: String)
    case failed(library: String, error: String)
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
                dataVolume: VolumeRef = VolumeRef(mountPoint: "/System/Volumes/Data", bsdDevice: "")) {
        self.helper = helper; self.detector = detector; self.probe = probe; self.locator = locator
        self.scratchBase = scratchBase; self.chunkSize = chunkSize
        self.pendingStore = pendingStore; self.jobStore = jobStore; self.dataVolume = dataVolume
    }

    private struct Staged: Sendable {
        let library: ContentType
        let index: Int
        let pending: PendingTransfer
        let scratchDir: URL
        let verified: Bool?
    }

    private struct SnapshotPass: Sendable {
        var results: [LibraryRunResult]
        var staged: [Staged]
        var cancelled: Bool
    }

    public func run(_ job: BackupJob, ownerUID: uid_t, now: Date,
                    control: RunControl = RunControl(),
                    onStage: @escaping @Sendable (BackupStage) -> Void = { _ in },
                    onLibrary: @escaping @Sendable (String) -> Void = { _ in },
                    onProgress: @escaping @Sendable (RunProgress) -> Void = { _ in }) async throws -> JobOutcome {
        let decision = decide(job.runPolicy, libraries: job.libraries, detector: detector)
        if case .deferred(let reason) = decision { return .deferred(reason) }

        let availability = probe.availability(of: job.target)
        guard availability.ok else {
            throw TargetError.unavailable(availability.reason ?? "\(job.target.displayName) is unavailable")
        }

        let runner = ProcessCommandRunner(control: control)
        let sealed = Self.sealedKind(job.format)
        let targetBase = job.target.destinationDir
        let count = job.libraries.count

        onStage(.preparing)
        let coordinator = SnapshotCoordinator(helper: helper)
        let pass = try await coordinator.withFrozenSnapshot(of: dataVolume, ownerUID: ownerUID) { mount -> SnapshotPass in
            var results: [LibraryRunResult] = []
            var staged: [Staged] = []
            var cancelled = false
            for (offset, library) in job.libraries.enumerated() {
                let idx = offset + 1
                if control.isCancelled { cancelled = true; break }
                onLibrary(library.displayName)
                let dest = targetBase.appendingPathComponent(library.displayName, isDirectory: true)
                guard let root = self.locator.frozenRoots(of: library, mountPoint: mount.mountPoint).first else {
                    results.append(.notFound(library: library.displayName)); continue
                }
                let source = ArchiveSource(name: root.lastPathComponent, root: root)
                onStage(.archiving)
                let isStaged = job.target.constraints.resumableTransfer && sealed != nil
                let outputDir = isStaged
                    ? self.scratchBase.appendingPathComponent("\(job.id)/\(Self.safe(library.id))", isDirectory: true)
                    : dest
                let poller = self.archivePoller(root: root, outputDir: outputDir, idx: idx, count: count, onProgress: onProgress)
                do {
                    if isStaged, let sealed {
                        staged.append(try self.stage(job: job, library: library, index: idx, source: source,
                                                     sealed: sealed, dest: dest, runner: runner, onStage: onStage))
                    } else {
                        results.append(try self.direct(job: job, library: library, source: source,
                                                       dest: dest, runner: runner, onStage: onStage))
                    }
                    poller.cancel()
                } catch is CancelledError {
                    poller.cancel(); cancelled = true; break
                } catch {
                    poller.cancel()
                    results.append(.failed(library: library.displayName, error: String(describing: error)))
                }
            }
            return SnapshotPass(results: results, staged: staged, cancelled: cancelled)
        }

        if pass.cancelled {
            pass.staged.forEach(cleanup)
            return .cancelled
        }
        var results = pass.results

        // ship staged libraries (the snapshot is already released)
        for item in pass.staged {
            if control.isCancelled { pass.staged.forEach(cleanup); return .cancelled }
            onStage(.transferring)
            do {
                let manifest = try ChunkedShipper().ship(
                    item.pending,
                    persist: { pendingStore?.save($0) },
                    control: control,
                    onPart: { done, total in
                        onProgress(RunProgress(stage: .transferring, libraryIndex: item.index, libraryCount: count,
                                               fraction: total > 0 ? Double(done) / Double(total) : nil,
                                               detail: "part \(done) of \(total)"))
                    })
                try? FileManager.default.removeItem(at: item.scratchDir)
                pendingStore?.remove(jobID: item.pending.jobID)
                results.append(.completed(library: item.library.displayName, parts: manifest.artifacts.count, verified: item.verified))
            } catch is CancelledError {
                pass.staged.forEach(cleanup); return .cancelled
            } catch {
                results.append(.failed(library: item.library.displayName, error: String(describing: error)))
            }
        }

        onStage(.completed)
        jobStore?.recordRun(id: job.id, at: now)
        return .finished(results: results, warning: decision.warning)
    }

    // MARK: progress

    /// polls the output directory's size against the source library size while an
    /// archive runs, so the UI shows a moving bytes-written bar.
    private func archivePoller(root: URL, outputDir: URL, idx: Int, count: Int,
                               onProgress: @escaping @Sendable (RunProgress) -> Void) -> Task<Void, Never> {
        Task.detached {
            let total = Self.directorySize(root)        // computed off the archive's thread
            while !Task.isCancelled {
                let written = Self.directorySize(outputDir)
                let fraction = total > 0 ? min(0.99, Double(written) / Double(total)) : nil
                onProgress(RunProgress(stage: .archiving, libraryIndex: idx, libraryCount: count, fraction: fraction,
                                       detail: total > 0 ? "\(Self.human(written)) of \(Self.human(total))" : Self.human(written)))
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

    private func stage(job: BackupJob, library: ContentType, index: Int, source: ArchiveSource,
                       sealed: SealedArchiveEngine.Sealed, dest: URL, runner: CommandRunner,
                       onStage: @escaping @Sendable (BackupStage) -> Void) throws -> Staged {
        let fm = FileManager.default
        let scratchDir = scratchBase.appendingPathComponent("\(job.id)/\(Self.safe(library.id))", isDirectory: true)
        try fm.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        let archive = try SealedArchiveEngine(sealed, split: .none, runner: runner).archive(source, to: scratchDir)
        guard let file = archive.artifacts.first,
              let size = (try? fm.attributesOfItem(atPath: file.path)[.size]) as? UInt64 else {
            throw ArchiveError.noArtifactProduced(scratchDir)
        }
        var verified: Bool?
        if job.verification == .mountAndOpen {
            onStage(.verifying)
            verified = try StrongVerifier(runner: runner).verify(archive, type: library).passed
        }
        let pending = PendingTransfer(jobID: "\(job.id):\(library.id)", sourceFile: file.path,
                                      baseName: file.lastPathComponent, totalBytes: size,
                                      chunkSize: chunkSize, targetDir: dest.path, format: archive.format)
        pendingStore?.save(pending)
        return Staged(library: library, index: index, pending: pending, scratchDir: scratchDir, verified: verified)
    }

    private func direct(job: BackupJob, library: ContentType, source: ArchiveSource, dest: URL,
                        runner: CommandRunner, onStage: @escaping @Sendable (BackupStage) -> Void) throws -> LibraryRunResult {
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let archive = try EngineFactory.engine(for: job.format, target: job.target, runner: runner).archive(source, to: dest)
        onStage(.checksumming)
        try ArchiveManifest.write(try ArchiveManifest.build(for: archive), toDir: dest)
        var verified: Bool?
        if job.verification == .mountAndOpen {
            onStage(.verifying)
            verified = try StrongVerifier(runner: runner).verify(archive, type: library).passed
        }
        return .completed(library: library.displayName, parts: archive.artifacts.count, verified: verified)
    }

    private func cleanup(_ s: Staged) {
        try? FileManager.default.removeItem(at: s.scratchDir)
        pendingStore?.remove(jobID: s.pending.jobID)
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
