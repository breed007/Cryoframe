//
//  ArchiveEngine.swift
//  CryoframeKit
//
//  Produces an archive from a (frozen) source tree. Two families:
//    - sealed   : immutable, checksummed cold storage — read-only UDZO dmg or
//                 zip, optionally split into sub-ceiling volumes for cloud sync.
//    - live mirror: incremental working backup — APFS sparsebundle (~8MB bands,
//                 only changed bands rewrite, the mechanism Time Machine uses).
//
//  Engines are agnostic to whether `root` is inside a snapshot mount or a plain
//  directory, which makes them testable with tiny fixtures and no root.
//  Command construction is factored into pure planners (ArchivePlan) so argv is
//  unit-tested without invoking hdiutil/ditto.
//

import Foundation

public struct ArchiveSource: Sendable, Equatable {
    public let name: String        // base name for the artifact
    public let root: URL           // directory to archive (e.g. the frozen .photoslibrary)
    public init(name: String, root: URL) { self.name = name; self.root = root }
}

public enum ArchiveFormat: String, Sendable, Equatable, Codable {
    case sealedDMG, sealedZip, liveMirror
}

public enum SplitPolicy: Sendable, Equatable {
    case none
    case maxBytes(UInt64)
    /// stay under the OneDrive/cloud single-file ceiling (250 GB). 240 GB volumes.
    public static let cloudCeiling = SplitPolicy.maxBytes(240 * 1_000_000_000)
}

public struct ArchiveResult: Sendable, Equatable {
    public let artifacts: [URL]    // one file, or split volumes
    public let format: ArchiveFormat
    public init(artifacts: [URL], format: ArchiveFormat) {
        self.artifacts = artifacts; self.format = format
    }
}

public protocol ArchiveEngine: Sendable {
    func archive(_ source: ArchiveSource, to destinationDir: URL) throws -> ArchiveResult
}

public enum ArchiveError: Error, Equatable {
    case toolFailed(tool: String, status: Int32, stderr: String)
    case noArtifactProduced(URL)
    case sourceMissing(String)
    case passphraseUnavailable      // job is encrypted but no key was found in the Keychain
}

public struct Command: Sendable, Equatable {
    public let tool: String
    public let args: [String]
    public init(_ tool: String, _ args: [String]) { self.tool = tool; self.args = args }
}

/// Pure command construction — no side effects, fully unit-testable.
public enum ArchivePlan {
    /// read-only compressed dmg. (hdiutil -segmentSize is deprecated and ignored
    /// for -srcfolder, so splitting is done post-hoc with split(1) — see ArchivePlan.split.)
    public static func dmg(root: URL, output: URL, encrypted: Bool = false) -> Command {
        var args = ["create", "-srcfolder", root.path, "-format", "UDZO"]
        if encrypted { args += ["-encryption", "AES-256", "-stdinpass"] }   // passphrase via stdin
        args += ["-ov", output.path]
        return Command("/usr/bin/hdiutil", args)
    }

    /// ditto preserves ACLs / resource forks / xattrs — a plain zip would not.
    public static func zip(root: URL, output: URL) -> Command {
        Command("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", root.path, output.path])
    }

    /// post-hoc split of a finished file into <cap>-byte parts (for the zip path).
    public static func split(file: URL, cap: UInt64, prefix: String) -> Command {
        Command("/usr/bin/split", ["-b", "\(cap)", file.path, prefix])
    }

    public static func sparseBundleCreate(output: URL, name: String, sizeGB: Int, bandSectors: Int,
                                          encrypted: Bool = false) -> Command {
        var args = ["create", "-type", "SPARSEBUNDLE", "-fs", "APFS",
                    "-size", "\(sizeGB)g", "-volname", name,
                    "-imagekey", "sparse-band-size=\(bandSectors)"]
        if encrypted { args += ["-encryption", "AES-256", "-stdinpass"] }
        args += [output.path]
        return Command("/usr/bin/hdiutil", args)
    }

    /// attach a sparsebundle or dmg at a known mountpoint. `readonly` for
    /// verification mounts; read-write for the live-mirror rsync. `encrypted` adds
    /// `-stdinpass` so the passphrase is read from stdin.
    public static func attach(image: URL, mountpoint: URL, readonly: Bool = false, encrypted: Bool = false) -> Command {
        var args = ["attach", image.path, "-mountpoint", mountpoint.path, "-nobrowse", "-owners", "on"]
        if readonly { args.append("-readonly") }
        if encrypted { args.append("-stdinpass") }
        return Command("/usr/bin/hdiutil", args)
    }

    public static func detach(mountpoint: URL) -> Command {
        Command("/usr/bin/hdiutil", ["detach", mountpoint.path])
    }

    /// incremental sync into the attached mirror; --delete prunes removed files,
    /// --partial keeps partially-transferred files so a dropped run resumes them,
    /// and the sparsebundle only rewrites the ~8MB bands that actually changed.
    public static func rsync(root: URL, into destination: URL) -> Command {
        Command("/usr/bin/rsync", ["-a", "--delete", "--partial", root.path + "/", destination.path + "/"])
    }
}
