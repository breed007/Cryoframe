//
//  LibraryFolder.swift
//  CryoframeKit
//
//  Which folder at a destination holds one library's backups.
//
//  Through 1.5 a library's archives lived in `<destination>/<library name>/`, found
//  by name alone. Two libraries with one name wrote into one folder (1.5.6 refused
//  such a job instead), a job's mirror and another job's sealed versions of the same
//  library shared a folder, and renaming a library would have orphaned its backups.
//
//  A library folder now carries an identity file naming the job and the library it
//  belongs to. The file, not the folder's name, says whose backups these are; the
//  name is for people and may change. A new folder takes the library's name, as
//  before, when no folder of that name is there; otherwise it is named
//  `<library name> [<short id>]`, the short id taken from the job and library ids,
//  so two libraries with one name get two folders side by side. A folder 1.5 wrote
//  keeps its name when it is taken over (see LibraryFolders), and so does a new one
//  with the plain name, so a return to 1.5.6 still finds them where it looks.
//

import Foundation
import CryptoKit

/// The identity file in a library folder.
public struct LibraryIdentity: Codable, Sendable, Equatable {
    public static let fileName = ".cryoframe-library.json"

    /// "<job id>/<library id>": whose backups the folder holds
    public var key: String
    public var jobID: String
    public var libraryID: String
    /// the library's name, and its job's, when the folder was last written to
    public var name: String
    public var jobName: String
    /// the names the library had before it was renamed, oldest first: checks recorded
    /// before 1.6 know a library only by its name (see KnownGood)
    public var formerNames: [String]?
    /// true when the library's job made a mirror when it last wrote here (nil: sealed
    /// versions)
    public var mirror: Bool?
    /// The version folders that were here when the library's job changed between a
    /// mirror and sealed versions. Whose they are can't be told: a mirror job's folder
    /// holds other jobs' versions (a 1.5 folder it shared, or what 1.5.6 wrote into it),
    /// and a sealed job's holds its own. They stay where they are, never pruned and
    /// never moved.
    public var heldVersions: [String]?

    public init(jobID: String, libraryID: String, name: String, jobName: String) {
        self.key = Self.key(jobID: jobID, libraryID: libraryID)
        self.jobID = jobID; self.libraryID = libraryID; self.name = name; self.jobName = jobName
    }

    public init(job: BackupJob, library: ContentType) {
        self.init(jobID: job.id, libraryID: library.id, name: library.displayName, jobName: job.name)
        mirror = job.format.isSealed ? nil : true
    }

    public static func key(jobID: String, libraryID: String) -> String { "\(jobID)/\(libraryID)" }

    public static func key(job: BackupJob, library: ContentType) -> String { key(jobID: job.id, libraryID: library.id) }

    /// six hex digits of the key's SHA-256: enough to tell apart the few libraries
    /// one destination holds (the identity file settles any tie)
    public static func shortID(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(3).map { String(format: "%02x", $0) }.joined()
    }

    /// the identity in `folder`, if it has a readable one
    public static func read(in folder: URL) -> LibraryIdentity? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(LibraryIdentity.self, from: data)
    }

    /// this identity, carrying over the names `previous` (the folder's identity until
    /// now) had, and its name if the library has since been renamed, and the versions
    /// it held
    public func following(_ previous: LibraryIdentity?) -> LibraryIdentity {
        guard let previous, previous.key == key else { return self }
        var names = previous.formerNames ?? []
        if previous.name != name, !names.contains(previous.name) { names.append(previous.name) }
        names.removeAll { $0 == name }
        var out = self
        out.formerNames = names.isEmpty ? nil : Array(names.suffix(20))
        out.heldVersions = previous.heldVersions
        return out
    }

    /// whether `version`, a version folder's name, is one of those held (see
    /// `heldVersions`)
    public func holds(_ version: String) -> Bool { heldVersions?.contains(version) == true }

    /// write it into `folder`, all at once (a crash leaves the old file or the new one)
    public func write(in folder: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

public enum LibraryFolderName {
    /// `<name> [<short id>]`, the name made safe for a folder: no "/" (a subfolder),
    /// no ":" (shown as "/" in Finder), no leading dot (hidden), not too long
    public static func make(name: String, key: String) -> String {
        "\(safe(name)) [\(LibraryIdentity.shortID(key))]"
    }

    public static func make(job: BackupJob, library: ContentType) -> String {
        make(name: library.displayName, key: LibraryIdentity.key(job: job, library: library))
    }

    /// the name a new folder for the library takes in `destination`: its own name if
    /// nothing there has it, else `<name> [<short id>]`
    public static func choose(job: BackupJob, library: ContentType, in destination: URL) -> String {
        let plain = safe(library.displayName)
        let taken = ((try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? [])
            .contains { LibraryNames.same($0, plain) }
        return taken ? make(job: job, library: library) : plain
    }

    static func safe(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        if s.isEmpty { s = "Library" }
        // a file name holds 255 bytes; leave room for " [abcdef]"
        while s.utf8.count > 200 { s.removeLast() }
        return s
    }

    /// whether `folder` is named as the library's folder may be: its plain name, its
    /// name exactly as 1.5 wrote it, or `<name> [<short id>]`. 1.5 named a folder by
    /// the library's name as it was ("Taxes 2024:25", ".config"); taken over in place,
    /// it keeps that name, or a return to 1.5.6 wouldn't find it and would start over.
    static func fits(_ folder: String, name: String, key: String) -> Bool {
        LibraryNames.same(folder, name) || LibraryNames.same(folder, safe(name)) || LibraryNames.same(folder, make(name: name, key: key))
    }
}
