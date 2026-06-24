//
//  BackupRunner.swift
//  CryoframeKit
//
//  Ties M1+M2+M3 into one backup run: freeze the Data volume (helper), locate
//  the content type's library inside the snapshot (locator), archive it from the
//  frozen mount (engine), then tear down. All archiving runs against the
//  read-only snapshot — never the live library.
//

import Foundation
import CryoframeShared

public enum BackupError: Error, Equatable {
    case libraryNotFoundInSnapshot(String)
}

public enum VerificationPolicy: String, Codable, Sendable {
    case checksumOnly      // manifest written (always); cheap
    case mountAndOpen      // also mount the archive and confirm the library reopens
}

public struct BackupOutcome: Sendable {
    public let result: ArchiveResult
    public let manifestURL: URL
    public let strong: VerificationReport?   // present iff policy == .mountAndOpen
}

/// coarse phase progress for the UI (the engines run synchronously).
public enum BackupStage: String, Sendable {
    case preparing, archiving, checksumming, verifying, completed
}

public struct BackupRunner: Sendable {
    let helper: PrivilegedHelper
    let locator: ContentLocator
    let dataVolume: VolumeRef

    public init(helper: PrivilegedHelper,
                locator: ContentLocator = ContentLocator(),
                dataVolume: VolumeRef = VolumeRef(mountPoint: "/System/Volumes/Data", bsdDevice: "")) {
        self.helper = helper; self.locator = locator; self.dataVolume = dataVolume
    }

    /// freeze → locate → archive (snapshot torn down) → seal a checksum manifest
    /// → optionally mount-and-open verify. Verification runs after teardown since
    /// the artifact is independent of the snapshot.
    @discardableResult
    public func run(_ type: ContentType,
                    engine: ArchiveEngine,
                    to destinationDir: URL,
                    ownerUID: uid_t,
                    verification: VerificationPolicy = .checksumOnly,
                    onStage: @escaping @Sendable (BackupStage) -> Void = { _ in }) async throws -> BackupOutcome {
        let coordinator = SnapshotCoordinator(helper: helper)
        let locator = self.locator

        onStage(.preparing)
        let result = try await coordinator.withFrozenSnapshot(of: dataVolume, ownerUID: ownerUID) { mount in
            guard let root = locator.frozenRoots(of: type, mountPoint: mount.mountPoint).first else {
                throw BackupError.libraryNotFoundInSnapshot(type.displayName)
            }
            onStage(.archiving)
            return try engine.archive(ArchiveSource(name: root.lastPathComponent, root: root), to: destinationDir)
        }

        // checksum always.
        onStage(.checksumming)
        let manifest = try ArchiveManifest.build(for: result)
        let manifestURL = try ArchiveManifest.write(manifest, toDir: destinationDir)

        var strong: VerificationReport?
        if verification == .mountAndOpen {
            onStage(.verifying)
            strong = try StrongVerifier().verify(result, type: type)
        }
        onStage(.completed)
        return BackupOutcome(result: result, manifestURL: manifestURL, strong: strong)
    }
}
