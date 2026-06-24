//
//  VerificationManifest.swift
//  CryoframeKit
//
//  The checksum manifest written beside every archive ("checksum always"). It's
//  the source of truth for periodic re-verification of cold archives.
//

import Foundation

public struct ArtifactDigest: Codable, Sendable, Equatable {
    public let name: String      // artifact filename (relative to the archive dir)
    public let size: UInt64
    public let sha256: String
}

public struct VerificationManifest: Codable, Sendable, Equatable {
    public let format: ArchiveFormat
    public let artifacts: [ArtifactDigest]
}

public enum ArchiveManifest {
    public static let sidecarName = "cryoframe-manifest.json"

    /// hash every artifact and build the manifest.
    public static func build(for result: ArchiveResult) throws -> VerificationManifest {
        let digests = try result.artifacts.map { url -> ArtifactDigest in
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
            return ArtifactDigest(name: url.lastPathComponent, size: size, sha256: try Checksum.sha256(of: url))
        }
        return VerificationManifest(format: result.format, artifacts: digests)
    }

    @discardableResult
    public static func write(_ manifest: VerificationManifest, toDir dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(sidecarName)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: url, options: .atomic)
        return url
    }

    public static func read(_ url: URL) throws -> VerificationManifest {
        try JSONDecoder().decode(VerificationManifest.self, from: Data(contentsOf: url))
    }
}
