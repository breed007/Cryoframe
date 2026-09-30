//
//  RestoreEngine.swift
//  CryoframeKit
//
//  The other half of the lifecycle: get a library back out of an archive. Finds
//  restorable archives on disk (a folder holding a checksum manifest), verifies
//  the checksums, opens the archive (mount/extract via ArchiveReader), and copies
//  the library to a destination folder — reconstructing the bundle correctly for
//  each format. Restores beside the live library, never over it.
//

import Foundation

public enum RestoreStage: String, Sendable {
    case verifying, opening, copying, completed
}

public enum RestoreError: Error, Equatable {
    case verificationFailed(String)
    case libraryNotFound
    case destinationExists(String)
    case noManifest
    /// the drive the restore writes to hasn't room for it (see RestoreRoom). `volume`
    /// names the drive; `inPlace`: a restore over the live library, which keeps its
    /// space in the Trash.
    case notEnoughRoom(needed: UInt64, free: UInt64, volume: String, inPlace: Bool)
}

/// What to do when the restored item's name is already taken in the destination.
public enum RestoreClash: Sendable, Equatable {
    /// stop and report it (RestoreError.destinationExists); nothing is written
    case refuse
    /// restore beside it, under the first free "Name (2)", "Name (3)", …
    case alongside
}

/// The name a restore takes beside an item already there.
public enum RestoreNames {
    /// the first of "Name (2)", "Name (3)", … not taken in `dir`. A library's package
    /// extension stays last ("Photos Library (2).photoslibrary") so it still opens as
    /// one; anything else after a dot is part of the name ("Thesis.v2 (2)").
    public static func alongside(_ name: String, in dir: URL) -> URL {
        let ns = name as NSString
        let ext = ns.pathExtension
        let keepsExtension = ext.count >= 2 && ext.allSatisfy { $0.isASCII && $0.isLetter }
        let stem = keepsExtension ? ns.deletingPathExtension : name
        var n = 2
        while true {
            let candidate = keepsExtension ? "\(stem) (\(n)).\(ext)" : "\(stem) (\(n))"
            let url = dir.appendingPathComponent(candidate)
            var st = stat()
            if lstat(url.path, &st) != 0 { return url }          // nothing there, not even a broken link
            n += 1
        }
    }
}

/// Whether the drive a restore writes to has room for it.
///
/// A restore used to find out by running out: part-way through a copy of a large
/// library, with the drive full and a half-restored folder left behind. It is checked
/// twice. Before anything is read, against the archive's size on the backup drive:
/// a compressed archive's library is at least that big, so a drive with less room
/// can be refused at once. Then, once the archive is open, against the library it
/// actually holds.
///
/// Restoring in place needs the same room as restoring beside: the verified copy is
/// made next to the library first, and the library it replaces goes to the Trash on
/// the same drive, where it keeps its space until the Trash is emptied.
public enum RestoreRoom {
    /// what a restore of `bytes` needs free: the library, and 5% (at least 256 MB)
    /// for the file system's own use and whatever else is writing
    public static func needed(for bytes: UInt64) -> UInt64 {
        bytes + max(bytes / 20, 256 * 1024 * 1024)
    }

    /// nil when it fits (or the free space can't be read: a share that doesn't say),
    /// else the refusal
    public static func refusal(bytes: UInt64, free: UInt64?, volume: String, inPlace: Bool) -> RestoreError? {
        guard let free else { return nil }
        let need = needed(for: bytes)
        return free >= need ? nil : .notEnoughRoom(needed: need, free: free, volume: volume, inPlace: inPlace)
    }

    /// the name of the drive holding `url` (its first existing ancestor), for messages
    public static func volumeName(for url: URL) -> String {
        var dir = url
        for _ in 0..<32 {
            if let v = try? dir.resourceValues(forKeys: [.volumeLocalizedNameKey]), let name = v.volumeLocalizedName {
                return name
            }
            let parent = dir.deletingLastPathComponent()
            if parent == dir { break }
            dir = parent
        }
        return url.lastPathComponent
    }

