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
    public init(runner: CommandRunner = ProcessCommandRunner()) { self.runner = runner }

    /// verify → open → copy the library into `destinationDir/<bundleName>`. Returns
    /// the restored library URL. Refuses to overwrite an existing item there.
    @discardableResult
    public func restore(_ archive: RestorableArchive, to destinationDir: URL, verify: Bool = true,
                        passphrase: String? = nil,
                        onStage: @escaping @Sendable (RestoreStage) -> Void = { _ in }) throws -> URL {
        let fm = FileManager.default

        if verify {
            onStage(.verifying)
            let sidecar = archive.dir.appendingPathComponent(ArchiveManifest.sidecarName)
            guard let manifest = try? ArchiveManifest.read(sidecar) else { throw RestoreError.noManifest }
            let report = try ChecksumVerifier().verify(manifest, in: archive.dir)   // checksums don't need the key
            guard report.passed else { throw RestoreError.verificationFailed(report.details) }
        }

        onStage(.opening)
        let opened = try ArchiveReader(runner: runner).open(archive.archiveResult(), passphrase: passphrase)
        defer { opened.close() }

        onStage(.copying)
        let bundleName = archive.bundleName
        let target = destinationDir.appendingPathComponent(bundleName)
        guard !fm.fileExists(atPath: target.path) else { throw RestoreError.destinationExists(target.path) }
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
                try fm.copyItem(at: packaged, to: target)
                break
            }
            let children = try fm.contentsOfDirectory(at: opened.root, includingPropertiesForKeys: nil)
            guard !children.isEmpty else { throw RestoreError.libraryNotFound }
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for child in children { try fm.copyItem(at: child, to: target.appendingPathComponent(child.lastPathComponent)) }
        case .sealedZip, .liveMirror:
            let bundle = opened.root.appendingPathComponent(bundleName)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: bundle.path, isDirectory: &isDir), isDir.boolValue else {
                throw RestoreError.libraryNotFound
            }
            try fm.copyItem(at: bundle, to: target)
        }

        onStage(.completed)
        return target
    }
}
