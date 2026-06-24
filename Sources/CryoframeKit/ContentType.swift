//
//  ContentType.swift
//  CryoframeKit
//
//  The declarative content-type descriptor — the product's core abstraction.
//  Adding a library type should be a small declarative addition here, not new
//  plumbing. The useful distinction is liveDB (snapshot mandatory) vs static.
//

import Foundation

public enum ContentKind: String, Codable, Sendable {
    case liveDB                       // Photos, Music, Final Cut, Mail… snapshot mandatory
    case staticContent = "static"     // Movies, document trees, arbitrary folders
}

/// the app that owns a liveDB library — used to detect (and later, optionally
/// quiesce) it. nil for static content.
public struct OwningProcess: Codable, Sendable, Hashable {
    public var displayName: String
    public var bundleIdentifier: String?
    public var executableName: String?
    public init(displayName: String, bundleIdentifier: String? = nil, executableName: String? = nil) {
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.executableName = executableName
    }
}

/// where a library lives, expressed against the Data volume so it maps cleanly
/// onto a snapshot mount.
public enum LibraryPath: Codable, Sendable, Hashable {
    case home(String)        // relative to the invoking user's home (~/Pictures/…)
    case absolute(String)    // absolute Data-volume path (/Users/Shared/…)

    /// path on the live filesystem.
    public func liveURL(home: String) -> URL {
        switch self {
        case .home(let rel):  return URL(fileURLWithPath: home).appendingPathComponent(rel)
        case .absolute(let p): return URL(fileURLWithPath: p)
        }
    }

    /// same content inside a snapshot mounted at `mountPoint`. The Data volume's
    /// root holds /Users directly, so a live "/Users/x/…" maps to "<mount>/Users/x/…".
    public func frozenURL(mountPoint: String, user: String) -> URL {
        let base = URL(fileURLWithPath: mountPoint)
        switch self {
        case .home(let rel):
            return base.appendingPathComponent("Users").appendingPathComponent(user).appendingPathComponent(rel)
        case .absolute(let p):
            return base.appendingPathComponent(String(p.drop(while: { $0 == "/" })))
        }
    }
}

public struct ContentType: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var displayName: String
    public var paths: [LibraryPath]          // roots, Data-volume-relative
    public var owningProcess: OwningProcess?  // nil for static
    public var kind: ContentKind
    /// representative file inside the first root, read to confirm integrity
    /// (and reused by M4 verification). nil for static content.
    public var integrityProbe: String?

    public init(id: String, displayName: String, paths: [LibraryPath],
                owningProcess: OwningProcess?, kind: ContentKind, integrityProbe: String? = nil) {
        self.id = id; self.displayName = displayName; self.paths = paths
        self.owningProcess = owningProcess; self.kind = kind; self.integrityProbe = integrityProbe
    }

    public var requiresSnapshot: Bool { kind == .liveDB }

    public func owningProcessRunning(_ detector: ProcessDetector) -> Bool {
        guard let owner = owningProcess else { return false }
        return detector.isRunning(owner)
    }
}

// MARK: - Built-in descriptors (prove the abstraction: Photos, then Music, then folder)

public extension ContentType {
    static let photos = ContentType(
        id: "com.apple.photos",
        displayName: "Photos",
        paths: [.home("Pictures/Photos Library.photoslibrary")],
        owningProcess: OwningProcess(displayName: "Photos",
                                     bundleIdentifier: "com.apple.Photos", executableName: "Photos"),
        kind: .liveDB,
        integrityProbe: "database/Photos.sqlite")

    static let appleMusic = ContentType(
        id: "com.apple.music",
        displayName: "Apple Music",
        paths: [.home("Music/Music/Music Library.musiclibrary")],
        owningProcess: OwningProcess(displayName: "Music",
                                     bundleIdentifier: "com.apple.Music", executableName: "Music"),
        kind: .liveDB,
        integrityProbe: "Library.musicdb")

    static let iMovie = ContentType(
        id: "com.apple.imovie",
        displayName: "iMovie",
        paths: [.home("Movies/iMovie Library.imovielibrary")],
        owningProcess: OwningProcess(displayName: "iMovie",
                                     bundleIdentifier: "com.apple.iMovieApp", executableName: "iMovie"),
        kind: .liveDB,
        integrityProbe: nil)              // internal DB filename not confirmed; verify falls back to mount + non-empty

    static let messages = ContentType(
        id: "com.apple.messages",
        displayName: "Messages",
        paths: [.home("Library/Messages")],
        owningProcess: OwningProcess(displayName: "Messages",
                                     bundleIdentifier: "com.apple.MobileSMS", executableName: "Messages"),
        kind: .liveDB,
        integrityProbe: "chat.db")        // hot SQLite — the snapshot-consistency case

    static let mail = ContentType(
        id: "com.apple.mail",
        displayName: "Mail",
        paths: [.home("Library/Mail")],
        owningProcess: OwningProcess(displayName: "Mail",
                                     bundleIdentifier: "com.apple.mail", executableName: "Mail"),
        kind: .liveDB,
        integrityProbe: nil)              // envelope DB path is version-specific

    static let garageBand = ContentType(
        id: "com.apple.garageband",
        displayName: "GarageBand",
        paths: [.home("Music/GarageBand")],
        owningProcess: OwningProcess(displayName: "GarageBand",
                                     bundleIdentifier: "com.apple.garageband10", executableName: "GarageBand"),
        kind: .staticContent,             // a folder of .band projects, not a single DB
        integrityProbe: nil)

    /// default Outlook profile. Non-default profiles can be added via a template.
    static let outlook = ContentType(
        id: "com.microsoft.outlook",
        displayName: "Microsoft Outlook",
        paths: [.home("Library/Group Containers/UBF8T346G9.Office/Outlook/Outlook 15 Profiles/Main Profile")],
        owningProcess: OwningProcess(displayName: "Microsoft Outlook",
                                     bundleIdentifier: "com.microsoft.Outlook", executableName: "Microsoft Outlook"),
        kind: .liveDB,
        integrityProbe: nil)

    /// generic-folder escape hatch: point at any Data-volume path, treated as static.
    static func genericFolder(id: String, displayName: String, path: LibraryPath) -> ContentType {
        ContentType(id: id, displayName: displayName, paths: [path],
                    owningProcess: nil, kind: .staticContent, integrityProbe: nil)
    }
}