    /// What a restore of `archive` needs at the least, known before it is opened: a
    /// sealed archive's size (compression only shrinks). nil for a mirror, whose
    /// archive is its disk image, which weighs more than its library (the image's own
    /// file system, and room a shrunk library left behind): 4 MB of library in a
    /// 47 MB image was refused with room to spare. A mirror is measured once open.
    public static func floor(for archive: RestorableArchive) -> UInt64? {
        archive.format == .liveMirror ? nil : archive.bytes
    }

    /// bytes the items take up on disk, folders walked
    static func bytes(of items: [URL]) -> UInt64 {
        items.reduce(0) { sum, item in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir) else { return sum }
            if isDir.boolValue { return sum + JobExecutor.directoryStats(item).bytes }
            let v = try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            return sum + UInt64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
        }
    }
}

/// one archive that can be restored — a directory with a checksum manifest.
public struct RestorableArchive: Sendable, Identifiable, Equatable {
    public var id: String { dir.path }
    public var dir: URL
    public var libraryName: String        // the archive subfolder name (the job's library display name)
    public var format: ArchiveFormat
    public var bytes: UInt64
    public var artifactNames: [String]    // from the manifest, in order
    public var encrypted: Bool            // needs a passphrase to open
    public var version: Date?             // the timestamp of this sealed version (nil = single-copy / legacy)

    public init(dir: URL, libraryName: String, format: ArchiveFormat, bytes: UInt64,
                artifactNames: [String], encrypted: Bool = false, version: Date? = nil) {
        self.dir = dir; self.libraryName = libraryName; self.format = format
        self.bytes = bytes; self.artifactNames = artifactNames; self.encrypted = encrypted; self.version = version
    }

    /// the original library/bundle name, recovered from the first artifact filename
    /// (e.g. "Photos Library.photoslibrary.dmg" → "Photos Library.photoslibrary";
    /// "…dmg.part.000" or "…zip.part.aa" → strip the part suffix first).
    ///
    /// Only a trailing part suffix, and never a mirror's (mirrors aren't split): this
    /// used to cut at the first ".part." anywhere, so a library called "Thesis.part.2"
    /// mirrored, drilled and rehearsed clean, and then wouldn't restore.
    public var bundleName: String {
        guard var n = artifactNames.first, !n.isEmpty else { return libraryName }
        if format != .liveMirror, let r = n.range(of: ".part.", options: .backwards) {
            let suffix = n[r.upperBound...]
            if !suffix.isEmpty, suffix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
                n = String(n[..<r.lowerBound])
            }
        }
        return (n as NSString).deletingPathExtension
    }

    public func archiveResult() -> ArchiveResult {
        ArchiveResult(artifacts: artifactNames.map { dir.appendingPathComponent($0) }, format: format)
    }
}

/// finds restorable archives under a folder.
public enum RestoreDiscovery {
    /// walk down to `maxDepth` levels, collecting every directory that holds a
    /// manifest. Covers target/library (single-copy mirror or legacy) and
    /// target/library/<version> (versioned sealed archives).
    public static func scan(_ folder: URL, maxDepth: Int = 2) -> [RestorableArchive] {
        var out: [RestorableArchive] = []
        walk(folder, depth: 0, maxDepth: maxDepth, into: &out)
        return out.sorted {
            $0.libraryName != $1.libraryName ? $0.libraryName < $1.libraryName
                : ($0.version ?? .distantPast) > ($1.version ?? .distantPast)   // newest version first
        }
    }

