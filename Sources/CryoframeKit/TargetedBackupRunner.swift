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

    public init(backup: BackupRunner,
                probe: TargetProbe = FileSystemTargetProbe(),
                engineProvider: @escaping @Sendable (FormatChoice, Target) throws -> ArchiveEngine
                    = { try EngineFactory.engine(for: $0, target: $1) }) {
        self.backup = backup; self.probe = probe; self.engineProvider = engineProvider
    }

    /// preflight → build engine → run. Throws before touching the snapshot if the
    /// target is unavailable, so an unmounted drive never starts a run.
    @discardableResult
    public func run(_ type: ContentType,
                    format: FormatChoice,
                    to target: Target,
                    ownerUID: uid_t,
                    verification: VerificationPolicy = .checksumOnly,
                    onStage: @escaping @Sendable (BackupStage) -> Void = { _ in }) async throws -> BackupOutcome {
        let availability = probe.availability(of: target)
        guard availability.ok else {
            throw TargetError.unavailable(availability.reason ?? "\(target.displayName) is unavailable")
        }
        let engine = try engineProvider(format, target)
        return try await backup.run(type, engine: engine, to: target.destinationDir,
                                    ownerUID: ownerUID, verification: verification, onStage: onStage)
    }
}
