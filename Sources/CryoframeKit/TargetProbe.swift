//
//  TargetProbe.swift
//  CryoframeKit
//
//  Availability preflight — don't start a run against an unmounted drive or an
//  unwritable destination.
//

import Foundation

public struct TargetAvailability: Sendable, Equatable {
    public let reachable: Bool
    public let writable: Bool
    public let reason: String?
    public var ok: Bool { reachable && writable }
    public init(reachable: Bool, writable: Bool, reason: String? = nil) {
        self.reachable = reachable; self.writable = writable; self.reason = reason
    }
}

public protocol TargetProbe: Sendable {
    func availability(of target: Target) -> TargetAvailability
}

public struct FileSystemTargetProbe: TargetProbe {
    public init() {}

    public func availability(of target: Target) -> TargetAvailability {
        let fm = FileManager.default

        // a network share must actually be mounted.
        if target.kind == .networkShare, let mp = target.networkMount?.mountpoint {
            if !fm.fileExists(atPath: mp) {
                return TargetAvailability(reachable: false, writable: false,
                                          reason: "share not mounted at \(mp)")
            }
        }

        // the destination (or its parent, if it doesn't exist yet) must be a
        // writable directory we can reach.
        let dir = target.destinationDir
        let base = fm.fileExists(atPath: dir.path) ? dir : dir.deletingLastPathComponent()
        guard fm.fileExists(atPath: base.path) else {
            return TargetAvailability(reachable: false, writable: false,
                                      reason: "destination not reachable: \(base.path)")
        }
        let writable = fm.isWritableFile(atPath: base.path)
        return TargetAvailability(reachable: true, writable: writable,
                                  reason: writable ? nil : "destination not writable: \(base.path)")
    }
}

public struct FakeTargetProbe: TargetProbe {
    public let result: TargetAvailability
    public init(_ result: TargetAvailability) { self.result = result }
    public func availability(of target: Target) -> TargetAvailability { result }
}