    private static func walk(_ dir: URL, depth: Int, maxDepth: Int, into out: inout [RestorableArchive]) {
        // listing a symlink lists nothing: follow it (depth still bounds a loop)
        let dir = (try? dir.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
            ? dir.resolvingSymlinksInPath() : dir
        if let a = archive(at: dir) { out.append(a); return }      // a manifest dir is a leaf
        guard depth < maxDepth else { return }
        let fm = FileManager.default
        for entry in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
            // fileExists follows a symlink: a destination can be one, or be reached
            // through one (a folder in the home folder pointing at a drive)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue {
                walk(entry, depth: depth + 1, maxDepth: maxDepth, into: &out)
            }
        }
    }

    /// the distinct libraries in a scan, in discovery order (scan already sorts by
    /// library, then newest version first). Drives the restore timeline's library list.
    public static func libraries(in archives: [RestorableArchive]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for a in archives where seen.insert(a.libraryName).inserted { out.append(a.libraryName) }
        return out
    }

    /// one library's versions, newest first.
    public static func versions(of library: String, in archives: [RestorableArchive]) -> [RestorableArchive] {
        archives.filter { $0.libraryName == library }
    }

    /// true when a library has no point-in-time history — a live mirror (or a legacy
    /// single copy) is one in-place copy with no version folders, so a timeline would
    /// be a lie. The UI shows a single "current" state for these instead.
    public static func isSingleCurrent(_ library: String, in archives: [RestorableArchive]) -> Bool {
        let v = versions(of: library, in: archives)
        return v.count == 1 && v[0].version == nil
    }

    public static func archive(at dir: URL) -> RestorableArchive? {
        let sidecar = dir.appendingPathComponent(ArchiveManifest.sidecarName)
        guard let m = try? ArchiveManifest.read(sidecar), !m.artifacts.isEmpty else { return nil }
        // a timestamped folder name means this is one version; the library name is its parent.
        let version = VersionStamp.date(dir.lastPathComponent)
        let libraryName = version != nil ? dir.deletingLastPathComponent().lastPathComponent : dir.lastPathComponent
        return RestorableArchive(dir: dir, libraryName: libraryName, format: m.format,
                                 bytes: m.artifacts.reduce(0) { $0 + $1.size }, artifactNames: m.artifacts.map(\.name),
                                 encrypted: m.encrypted ?? false, version: version)
    }
}

public struct RestoreEngine: Sendable {
    let runner: CommandRunner
    /// free bytes on the drive holding a folder (nil: unknown); injectable for tests
    let freeSpace: @Sendable (URL) -> UInt64?
    public init(runner: CommandRunner = ProcessCommandRunner(),
                freeSpace: @escaping @Sendable (URL) -> UInt64? = { JobExecutor.freeSpace(for: $0) }) {
        self.runner = runner; self.freeSpace = freeSpace
    }

    /// verify → open → copy the library into `destinationDir/<bundleName>`. Returns
    /// the restored library URL. Never overwrites an existing item there: with
    /// `onClash: .refuse` it stops, with `.alongside` it restores beside it under a
    /// new name. Refuses a drive without room for it (see RestoreRoom); `inPlace` only
    /// changes how that is worded.
    @discardableResult
    public func restore(_ archive: RestorableArchive, to destinationDir: URL, verify: Bool = true,
                        passphrase: String? = nil, onClash: RestoreClash = .refuse, inPlace: Bool = false,
                        onStage: @escaping @Sendable (RestoreStage) -> Void = { _ in }) throws -> URL {
        let fm = FileManager.default
        func checkRoom(_ bytes: UInt64) throws {
            if let refusal = RestoreRoom.refusal(bytes: bytes, free: freeSpace(destinationDir),
                                                 volume: RestoreRoom.volumeName(for: destinationDir), inPlace: inPlace) {
                throw refusal
            }
        }
        // before reading anything: a sealed archive's library is at least as big as it
        if let floor = RestoreRoom.floor(for: archive) { try checkRoom(floor) }
        // and a clash is said before the archive is verified, not after
        _ = try Self.target(archive.bundleName, in: destinationDir, onClash: onClash)

        if verify {
            onStage(.verifying)
            let sidecar = archive.dir.appendingPathComponent(ArchiveManifest.sidecarName)
            guard let manifest = try? ArchiveManifest.read(sidecar) else { throw RestoreError.noManifest }
            let report = try ChecksumVerifier().verify(manifest, in: archive.dir)   // checksums don't need the key
            guard report.passed else { throw RestoreError.verificationFailed(report.details) }
        }

        onStage(.opening)
        let opened = try ArchiveReader(runner: runner, freeSpace: freeSpace).open(archive.archiveResult(), passphrase: passphrase)
        defer { opened.close() }

        onStage(.copying)
        let bundleName = archive.bundleName
        let target = try Self.target(bundleName, in: destinationDir, onClash: onClash)   // taken meanwhile?
        try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        // zip / live mirror keep the bundle intact one level down. A sealed DMG does
        // one of two things, measured: `hdiutil create -srcfolder` puts a PACKAGE
        // (.photoslibrary, .musiclibrary, .app, …) on the volume root as one item, and
        // spreads a plain folder's CONTENTS over the root (even "Plain.stuff").
        //
        // So the library-named item on a DMG's root is the library only when it is a
        // package. Taking any directory of that name, as this used to, meant a plain
        // "Projects" folder holding its own "Projects" subfolder restored only the
        // subfolder, and reported success.
        switch archive.format {
        case .sealedDMG:
            let packaged = opened.root.appendingPathComponent(bundleName)
            if (try? packaged.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true {
                try checkRoom(RestoreRoom.bytes(of: [packaged]))
                try fm.copyItem(at: packaged, to: target)
                Self.keepQuarantine(from: packaged, to: target)
                break
            }
            let children = try fm.contentsOfDirectory(at: opened.root, includingPropertiesForKeys: nil)
            guard !children.isEmpty else { throw RestoreError.libraryNotFound }
            try checkRoom(RestoreRoom.bytes(of: children))
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for child in children {
                let into = target.appendingPathComponent(child.lastPathComponent)
                try fm.copyItem(at: child, to: into)
                Self.keepQuarantine(from: child, to: into)
            }
        case .sealedZip, .liveMirror:
            let bundle = opened.root.appendingPathComponent(bundleName)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: bundle.path, isDirectory: &isDir), isDir.boolValue else {
                throw RestoreError.libraryNotFound
            }
            try checkRoom(RestoreRoom.bytes(of: [bundle]))
            try fm.copyItem(at: bundle, to: target)
            Self.keepQuarantine(from: bundle, to: target)
        }

        onStage(.completed)
        return target
    }

