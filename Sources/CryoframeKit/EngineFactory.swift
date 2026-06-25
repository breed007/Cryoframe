//
//  EngineFactory.swift
//  CryoframeKit
//
//  The output-format choice and how it maps to an ArchiveEngine for a given
//  target, honouring the target's constraints (cloud cap → split; non-incremental
//  target → reject live mirror). JobExecutor drives the run itself.
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
    /// `passphrase` (non-nil) turns on AES-256 for the hdiutil formats — sealed DMG
    /// and live mirror. Sealed zip can't be strongly encrypted, so it ignores it.
    public static func engine(for choice: FormatChoice, target: Target,
                              runner: CommandRunner = ProcessCommandRunner(),
                              passphrase: String? = nil) throws -> ArchiveEngine {
        switch choice {
        case .sealedDMG:
            return SealedArchiveEngine(.dmg, split: target.constraints.splitPolicy, runner: runner, passphrase: passphrase)
        case .sealedZip:
            return SealedArchiveEngine(.zip, split: target.constraints.splitPolicy, runner: runner)
        case .liveMirror(let sizeGB):
            guard target.constraints.supportsIncremental else {
                throw TargetError.incrementalUnsupported(target.displayName)
            }
            return SparseBundleMirrorEngine(sizeGB: sizeGB, runner: runner, passphrase: passphrase)
        }
    }
}
