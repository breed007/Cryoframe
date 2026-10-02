//
//  ArchiveEngine.swift
//  CryoframeKit
//
//  Produces an archive from a (frozen) source tree. Two families:
//    - sealed   : immutable, checksummed cold storage — read-only UDZO dmg or
//                 zip, optionally split into sub-ceiling volumes for cloud sync.
//    - live mirror: incremental working backup — APFS sparsebundle (~8MB bands,
//                 only changed bands rewrite, the mechanism Time Machine uses).
//
//  Engines are agnostic to whether `root` is inside a snapshot mount or a plain
//  directory, which makes them testable with tiny fixtures and no root.
//  Command construction is factored into pure planners (ArchivePlan) so argv is
//  unit-tested without invoking hdiutil/ditto.
//

import Foundation

public struct ArchiveSource: Sendable, Equatable {
    public let name: String        // base name for the artifact
    public let root: URL           // directory to archive (e.g. the frozen .photoslibrary)
    /// bytes the source takes up, when the caller has measured it (JobExecutor walks
    /// every source before archiving). The mirror checks the destination against it.
    public let sizeHint: UInt64?
    /// items of the library left out of its backup, relative to `root`, each the
    /// topmost such item (see ContentType.leavesOut): no format copies them
    public var excluded: [String] = []
    /// what the library no longer holds is kept (see ContentType.keepsRemoved): the
    /// mirror moves it to Removed items in its image rather than deleting it
    public var keepsRemoved = false
    public init(name: String, root: URL, sizeHint: UInt64? = nil, excluded: [String] = [], keepsRemoved: Bool = false) {
        self.name = name; self.root = root; self.sizeHint = sizeHint
        self.excluded = excluded; self.keepsRemoved = keepsRemoved
    }
}

public enum ArchiveFormat: String, Sendable, Equatable, Codable {
    case sealedDMG, sealedZip, liveMirror
    /// ordinary files and folders in a library folder (see PlainCopy). Never written
    /// into anything an older version reads: a plain folder has no manifest.
    case plainFiles
}

public enum SplitPolicy: Sendable, Equatable {
    case none
    case maxBytes(UInt64)
    /// stay under the OneDrive/cloud single-file ceiling (250 GB). 240 GB volumes.
    public static let cloudCeiling = SplitPolicy.maxBytes(240 * 1_000_000_000)
}

public struct ArchiveResult: Sendable, Equatable {
    public let artifacts: [URL]    // one file, or split volumes
    public let format: ArchiveFormat
    public init(artifacts: [URL], format: ArchiveFormat) {
        self.artifacts = artifacts; self.format = format
    }
}

public protocol ArchiveEngine: Sendable {
    func archive(_ source: ArchiveSource, to destinationDir: URL) throws -> ArchiveResult
}

public enum ArchiveError: Error, Equatable {
    case toolFailed(tool: String, status: Int32, stderr: String)
    case noArtifactProduced(URL)
    case sourceMissing(String)
    case passphraseUnavailable      // job is encrypted but no key was found in the Keychain
}

public struct Command: Sendable, Equatable {
    public let tool: String
    public let args: [String]
    public init(_ tool: String, _ args: [String]) { self.tool = tool; self.args = args }
}

/// Pure command construction — no side effects, fully unit-testable.
public enum ArchivePlan {
    /// read-only compressed dmg. (hdiutil -segmentSize is deprecated and ignored
    /// for -srcfolder, so splitting is done post-hoc with split(1) — see ArchivePlan.split.)
    /// `sizeMB`, when given, sets the size of the file system the folder is copied
    /// into, instead of hdiutil's own guess (see DMGSizing).
    public static func dmg(root: URL, output: URL, encrypted: Bool = false, sizeMB: UInt64? = nil) -> Command {
        var args = ["create", "-srcfolder", root.path, "-format", "UDZO"]
        if let sizeMB { args += ["-size", "\(sizeMB)m"] }
        if encrypted { args += ["-encryption", "AES-256", "-stdinpass"] }   // passphrase via stdin
        args += ["-ov", output.path]
        return Command("/usr/bin/hdiutil", args)
    }