    /// where the library goes: its own name, or with `.alongside` the first free
    /// "Name (2)" when that is taken. lstat, not fileExists: a broken link takes the
    /// name too, and fileExists follows it and says nothing is there; the copy then
    /// failed at the end with a raw "already exists".
    static func target(_ name: String, in dir: URL, onClash: RestoreClash) throws -> URL {
        let target = dir.appendingPathComponent(name)
        var st = stat()
        guard lstat(target.path, &st) == 0 else { return target }
        guard onClash == .alongside else { throw RestoreError.destinationExists(target.path) }
        return RestoreNames.alongside(name, in: dir)
    }

    static let quarantine = "com.apple.quarantine"

    /// Put back every downloaded file's quarantine exactly as the archive holds it.
    ///
    /// The copy (copyfile(3), as Finder's) re-stamps it: measured, "0083;66f9a1b2;
    /// Safari;<id>" arrives as "0283;<time of the copy>;;<id>", so a restored download
    /// looked as if it had been downloaded at the restore and lost which app fetched
    /// it. The archive's own bytes are written back, as the mirror now does. Best
    /// effort: a file that refuses (locked in Finder) keeps the re-stamped value, and
    /// the restore still succeeds. Only the attribute changes; the file's dates don't.
    ///
    /// Exactly as the archive holds it, which for a live mirror is exactly as the
    /// library had it. A sealed archive already holds a re-stamped value: hdiutil
    /// -srcfolder and ditto copy with copyfile when it is built.
    static func keepQuarantine(from source: URL, to copy: URL) {
        var rels = [""]
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue,
           let walker = FileManager.default.enumerator(atPath: source.path) {
            while let rel = walker.nextObject() as? String { rels.append(rel) }
        }
        for rel in rels {
            let from = rel.isEmpty ? source.path : source.appendingPathComponent(rel).path
            let to = rel.isEmpty ? copy.path : copy.appendingPathComponent(rel).path
            guard let value = MirrorCopy.attributeValue(from, quarantine),
                  MirrorCopy.attributeValue(to, quarantine) != value else { continue }
            if setxattr(to, quarantine, value, value.count, 0, XATTR_NOFOLLOW) == 0 { continue }
            // a read-only file: writable for the moment it takes
            var st = stat()
            guard errno == EACCES || errno == EPERM, lstat(to, &st) == 0, st.st_mode & S_IFMT != S_IFLNK else { continue }
            guard chmod(to, (st.st_mode & 0o7777) | S_IWUSR) == 0 else { continue }
            _ = setxattr(to, quarantine, value, value.count, 0, XATTR_NOFOLLOW)
            chmod(to, st.st_mode & 0o7777)
        }
    }
}
