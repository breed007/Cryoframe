//
//  ContentTypeRegistry.swift
//  CryoframeKit
//
//  The set of content types Cryoframe knows about: built-ins plus any
//  user-added generic folders. Lookup by id; add replaces by id.
//

import Foundation

public struct ContentTypeRegistry: Sendable {
    public private(set) var types: [ContentType]

    public init(_ types: [ContentType] = ContentTypeRegistry.builtIns) {
        self.types = types
    }

    public static let builtIns: [ContentType] = [.photos, .appleMusic, .iMovie, .garageBand, .messages, .mail, .outlook]

    public func type(id: String) -> ContentType? {
        types.first { $0.id == id }
    }

    /// built-ins with per-id path overrides applied (a moved library, a library
    /// on an external drive). Ids without an override keep their default path.
    public static func withOverrides(_ overrides: [String: LibraryPath]) -> ContentTypeRegistry {
        ContentTypeRegistry(builtIns.map { overrides[$0.id].map($0.overridingPath) ?? $0 })
    }

    public mutating func add(_ type: ContentType) {
        types.removeAll { $0.id == type.id }
        types.append(type)
    }
}
