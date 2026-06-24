//
//  ProcessDetector.swift
//  CryoframeKit
//
//  Detects whether a content type's owning app is running. The snapshot makes
//  quiescing largely unnecessary, so this drives a warn/defer hint (M6), not a
//  hard block. Real impl (NSWorkspace) lives app-side to keep Kit AppKit-free.
//

import Foundation

public protocol ProcessDetector: Sendable {
    func isRunning(_ owner: OwningProcess) -> Bool
}

/// test double — owning apps considered running are those whose bundle id or
/// executable name is in the provided sets.
public struct FakeProcessDetector: ProcessDetector {
    public var runningBundleIDs: Set<String>
    public var runningExecutables: Set<String>
    public init(runningBundleIDs: Set<String> = [], runningExecutables: Set<String> = []) {
        self.runningBundleIDs = runningBundleIDs
        self.runningExecutables = runningExecutables
    }
    public func isRunning(_ owner: OwningProcess) -> Bool {
        if let b = owner.bundleIdentifier, runningBundleIDs.contains(b) { return true }
        if let e = owner.executableName, runningExecutables.contains(e) { return true }
        return false
    }
}
