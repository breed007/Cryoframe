//
//  ContentLocator.swift
//  CryoframeKit
//
//  Resolves a descriptor's declared paths to concrete roots — on the live
//  filesystem, or inside a snapshot mount. Existence check is injectable so
//  resolution is unit-testable without touching disk.
//

import Foundation

public struct ContentLocator: Sendable {
    public let home: String
    public let user: String
    private let exists: @Sendable (String) -> Bool

    public init(home: String = NSHomeDirectory(),
                user: String = NSUserName(),
                exists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.home = home; self.user = user; self.exists = exists
    }

    /// existing roots on the live filesystem.
    public func liveRoots(of type: ContentType) -> [URL] {
        type.paths.map { $0.liveURL(home: home) }.filter { exists($0.path) }
    }

    /// existing roots inside a snapshot mounted at `mountPoint`.
    public func frozenRoots(of type: ContentType, mountPoint: String) -> [URL] {
        type.paths.map { $0.frozenURL(mountPoint: mountPoint, user: user) }.filter { exists($0.path) }
    }
}
