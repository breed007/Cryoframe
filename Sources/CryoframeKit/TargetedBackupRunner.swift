//
//  TargetedBackupRunner.swift
//  CryoframeKit
//
//  Ties targets to the backup pipeline: preflight the target, build the right
//  engine for the chosen format honouring the target's constraints (cloud cap →
//  split; non-incremental target → reject live mirror), then run.
//

import Foundation
import CryoframeShared

public enum FormatChoice: Sendable, Equatable, Codable {
    case sealedDMG
    case sealedZip
    case liveMirror(sizeGB: Int)
}

public enum TargetError: Error, Equatable {
    case unavailable(String)
    case incrementalUnsupported(String)
}

/// builds an ArchiveEngine for a (format, target) pair, applying target constraints.
public enum EngineFactory {
    public static func engine(for choice: FormatChoice, target: Target,
                              runner: CommandRunner = ProcessCommandRunner()) throws -> ArchiveEngine {
        switch choice {
        case .sealedDMG:
            return SealedArchiveEngine(.dmg, split: target.constraints.splitPolicy, runner: runner)
        case .sealedZip:
            return SealedArchiveEngine(.zip, split: target.constraints.splitPolicy, runner: runner)
        case .liveMirror(let sizeGB):
            guard target.constraints.supportsIncremental else {
                throw TargetError.incrementalUnsupported(target.displayName)
            }
            return SparseBundleMirrorEngine(sizeGB: sizeGB, runner: runner)
        }
    }
}

public struct TargetedBackupRunner: Sendable {
    let backup: BackupRunner
    let probe: TargetProbe
    let engineProvider: @Sendable (FormatChoice, Target) throws -> ArchiveEngine
    let scratchBase: URL
    let chunkSize: UInt64
    let pendingStore: PendingTransferStore?

    public init(backup: BackupRunner,
                probe: TargetProbe = FileSystemTargetProbe(),
                engineProvider: @escaping @Sendable (FormatChoice, Target) throws -> ArchiveEngine
                    = { try EngineFactory.engine(for: $0, target: $1) },
                scratchBase: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("app.cryoframe/scratch", isDirectory: true),
                chunkSize: UInt64 = 2 * 1_000_000_000,
                pendingStore: PendingTransferStore? = nil) {
        self.backup = backup; self.probe = probe; self.engineProvider = engineProvider
        self.scratchBase = scratchBase; self.chunkSize = chunkSize; self.pendingStore = pendingStore
    }

    /// preflight → run. For a fragile target (network/external) and a sealed
    /// format, stages the archive locally and ships it in resumable parts;
    /// otherwise writes directly. Throws before touching the snapshot if the
    /// target is unavailable, so an unmounted drive never starts a run.
    @discardableResult
    public func run(_ type: ContentType,
                    format: FormatChoice,
                    to target: Target,
                    ownerUID: uid_t,
                    verification: VerificationPolicy = .checksumOnly,
                    onStage: @escaping @Sendable (BackupStage) -> Void = { _ in },
                    id: String = UUID().uuidString) async throws -> BackupOutcome {
        let availability = probe.availability(of: target)
        guard availability.ok else {
            throw TargetError.unavailable(availability.reason ?? "\(target.displayName) is unavailable")
        }

        if target.constraints.resumableTransfer, let sealed = Self.sealedKind(format) {
            return try await stagedRun(id: id, type: type, sealed: sealed, target: target,
                                       ownerUID: ownerUID, verification: verification, onStage: onStage)
        }

        let engine = try engineProvider(format, target)
        return try await backup.run(type, engine: engine, to: target.destinationDir,
                                    ownerUID: ownerUID, verification: verification, onStage: onStage)
    }

    // MARK: staged + resumable

    private static func sealedKind(_ format: FormatChoice) -> SealedArchiveEngine.Sealed? {
        switch format {
        case .sealedDMG: return .dmg
        case .sealedZip: return .zip
        case .liveMirror: return nil          // the mirror handles disconnects itself
        }
    }

    private func stagedRun(id: String, type: ContentType, sealed: SealedArchiveEngine.Sealed,
                           target: Target, ownerUID: uid_t, verification: VerificationPolicy,
                           onStage: @escaping @Sendable (BackupStage) -> Void) async throws -> BackupOutcome {
        let fm = FileManager.default
        let scratchDir = scratchBase.appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: scratchDir, withIntermediateDirectories: true)

        // build one archive locally (snapshot released here); strong verify can run
        // on the single file with no reassembly.
        let staged = try await backup.run(type, engine: SealedArchiveEngine(sealed, split: .none),
                                          to: scratchDir, ownerUID: ownerUID,
                                          verification: verification, onStage: onStage)
        guard let archive = staged.result.artifacts.first,
              let size = (try? fm.attributesOfItem(atPath: archive.path)[.size]) as? UInt64 else {
            throw ArchiveError.noArtifactProduced(scratchDir)
        }

        onStage(.transferring)
        let pending = PendingTransfer(jobID: id, sourceFile: archive.path, baseName: archive.lastPathComponent,
                                      totalBytes: size, chunkSize: chunkSize,
                                      targetDir: target.destinationDir.path, format: staged.result.format)
        let store = pendingStore
        store?.save(pending)
        let manifest = try ChunkedShipper().ship(pending, persist: { store?.save($0) })

        try? fm.removeItem(at: scratchDir)
        store?.remove(jobID: id)
        onStage(.completed)

        let targetDir = target.destinationDir
        return BackupOutcome(
            result: ArchiveResult(artifacts: manifest.artifacts.map { targetDir.appendingPathComponent($0.name) },
                                  format: staged.result.format),
            manifestURL: targetDir.appendingPathComponent(ArchiveManifest.sidecarName),
            strong: staged.strong)
    }
}
