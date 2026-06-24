//
//  LibraryOverrides.swift
//  Cryoframe (app)
//
//  Per-built-in library path overrides, persisted in UserDefaults. Lets a user
//  repoint a built-in (e.g. a Photos library on an external drive) without
//  losing its owning-app detection or integrity check.
//

import Foundation
import CryoframeKit

enum LibraryOverrides {
    static func loadRaw() -> [String: String] {
        (UserDefaults.standard.dictionary(forKey: Prefs.libraryOverrides) as? [String: String]) ?? [:]
    }

    /// id → LibraryPath, ready for ContentTypeRegistry.withOverrides.
    static func load() -> [String: LibraryPath] {
        loadRaw().mapValues(libraryPath(for:))
    }

    static func set(id: String, path: String) {
        var d = loadRaw(); d[id] = path
        UserDefaults.standard.set(d, forKey: Prefs.libraryOverrides)
    }
    static func reset(id: String) {
        var d = loadRaw(); d.removeValue(forKey: id)
        UserDefaults.standard.set(d, forKey: Prefs.libraryOverrides)
    }
    static func resetAll() {
        UserDefaults.standard.removeObject(forKey: Prefs.libraryOverrides)
    }

    /// store absolute paths; express as home-relative when under the home dir so
    /// they map cleanly onto a snapshot mount.
    static func libraryPath(for path: String) -> LibraryPath {
        let home = NSHomeDirectory()
        if path == home { return .home("") }
        if path.hasPrefix(home + "/") { return .home(String(path.dropFirst(home.count + 1))) }
        return .absolute(path)
    }
}
