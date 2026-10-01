//
//  RecoveryNote.swift
//  CryoframeKit
//
//  A plain-text note at the top of every folder Cryoframe backs up to, saying what
//  is there and how to get it back with nothing but a Mac.
//
//  A backup is only as good as the day someone needs it, and that someone may not
//  have Cryoframe: a new Mac, a family member, a repair shop. Everything Cryoframe
//  writes opens with tools built into macOS, but nothing on the drive said so or
//  said how. The note is rewritten after each run from what the folder actually
//  holds (every job writing there, not just the one that ran), and only when it
//  changes, so a cloud folder doesn't upload it again for nothing.
//
//  It holds no secrets: no passphrase, no path outside the folder. Discovery,
//  retention, drills and checks all look for folders holding a manifest, so a text
//  file at the top is never taken for a library. Writing it never fails a run.
//

import Foundation
import os

public enum RecoveryNote {
    /// ASCII only, so it reads the same on any drive format and any computer
    public static let fileName = "READ ME - How to restore without Cryoframe.txt"

    private static let log = Logger(subsystem: "app.cryoframe", category: "recovery-note")

    /// Write (or bring up to date) the note at the top of `destination`. Never creates
    /// the folder: a drive that isn't connected leaves its mount point empty, and
    /// writing there would put the note on the startup disk. Returns what went wrong,
    /// if anything, after logging it; the caller carries on regardless.
    @discardableResult
    public static func write(in destination: URL) -> Error? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDir), isDir.boolValue else {
            let error = CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: destination.path])
            log.error("recovery note not written, the destination isn't there: \(destination.path, privacy: .private)")
            return error
        }
        let url = destination.appendingPathComponent(fileName)
        let body = text(for: RestoreDiscovery.scan(destination))
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == body { return nil }
        do {
            try Data(body.utf8).write(to: url, options: .atomic)
            return nil
        } catch {
            log.error("recovery note not written in \(destination.path, privacy: .private): \(error.localizedDescription, privacy: .public)")
            return error
        }
    }

    /// The note for a folder holding `archives` (as RestoreDiscovery.scan finds them).
    public static func text(for archives: [RestorableArchive]) -> String {
        let libraries = RestoreDiscovery.libraries(in: archives)
        let formats = Set(archives.map(\.format))
        var out: [String] = []
        func add(_ lines: String...) { out.append(contentsOf: lines) }

        add("HOW TO RESTORE WITHOUT CRYOFRAME",
            "",
            "This folder holds backups made by Cryoframe, a backup app for the Mac. You don't",
            "need Cryoframe to get your files back: everything here opens with tools built",
            "into macOS. Cryoframe rewrites this note after each backup to describe what the",
            "folder holds.",
            "")

        add("WHAT'S IN THIS FOLDER", "")
        if libraries.isEmpty {
            add("Nothing yet: no finished backup was found here when this note was written.", "")
        }
        for lib in libraries {
            let versions = RestoreDiscovery.versions(of: lib, in: archives)
            guard let newest = versions.first else { continue }
            let encrypted = versions.contains(where: \.encrypted)
            add("\(lib) - \(formatName(newest.format))\(encrypted ? ", encrypted" : "")")
            // the folder as it is named on the drive, which needn't be the library's name
            let folder = newest.libraryFolder.lastPathComponent + "/"
            if newest.format == .liveMirror || newest.version == nil {
                add("  In the folder \(folder), one copy kept up to date: \(newest.artifactNames.first ?? "")")
            } else {
                let count = versions.count
                add("  In the folder \(folder), \(count) version\(count == 1 ? "" : "s"), each in its own folder named by the",
                    "  date and time of the backup (year-month-day-hourminutesecond). The newest is",
                    "  \(folder)\(newest.version.map(VersionStamp.string) ?? "")/")
                if newest.artifactNames.count > 1 {
                    add("  Each version is split into \(newest.artifactNames.count) parts; see \"Split archives\" below.")
                }
            }
            add("")
        }

        if formats.contains(.sealedDMG) {
            add("TO OPEN A SEALED DISK IMAGE (.dmg)",
                "",
                "1. Open the library's folder, then the folder of the version you want.",
                "2. Double-click the .dmg file. It opens in Finder as a read-only disk. If it is",
                "   encrypted, macOS asks for its passphrase.",
                "3. Copy what you need from that disk to your Mac, then eject the disk.",
                "",
                "In Terminal:  hdiutil attach -readonly \"NAME.dmg\"",
                "")
        }
        if formats.contains(.sealedZip) {
            add("TO OPEN A SEALED ZIP (.zip)",
                "",
                "1. Copy the .zip file to your Mac (the backup drive may not have room to unpack it).",
                "2. Double-click it. Archive Utility unpacks it into a folder beside it.",
                "",
                "In Terminal (keeps Finder tags and other Mac details):",
                "  ditto -x -k \"NAME.zip\" \"FOLDER TO UNPACK INTO\"",
                "",
                "On a computer that isn't a Mac, any unzip tool opens it; Mac-only details are",
                "kept in extra files starting with \"._\" that you can ignore.",
                "")
        }
        if formats.contains(.liveMirror) {
            add("TO OPEN A LIVE MIRROR (.sparsebundle)",
                "",
                "1. Double-click the .sparsebundle in the library's folder. It opens as a disk. If",
                "   it is encrypted, macOS asks for its passphrase.",
                "2. On that disk, the folder named after the library is the backup. Copy what you",
                "   need to your Mac, then eject the disk. Ignore a folder named .cryoframe-staging",
                "   if there is one: it is an unfinished update.",
                "",
                "Don't change anything on that disk or inside the .sparsebundle: that is the backup.",
                "In Terminal, to open it read-only:  hdiutil attach -readonly \"NAME.sparsebundle\"",
                "")
        }
        if archives.contains(where: { $0.artifactNames.count > 1 }) {
            let split = archives.filter { $0.artifactNames.count > 1 }
            let ext = split.allSatisfy { $0.format == .sealedZip } ? "zip" : split.allSatisfy { $0.format == .sealedDMG } ? "dmg" : "dmg (or .zip)"
            add("SPLIT ARCHIVES",
                "",
                "A large archive for a cloud folder is split into parts named NAME.\(ext).part.000,",
                "NAME.\(ext).part.001 and so on (or .part.aa, .part.ab). Join them into one file",
                "first, in Terminal, in the version's folder, in order:",
                "  ls \"NAME.\(ext == "zip" ? "zip" : "dmg").part.\"* | sort -V | while IFS= read -r p; do cat \"$p\"; done > ~/Desktop/\"NAME.\(ext == "zip" ? "zip" : "dmg")\"",
                "(sort -V puts part 1000 after part 999; with fewer parts, cat \"NAME.\(ext == "zip" ? "zip" : "dmg").part.\"* does the same.)",
                "then open the joined file as above.",
                "")
        }

        add("TO CHECK A BACKUP BY HAND",
            "",
            "Each backup's folder holds cryoframe-manifest.json, which lists every file with its",
            "size and SHA-256 checksum. To check a file of a sealed archive, in Terminal:",
            "  cd \"THE VERSION'S FOLDER\"",
            "  shasum -a 256 \"NAME.dmg\"",
            "and compare the result with the \"sha256\" value for that file in the manifest.",
            "A live mirror's value covers the whole .sparsebundle and can't be checked with",
            "shasum; to check a mirror, open it and run First Aid on its disk in Disk Utility.",
            "",
            "A version's folder may also hold cryoframe-contents.jsonl.gz, or",
            "cryoframe-contents.cflist if the backup is encrypted: the list of files in that",
            "version, for Cryoframe's Find a File. A restore doesn't need it.",
            "")

        add("ENCRYPTED BACKUPS",
            "",
            "An encrypted backup opens only with its passphrase, on any Mac. Nobody can open it",
            "without the passphrase, Cryoframe included. If you exported a Cryoframe recovery",
            "file, it holds every passphrase, locked with the master password you chose. The",
            "recovery file is opened with Cryoframe, which is free and open source:",
            "https://github.com/breed007/Cryoframe",
            "")

        add("Written by Cryoframe. This note holds no passwords or passphrases.")
        return out.joined(separator: "\n") + "\n"
    }

    static func formatName(_ f: ArchiveFormat) -> String {
        switch f {
        case .sealedDMG: return "sealed disk image (.dmg)"
        case .sealedZip: return "sealed zip (.zip)"
        case .liveMirror: return "live mirror (.sparsebundle)"
        }
    }
}
