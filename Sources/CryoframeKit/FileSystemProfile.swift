//
//  FileSystemProfile.swift
//  CryoframeKit
//
//  What a plain-files copy (see PlainCopy) can keep on the drive it is written to,
//  and how it is written there.
//
//  Measured on macOS 27.0.1 with exFAT and FAT32 disk images (both mount through
//  FSKit) and openrsync:
//    - exFAT and FAT32 keep names, contents, modification dates (FAT32 to 2 seconds,
//      rounded down), folders and symbolic links. They drop permissions (every item
//      reads 700), owners, access lists and creation dates. Extended attributes and
//      Finder tags live in a hidden "._" companion beside each item, 4 KB, one cluster
//      or more each; every file a process started from Terminal writes gets one (its
//      provenance). Foundation's directory listings leave the companions out.
//    - A source file named "._X" beside "X" is overwritten by X's companion the moment
//      X gets an attribute: rsync turned it into AppleDouble data.
//    - Both fold case and Unicode normalization ("é" composed or not is one name).
//    - No character was refused in a name: FSKit takes \ : * ? " < > | and control
//      characters and lists them back unchanged. A network drive may still refuse them,
//      so each such name is tried on the drive before it is copied (see PlainCopy).
//    - rsync without --modify-window=1 copies every file with an odd-second date again
//      on every FAT32 run; exFAT needs no window.
//    - FAT32 refuses a file of 4 GiB or more (EFBIG), and openrsync then ends the whole
//      run. A FAT32 folder holds at most 65,536 directory entries (the FAT
//      specification; not measured here): a long name takes one for each 13 characters
//      and one more, and its "._" companion as many again.
//

import Foundation

