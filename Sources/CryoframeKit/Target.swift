//
//  Target.swift
//  CryoframeKit
//
//  Where archives land. A target abstracts local volume / network share /
//  cloud-sync folder, each declaring its own constraints: a single-file size
//  cap (cloud ceiling → split sealed archives) and whether it supports an
//  incremental live mirror.
//

import Foundation

public enum TargetKind: String, Codable, Sendable {
    case local, networkShare, cloudSync
}

/// how to reach a network share (used by preflight; root auto-mount is a later refinement).
public struct NetworkMountSpec: Sendable, Equatable, Codable {
    public let url: URL          // smb://host/share
    public let mountpoint: String
    public init(url: URL, mountpoint: String) { self.url = url; self.mountpoint = mountpoint }
}

public struct TargetConstraints: Sendable, Equatable, Codable {
    /// single-file ceiling — sealed archives larger than this are split into volumes.
    public let maxSingleFileBytes: UInt64?
    /// whether a sparsebundle live mirror is allowed here.
    public let supportsIncremental: Bool
    /// fragile link (network share, external drive): stage the sealed archive
    /// locally and ship it in resumable parts instead of writing it in place.
    public let resumableTransfer: Bool

    public init(maxSingleFileBytes: UInt64? = nil, supportsIncremental: Bool = true,
                resumableTransfer: Bool = false) {
        self.maxSingleFileBytes = maxSingleFileBytes
        self.supportsIncremental = supportsIncremental
        self.resumableTransfer = resumableTransfer
    }

    /// the split policy a sealed archive should use for this target.
    public var splitPolicy: SplitPolicy {
        maxSingleFileBytes.map { .maxBytes($0) } ?? .none
    }
}

public struct Target: Sendable, Identifiable, Equatable, Codable {
    public let id: String
    public let displayName: String
    public let kind: TargetKind
    public let destinationDir: URL
    public let constraints: TargetConstraints
    public let networkMount: NetworkMountSpec?

    public init(id: String, displayName: String, kind: TargetKind, destinationDir: URL,
                constraints: TargetConstraints, networkMount: NetworkMountSpec? = nil) {
        self.id = id; self.displayName = displayName; self.kind = kind
        self.destinationDir = destinationDir; self.constraints = constraints; self.networkMount = networkMount
    }
}

public extension Target {
    /// local disk — no size cap, incremental fine.
    static func localVolume(id: String, name: String, dir: URL) -> Target {
        Target(id: id, displayName: name, kind: .local, destinationDir: dir,
               constraints: TargetConstraints(maxSingleFileBytes: nil, supportsIncremental: true))
    }

    /// cloud-sync folder (OneDrive/iCloud) — 240 GB single-file ceiling, so sealed
    /// archives split into sub-250 GB volumes. sparsebundle bands are small, so
    /// incremental mirroring is still fine.
    static func cloudSyncFolder(id: String, name: String, dir: URL) -> Target {
        Target(id: id, displayName: name, kind: .cloudSync, destinationDir: dir,
               constraints: TargetConstraints(maxSingleFileBytes: 240 * 1_000_000_000, supportsIncremental: true))
    }

    /// network share — must be mounted before a run (preflight enforces this).
    /// Fragile link, so sealed archives ship as resumable parts.
    static func networkShare(id: String, name: String, dir: URL, mount: NetworkMountSpec,
                             supportsIncremental: Bool = true) -> Target {
        Target(id: id, displayName: name, kind: .networkShare, destinationDir: dir,
               constraints: TargetConstraints(maxSingleFileBytes: nil, supportsIncremental: supportsIncremental,
                                              resumableTransfer: true),
               networkMount: mount)
    }

    /// a removable/external drive — a local mount path that can vanish, so sealed
    /// archives ship as resumable parts (and preflight catches it if unplugged).
    static func externalDrive(id: String, name: String, dir: URL) -> Target {
        Target(id: id, displayName: name, kind: .local, destinationDir: dir,
               constraints: TargetConstraints(resumableTransfer: true))
    }
}