    /// ditto preserves ACLs / resource forks / xattrs — a plain zip would not.
    public static func zip(root: URL, output: URL) -> Command {
        Command("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", root.path, output.path])
    }

    /// post-hoc split of a finished file into <cap>-byte parts (for the zip path).
    public static func split(file: URL, cap: UInt64, prefix: String) -> Command {
        Command("/usr/bin/split", ["-b", "\(cap)", file.path, prefix])
    }

    /// `sectors`, when given, sets the size in 512-byte sectors instead of `sizeGB`.
    public static func sparseBundleCreate(output: URL, name: String, sizeGB: Int, bandSectors: Int,
                                          encrypted: Bool = false, sectors: UInt64? = nil) -> Command {
        let size = sectors.map { ["-sectors", "\($0)"] } ?? ["-size", "\(sizeGB)g"]
        var args = ["create", "-type", "SPARSEBUNDLE", "-fs", "APFS"] + size + ["-volname", name,
                    "-imagekey", "sparse-band-size=\(bandSectors)"]
        if encrypted { args += ["-encryption", "AES-256", "-stdinpass"] }
        args += [output.path]
        return Command("/usr/bin/hdiutil", args)
    }

    /// the image's size limits, in 512-byte sectors: "min<TAB>current<TAB>max".
    public static func resizeLimits(image: URL, encrypted: Bool = false) -> Command {
        Command("/usr/bin/hdiutil", ["resize", "-limits"] + (encrypted ? ["-stdinpass"] : []) + [image.path])
    }

    /// grow an image (and the APFS volume inside it) to `sizeGB`. Measured on APFS
    /// sparsebundles, plain and encrypted: the mounted volume reports the new size.
    public static func resize(image: URL, sizeGB: Int, encrypted: Bool = false, sectors: UInt64? = nil) -> Command {
        let size = sectors.map { ["-sectors", "\($0)"] } ?? ["-size", "\(sizeGB)g"]
        return Command("/usr/bin/hdiutil", ["resize"] + size + (encrypted ? ["-stdinpass"] : []) + [image.path])
    }

    /// attach a sparsebundle or dmg at a known mountpoint. `readonly` for
    /// verification mounts; read-write for the live-mirror rsync. `encrypted` adds
    /// `-stdinpass` so the passphrase is read from stdin.
    public static func attach(image: URL, mountpoint: URL, readonly: Bool = false, encrypted: Bool = false) -> Command {
        var args = ["attach", image.path, "-mountpoint", mountpoint.path, "-nobrowse", "-owners", "on"]
        if readonly { args.append("-readonly") }
        if encrypted { args.append("-stdinpass") }
        return Command("/usr/bin/hdiutil", args)
    }

    public static func detach(mountpoint: URL) -> Command {
        Command("/usr/bin/hdiutil", ["detach", mountpoint.path])
    }

    /// incremental sync into the attached mirror; --delete prunes removed files,
    /// --partial keeps partially-transferred files so a dropped run resumes them,
    /// and the sparsebundle only rewrites the ~8MB bands that actually changed.
    ///
    /// -E carries extended attributes, resource forks and ACLs. Without it `-a`
    /// alone silently drops all three — /usr/bin/rsync is openrsync on macOS 15+,
    /// where -a covers neither (and -X is not even a recognised option). That made
    /// the DEFAULT format the one lossy path in the app: sealed zip goes through
    /// ditto and sealed DMG through a filesystem image, both faithful, while the
    /// mirror quietly discarded Finder tags and every resource fork on every run.
    ///
    /// -S keeps a sparse file sparse. Without it a virtual machine's 1 GiB disk
    /// holding 8 KB was written out whole inside the image (1 GB of bands, measured),
    /// where the room check and the image's cap count what the file takes on disk.
    ///
    /// `inPlace`: a plain-files copy updated where it is (see PlainCopy), which keeps
    /// what the library no longer holds itself, and can't keep a partly sent file
    /// (--partial would put it in place of the file it was replacing).
    public static func rsync(root: URL, into destination: URL, extra: [String] = [], inPlace: Bool = false) -> Command {
        Command("/usr/bin/rsync", ["-aE", "-S"] + (inPlace ? [] : ["--delete", "--partial"]) + extra + [root.path + "/", destination.path + "/"])
    }
}

/// How big a disk image a folder needs.
///
/// `hdiutil create -srcfolder` sizes the image by what the folder takes on disk,
/// then copies each file out in full. A sparse file (a virtual machine's disk,
/// Docker's, a database's preallocated file) takes little room on disk and a lot
/// once written out: a library holding a 1 GiB sparse file failed "No space left on
/// device" with plenty free, measured on macOS 26.7, and so did every run of its
/// job, blaming the drive. When the folder's files add up to much more than they
/// take, the size is given: what they hold (each rounded up to a 4 KB block), a
/// tenth more, and 64 MB for the file system itself. The image is compressed
/// either way, so the size costs nothing in the archive.
public enum DMGSizing {
    public static func sizeMB(for root: URL) -> UInt64? {
        guard let walker = FileManager.default.enumerator(atPath: root.path) else { return nil }
        var logical: UInt64 = 0, onDisk: UInt64 = 0, items: UInt64 = 0
        while let rel = walker.nextObject() as? String {
            var st = stat()
            guard lstat(root.appendingPathComponent(rel).path, &st) == 0 else { continue }
            items += 1
            onDisk += UInt64(st.st_blocks) * 512
            if st.st_mode & S_IFMT == S_IFREG { logical += (UInt64(st.st_size) + 4095) / 4096 * 4096 }
        }
        guard logical > onDisk + max(64 << 20, onDisk / 10) else { return nil }
        let bytes = logical + logical / 10 + items * 4096 + (64 << 20)
        return (bytes + (1 << 20) - 1) >> 20
    }
}