public struct FileSystemProfile: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Equatable, Codable {
        case apfs, hfs, exfat, fat32, network, cloud, other
    }
    public var kind: Kind
    /// the kernel's name for the file system ("apfs", "exfat", "msdos", "smbfs")
    public var fsType: String
    /// "a" and "A" are one name on it
    public var foldsCase: Bool
    /// the smallest amount of space a file takes on it: what statfs says (on exFAT and
    /// FAT, at least the largest cluster they commonly use), until a run measures it
    /// (see DriveAllocation)
    public var cluster: UInt64
    /// a drive that isn't a Mac's keeps a file's extended attributes in a hidden "._"
    /// companion; a copy checks whether what it writes gets one (see PlainCopy)
    public var companions: Bool
    /// the largest file it takes, if it has a limit: FAT32's, or a cloud provider's
    public var maxFileSize: UInt64?

    public init(kind: Kind, fsType: String, foldsCase: Bool = true, cluster: UInt64 = 4096,
                companions: Bool? = nil, maxFileSize: UInt64? = nil) {
        self.kind = kind; self.fsType = fsType; self.foldsCase = foldsCase; self.cluster = max(cluster, 512)
        self.companions = companions ?? !Self.macFileSystems.contains(fsType)
        self.maxFileSize = maxFileSize ?? (kind == .fat32 ? Self.fat32Limit : nil)
    }

    public static let fat32Limit: UInt64 = 4 * 1024 * 1024 * 1024
    /// the size of a "._" companion as written (measured: 4 KB)
    static let companionBytes: UInt64 = 4096
    /// a FAT32 folder's directory entries, at most
    static let fat32FolderEntries = 65_536
    static let macFileSystems: Set<String> = ["apfs", "hfs"]

    /// A Mac's own drive: permissions, extended attributes, access lists, flags and
    /// creation dates are kept, and the copy is made the way a mirror's is (see
    /// MirrorCopy.sync).
    public var keepsMacDetails: Bool { Self.macFileSystems.contains(fsType) && kind != .network }

    /// Brought up to date in a copy made beside it and swapped in whole (see
    /// PlainCopy): APFS on a drive of this Mac, where the copy beside it is a clone and
    /// costs next to nothing. Anywhere else the copy is updated where it is. A cloud
    /// folder is updated in place too: a new copy each run would be uploaded whole.
    public var swapsWholeCopy: Bool { kind == .apfs }

    /// An app library (Photos, Music…) can be kept here as plain files: only where the
    /// copy is swapped in whole. Updated in place, a copy stopped part way is a library
    /// that is part old and part new, which its app can damage further when it opens
    /// it; and a drive that isn't a Mac's can't hold what the app needs.
    public var takesAppLibraries: Bool { swapsWholeCopy }

    /// FAT32 keeps dates to 2 seconds: compared with a second's window either way
    public var modifyWindow: Bool { kind == .fat32 || kind == .network || kind == .other }

    /// The modification dates the drive keeps, in seconds since 1970; nil when it keeps
    /// any a library holds. exFAT and FAT32 keep 1980 to 2107 in local time, and
    /// Mac OS Extended 1904 to 2040; the bounds here sit a day or more inside those,
    /// whatever the time zone. Measured on macOS 27: FSKit stores 1970 as 1980-01-01
    /// and wraps 2200 to 2063 on exFAT and FAT32, and gave back 2106-01-01 a day early
    /// (2100-03-01 came back right), so its bound is 2100; Mac OS Extended, read again
    /// after a remount, gave back 1900 as 2036 and 2200 as 1970.
    public var dateRange: ClosedRange<Int>? {
        switch kind {
        case .exfat, .fat32: return 315_619_200 ... 4_102_444_800          // 1980-01-02 to 2100-01-01 UTC
        case .hfs: return -2_082_758_400 ... 2_208_988_800                  // 1904-01-02 to 2040-01-01 UTC
        default: return nil
        }
    }

    /// `seconds`, as the copy on this drive is dated: the nearest date it keeps
    public func clamped(_ seconds: Int) -> Int {
        guard let range = dateRange else { return seconds }
        return min(max(seconds, range.lowerBound), range.upperBound)
    }

    /// Whether a copy dated `copy` is current with a library item dated `library`, to
    /// the drive: the date it keeps for the library's, to a second either way where it
    /// keeps dates to 2 seconds. FAT32 keeps local time, which FSKit works out with the
    /// UTC offset in force at the time (measured: a January date written in October
    /// was stored an hour ahead), so after a daylight saving change every file would
    /// read an hour off and be copied again whole: exactly an hour either way counts
    /// as the same date there.
    public func sameDate(library: Int, copy: Int) -> Bool {
        let off = abs(copy - clamped(library))
        guard modifyWindow else { return off == 0 }
        return off <= 1 || (kind == .fat32 && abs(off - 3600) <= 1)
    }

    /// what this drive keeps of the library as plain files and what it drops, for the
    /// identity file, the editor and Restore. Empty for a Mac's own drive.
    public var dropped: [String] {
        keepsMacDetails ? [] : ["permissions", "extended attributes and Finder tags", "hidden and locked flags",
                                "creation dates", "hard links"]
    }

    /// how the drive is called to a person: "an exFAT drive"
    public var described: String {
        switch kind {
        case .apfs: return "an APFS drive"
        case .hfs: return "a Mac OS Extended drive"
        case .exfat: return "an exFAT drive"
        case .fat32: return "a FAT32 drive"
        case .network: return "a network drive"
        case .cloud: return "a cloud folder"
        case .other: return "a drive in the \(fsType.uppercased()) format"
        }
    }

    /// why an app library can't be kept as plain files here (nil: it can), in the words
    /// the editor and a run use
    public func refusal(appLibrary app: String) -> String? {
        guard !takesAppLibraries else { return nil }
        let why: String
        switch kind {
        case .exfat, .fat32, .other:
            why = "\(described) can't hold what \(app) needs to open its library again"
        case .network:
            why = "a copy updated over the network and stopped part way would leave a library \(app) can't open"
        case .cloud:
            why = "a cloud folder uploads a library while it is being updated, and \(app) can't open a library caught part way"
        case .hfs:
            why = "on a Mac OS Extended drive the copy is updated where it is, and one stopped part way would leave a library \(app) can't open"
        case .apfs:
            why = "\(described) can't take it"
        }
        return "\(app) can't be kept as plain files on this drive: \(why). Use a disk image on this drive."
    }

    // MARK: finding it

    /// the profile for `kind` of file system type `fsType` (pure, for tests)
    public static func make(fsType: String, target: TargetKind = .local, foldsCase: Bool = true,
                            cluster: UInt64 = 4096, cloudLimit: UInt64? = nil) -> FileSystemProfile {
        let fs = fsType.lowercased()
        let kind: Kind
        switch (target, fs) {
        case (.cloudSync, _): kind = .cloud
        case (.networkShare, _), (_, "smbfs"), (_, "afpfs"), (_, "nfs"), (_, "webdav"): kind = .network
        case (_, "apfs"): kind = .apfs
        case (_, "hfs"): kind = .hfs
        case (_, "exfat"): kind = .exfat
        case (_, "msdos"): kind = .fat32
        default: kind = .other
        }
        let limit = kind == .fat32 ? fat32Limit : cloudLimit
        return FileSystemProfile(kind: kind, fsType: fs, foldsCase: foldsCase, cluster: cluster,
                                 companions: kind == .network ? false : nil, maxFileSize: limit)
    }

    /// the drive `folder` is on, for a destination of `target`. A folder not made yet
    /// is on the drive of the nearest one that is.
    public static func of(_ folder: URL, target: Target? = nil) -> FileSystemProfile {
        var folder = folder
        while !FileManager.default.fileExists(atPath: folder.path), folder.path != "/" { folder.deleteLastPathComponent() }
        var url = folder
        url.removeAllCachedResourceValues()
        let v = try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        var s = statfs()
        let found = statfs(folder.path, &s) == 0
        let fsType = VolumeInspector.volume(for: folder)?.fsType ?? ""
        let cluster = DriveAllocation.cluster(statfsBlockSize: found && s.f_bsize > 0 ? UInt64(s.f_bsize) : nil,
                                              fsType: fsType.lowercased(), probed: DriveAllocation())
        let isLocal = found && (s.f_flags & UInt32(MNT_LOCAL)) != 0
        let kind: TargetKind = target?.kind == .cloudSync ? .cloudSync
            : (target?.kind == .networkShare || (found && !isLocal)) ? .networkShare : .local
        return make(fsType: fsType, target: kind, foldsCase: !(v?.volumeSupportsCaseSensitiveNames ?? false),
                    cluster: cluster, cloudLimit: target?.kind == .cloudSync ? target?.constraints.maxSingleFileBytes : nil)
    }

    // MARK: names

    /// The name a drive sees: one key for every spelling it takes to be the same name.
    /// Every drive here ignores Unicode normalization; one that folds case ignores case
    /// too. Folding more than the drive does is safe (two names it could have kept
    /// apart are treated as one, and one isn't copied); folding less is not.
    public func identity(of name: String) -> String {
        let n = name.decomposedStringWithCanonicalMapping
        return foldsCase ? n.folding(options: [.caseInsensitive], locale: nil) : n
    }

    /// directory entries `name` takes in a FAT32 folder, with its companion if the
    /// drive writes one: a long-name entry for each 13 characters, and the short one
    func fat32Entries(_ name: String) -> Int {
        func entries(_ n: String) -> Int { 1 + (n.utf16.count + 12) / 13 }
        return entries(name) + (companions ? entries("._" + name) : 0)
    }

    /// the room a file of `size` bytes takes, with its companion if the drive writes one
    func room(forFile size: UInt64, new: Bool) -> UInt64 {
        roundUp(size) + (new && companions ? roundUp(Self.companionBytes) : 0)
    }

    /// the room a new folder takes, with its companion if the drive writes one
    var roomForFolder: UInt64 { cluster + (companions ? roundUp(Self.companionBytes) : 0) }

    func roundUp(_ n: UInt64) -> UInt64 { (n + cluster - 1) / cluster * cluster }
}
