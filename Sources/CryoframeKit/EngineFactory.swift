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
    /// `sizeGB` is what a job saved before 1.6 chose. It is kept so those jobs (and an
    /// older app reading a newer job) still decode, and is otherwise ignored: the image
    /// is sized from its destination (see MirrorSizing).
    case liveMirror(sizeGB: Int)

    /// what a new mirror job records as its size, for the benefit of older versions
    public static let legacyMirrorGB = 500

    /// sealed formats are versioned into timestamped folders; a live mirror is a single
    /// in-place copy. Two sealed jobs to the same (target, library) share version folders
    /// and would cross-prune each other.
    public var isSealed: Bool { if case .liveMirror = self { return false }; return true }
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
        case .liveMirror:
            guard target.constraints.supportsIncremental else {
                throw TargetError.incrementalUnsupported(target.displayName)
            }
            return SparseBundleMirrorEngine(sizing: .fromDestination, runner: runner, passphrase: passphrase)
        }
    }
}
