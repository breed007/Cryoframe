//
//  MediaExport.swift
//  CryoframeKit
//
//  Restore → Export Media…: one version's photos, videos and other files copied
//  out as ordinary files, into month folders ("2024-05") in a folder the person
//  picks. A one-time copy, not a backup: nothing keeps it up to date.
//
//  The month is the file's modification date. For a message attachment that is when
//  it was sent, and every format and drive keeps it; creation dates are lost on
//  exFAT and FAT32. A Live Photo's video goes with its photo: same month folder,
//  same name before the extension, same "(2)" when the name is taken.
//
//  Exporting again copies only what isn't there yet. A file whose name is taken in
//  its month folder is compared with what is there, and with each "(2)", "(3)"…
//  after it: the same bytes are skipped, different bytes take the first free name.
//  Files are handled in one fixed order, so the same file gets the same name on
//  every export, however often it is stopped part way.
//
//  Every phase says how far it has got, and Stop works in each: looking for files
//  (a count), checking what an earlier export left (bytes), copying (bytes). Each
//  file is written under its own name and given its source's date last; Stop removes
//  a part-written file. Before copying, the export writes a list of the files it is
//  about to write, with their sizes and dates, so after a crash the next export finds
//  a part-written one (its size or date is wrong) and writes it again. The room it
//  needs is checked before anything is written.
//
//  A file that can't be read from the version is skipped and named in the summary;
//  the rest still go out. A file that can't be written ends the export.
//

import Foundation
import UniformTypeIdentifiers

/// what a file is, for choosing what to export
public enum MediaKind: String, CaseIterable, Sendable, Hashable {
    case photos, videos, other

    public var title: String {
        switch self {
        case .photos: "Photos"
        case .videos: "Videos"
        case .other:  "Other files"
        }
    }

    /// what `name` is by its extension; nil for what an export never copies
    public static func of(name: String) -> MediaKind? {
        guard !MediaCatalog.isLeftOut(name) else { return nil }
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .image) { return .photos }
        if type.conforms(to: .movie) { return .videos }
        return .other
    }
}

/// a calendar month, and the name of its folder
public struct MediaMonth: Hashable, Comparable, Sendable {
    public let year: Int
    public let month: Int

    public init(year: Int, month: Int) { self.year = year; self.month = month }

    public init(_ date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1)
    }

    /// "2024-05": sorts by date in any file list
    public var folderName: String { String(format: "%04d-%02d", year, month) }

    public static func < (a: MediaMonth, b: MediaMonth) -> Bool { (a.year, a.month) < (b.year, b.month) }
}

/// one file in the version, by its path under the folder looked through
public struct MediaFile: Sendable, Equatable {
    /// "/"-separated, relative to the folder looked through
    public var path: String
    public var size: UInt64
    public var modified: Date

    public init(path: String, size: UInt64, modified: Date) {
        self.path = path; self.size = size; self.modified = modified
    }

    public var name: String { (path as NSString).lastPathComponent }
}

/// what is exported as one: a file, or a Live Photo's photo and its video
public struct MediaEntry: Sendable, Equatable {
    public var kind: MediaKind
    public var file: MediaFile
    /// a Live Photo's video: in the photo's folder, with the photo's name before the extension
    public var motion: MediaFile?

    public init(kind: MediaKind, file: MediaFile, motion: MediaFile? = nil) {
        self.kind = kind; self.file = file; self.motion = motion
    }

    public var files: [MediaFile] { motion.map { [file, $0] } ?? [file] }
    public var bytes: UInt64 { files.reduce(0) { $0 + $1.size } }

    /// the photo's month, which its video follows
    public func month(_ calendar: Calendar) -> MediaMonth { MediaMonth(file.modified, calendar: calendar) }
}

public enum MediaCatalog {
    /// Never exported: hidden files (a drive's `._` companions, `.DS_Store`), property
    /// lists, and the link previews Messages keeps beside attachments.
    static let leftOutExtensions: Set<String> = ["plist", "pluginpayloadattachment"]

    public static func isLeftOut(_ name: String) -> Bool {
        name.hasPrefix(".") || leftOutExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// The files as what is exported: each photo with its Live Photo video, when its
    /// folder holds a video of the same name, and every other file on its own. In
    /// path order, so the same files always come out the same way.
    public static func entries(_ files: [MediaFile]) -> [MediaEntry] {
        let sorted = files.sorted { $0.path < $1.path }
        var entries: [MediaEntry] = []
        var photoAt: [String: Int] = [:]          // folder + name before the extension → entry
        var videos: [MediaFile] = []
        for f in sorted {
            switch MediaKind.of(name: f.name) {
            case nil: continue
            case .videos?: videos.append(f)
            case .photos?:
                let key = pairKey(f.path)
                if photoAt[key] == nil { photoAt[key] = entries.count }
                entries.append(MediaEntry(kind: .photos, file: f))
            case .other?:
                entries.append(MediaEntry(kind: .other, file: f))
            }
        }
        for v in videos {
            if let i = photoAt[pairKey(v.path)], entries[i].motion == nil {
                entries[i].motion = v
            } else {
                entries.append(MediaEntry(kind: .videos, file: v))
            }
        }
        return entries.sorted { $0.file.path < $1.file.path }
    }

    /// a photo and its video share this: the folder, and the name before the extension
    static func pairKey(_ path: String) -> String {
        (path as NSString).deletingPathExtension.precomposedStringWithCanonicalMapping.lowercased()
    }
}

/// what to export: which kinds, from which months (both ends included; nil: open)
public struct MediaExportFilter: Sendable, Equatable {
    public var kinds: Set<MediaKind>
    public var from: MediaMonth?
    public var through: MediaMonth?

    public init(kinds: Set<MediaKind> = [.photos, .videos], from: MediaMonth? = nil, through: MediaMonth? = nil) {
        self.kinds = kinds; self.from = from; self.through = through
    }

    public func includes(_ e: MediaEntry, calendar: Calendar) -> Bool {
        guard kinds.contains(e.kind) else { return false }
        let m = e.month(calendar)
        if let from, m < from { return false }
        if let through, through < m { return false }
        return true
    }
}

/// which versions can be exported from, and where in them to look
public enum MediaExportScope {
    static let messagesIDs: Set<String> = ["com.apple.messages", "com.apple.messages.attachments"]
    /// an app's library kept as a package, wherever it is and whatever it is called
    static let appLibraryExtensions: Set<String> = ["photoslibrary", "musiclibrary", "imovielibrary", "tvlibrary",
                                                    "fcpbundle", "aplibrary", "band"]

    /// the built-in library `a` holds, from its folder's identity, or for a folder
    /// written before 1.6, from the library's own name
    static func builtIn(_ a: RestorableArchive) -> ContentType? {
        if let key = a.libraryKey, let slash = key.firstIndex(of: "/") {
            let id = String(key[key.index(after: slash)...])
            return ContentTypeRegistry.builtIns.first { $0.id == id }
        }
        return ContentTypeRegistry.builtIns.first { type in
            type.paths.contains { path in
                if case .home(let rel) = path { return (rel as NSString).lastPathComponent == a.bundleName }
                return false
            }
        }
    }

    /// Folders and Messages. Not the other apps' libraries: their files are the app's
    /// own (Photos keeps thumbnails and edits beside each original).
    public static func isOffered(_ a: RestorableArchive) -> Bool {
        if appLibraryExtensions.contains((a.bundleName as NSString).pathExtension.lowercased()) { return false }
        guard let type = builtIn(a) else { return true }
        return messagesIDs.contains(type.id)
    }

    /// whether `a` holds photos and files from someone's messages
    public static func holdsMessages(_ a: RestorableArchive) -> Bool {
        builtIn(a).map { messagesIDs.contains($0.id) } ?? false
    }

    /// where to look in `a`, opened with its library at `libraryRoot`: a Messages
    /// library's Attachments, anything else whole
    public static func folder(in libraryRoot: URL, for a: RestorableArchive) -> URL {
        builtIn(a)?.id == "com.apple.messages" ? libraryRoot.appendingPathComponent("Attachments", isDirectory: true) : libraryRoot
    }

    /// Said before an export of a version that is encrypted or holds messages, unless
    /// the drive it goes to is encrypted itself.
    public static func warning(for a: RestorableArchive, driveEncrypted: Bool) -> String? {
        let messages = holdsMessages(a)
        guard !driveEncrypted, a.encrypted || messages else { return nil }
        let what = messages ? ", including photos and files from your messages, even ones deleted in Messages since this backup" : ""
        return "The exported files aren't encrypted. Anyone who can open the folder you export to can see them\(what). When you're done with them, delete them from that folder in Finder."
    }
}

/// where an export writes, as far as it matters to the export
public struct MediaExportDrive: Sendable, Equatable {
    public var name: String
    /// "a" and "A" are one name on it
    public var foldsCase: Bool
    /// the smallest amount of space a file takes on it
    public var cluster: UInt64
    /// a drive that isn't a Mac's keeps a file's extended attributes in a hidden `._`
    /// companion, one cluster each; an export checks whether its files get any (see
    /// MediaExport.writesGetCompanions)
    public var companions: Bool
    /// FAT32: no file of 4 GiB or more
    public var maxFileSize: UInt64?
    public var encrypted: Bool
    public var free: UInt64?

    public init(name: String, foldsCase: Bool = true, cluster: UInt64 = 4096, companions: Bool = false,
                maxFileSize: UInt64? = nil, encrypted: Bool = false, free: UInt64? = nil) {
        self.name = name; self.foldsCase = foldsCase; self.cluster = cluster; self.companions = companions
        self.maxFileSize = maxFileSize; self.encrypted = encrypted; self.free = free
    }

    public static let fat32Limit: UInt64 = 4 * 1024 * 1024 * 1024

    /// the drive `folder` is on
    public static func of(_ folder: URL) -> MediaExportDrive {
        var url = folder
        url.removeAllCachedResourceValues()
        let v = try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey, .volumeIsEncryptedKey])
        let fsType = VolumeInspector.volume(for: folder)?.fsType ?? ""
        var s = statfs()
        let cluster: UInt64 = statfs(folder.path, &s) == 0 && s.f_bsize > 0 ? UInt64(s.f_bsize) : 4096
        return MediaExportDrive(name: RestoreRoom.volumeName(for: folder),
                                foldsCase: !(v?.volumeSupportsCaseSensitiveNames ?? false),
                                cluster: cluster,
                                companions: !["apfs", "hfs"].contains(fsType),
                                maxFileSize: fsType == "msdos" ? fat32Limit : nil,
                                encrypted: v?.volumeIsEncrypted ?? false,
                                free: JobExecutor.freeSpace(for: folder))
    }

    /// the name as the drive compares it
    func key(_ name: String) -> String {
        let n = name.precomposedStringWithCanonicalMapping
        return foldsCase ? n.folding(options: .caseInsensitive, locale: nil) : n
    }
}

/// a file to compare: in the version, or already in the folder exported to
public enum MediaLocation: Hashable, Sendable {
    case source(String)
    case exported(folder: String, name: String)
}

/// what the planner asks of the version and the folder exported to (fakes in tests)
public struct MediaExportProbe: Sendable {
    /// what a month folder holds, name → size (a folder: never the same as a file);
    /// nil when there is no such folder yet
    public var contents: @Sendable (_ folder: String) -> [String: UInt64]?
    /// whether two files hold the same bytes, saying how many it has read as it goes;
    /// throws CancelledError on Stop
    public var sameBytes: @Sendable (_ a: MediaLocation, _ b: MediaLocation, _ read: (UInt64) -> Void) throws -> Bool

    public init(contents: @escaping @Sendable (String) -> [String: UInt64]?,
                sameBytes: @escaping @Sendable (MediaLocation, MediaLocation, (UInt64) -> Void) throws -> Bool) {
        self.contents = contents; self.sameBytes = sameBytes
    }
}

public struct MediaExportPlan: Sendable, Equatable {
    public struct Copy: Sendable, Equatable {
        /// the path in the version
        public var source: String
        public var folder: String
        public var name: String
        public var size: UInt64
        public var modified: Date
    }

    public var copies: [Copy] = []
    /// files an earlier export already copied, or the same file twice in this one
    public var alreadyThere = 0
    /// files of 4 GiB or more on a FAT32 drive: not copied
    public var tooLarge: [String] = []
    /// month folders to be made
    public var newFolders: [String] = []

    public var bytes: UInt64 { copies.reduce(0) { $0 + $1.size } }
}

public enum MediaExportPlanner {
    /// "IMG_0001 (2).HEIC"; `n` 1 is the name itself
    public static func suffixed(_ name: String, _ n: Int) -> String {
        guard n > 1 else { return name }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        return ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
    }

    private enum Fit { case free, same, taken }

    /// What exporting `entries` to the drive writes, and under which names. Each name
    /// taken in its month folder, by an earlier export or by this one, is compared:
    /// the same bytes are already there, different bytes try the next "(n)". A Live
    /// Photo's two files take one "(n)" between them. `progress` is told the bytes
    /// handled so far, of the entries' total.
    public static func plan(_ entries: [MediaEntry], drive: MediaExportDrive, probe: MediaExportProbe,
                            calendar: Calendar, control: RunControl? = nil,
                            progress: (UInt64) -> Void = { _ in }) throws -> MediaExportPlan {
        var plan = MediaExportPlan()
        var listed: [String: [String: (name: String, size: UInt64)]] = [:]
        var claimed: [String: [String: (at: MediaLocation, size: UInt64)]] = [:]
        var done: UInt64 = 0
        let ordered = entries.enumerated().sorted { a, b in
            let (ma, mb) = (a.element.month(calendar), b.element.month(calendar))
            return ma != mb ? ma < mb : a.offset < b.offset
        }.map(\.element)

        for entry in ordered {
            if control?.isCancelled == true { throw CancelledError() }
            defer { done += entry.bytes; progress(done) }
            if let max = drive.maxFileSize, entry.files.contains(where: { $0.size >= max }) {
                plan.tooLarge += entry.files.filter { $0.size >= max }.map(\.name)
                continue
            }
            let folder = entry.month(calendar).folderName
            if listed[folder] == nil {
                let there = probe.contents(folder)
                if there == nil { plan.newFolders.append(folder) }
                var byKey: [String: (name: String, size: UInt64)] = [:]
                for (name, size) in there ?? [:] { byKey[drive.key(name)] = (name, size) }
                listed[folder] = byKey
            }
            var read: UInt64 = 0
            func compare(_ f: MediaFile, _ other: MediaLocation) throws -> Bool {
                try probe.sameBytes(.source(f.path), other) { n in progress(done + min(read + n, entry.bytes)) }
            }
            var n = 1
            while true {
                var fits: [(MediaFile, String, Fit, MediaLocation?)] = []
                for f in entry.files {
                    let name = suffixed(f.name, n), key = drive.key(name)
                    if let c = claimed[folder]?[key] {
                        let same = try c.size == f.size && compare(f, c.at)
                        fits.append((f, name, same ? .same : .taken, c.at))
                    } else if let e = listed[folder]?[key] {
                        let at = MediaLocation.exported(folder: folder, name: e.name)
                        let same = try e.size == f.size && compare(f, at)
                        fits.append((f, name, same ? .same : .taken, at))
                    } else {
                        fits.append((f, name, .free, nil))
                    }
                    read += f.size
                }
                if fits.contains(where: { $0.2 == .taken }) { n += 1; read = 0; continue }
                for (f, name, fit, at) in fits {
                    let key = drive.key(name)
                    if fit == .same {
                        plan.alreadyThere += 1
                        claimed[folder, default: [:]][key] = (at ?? .source(f.path), f.size)
                    } else {
                        plan.copies.append(.init(source: f.path, folder: folder, name: name, size: f.size, modified: f.modified))
                        claimed[folder, default: [:]][key] = (.source(f.path), f.size)
                    }
                }
                break
            }
        }
        return plan
    }
}

public enum MediaExportRoom {
    /// What copying `plan` takes on `drive`: each file rounded up to whole clusters,
    /// a cluster for each new folder, one for each `._` companion when the drive gets
    /// them (see MediaExport.writesGetCompanions), and 1% (at least 16 MB) for the
    /// drive's own use.
    public static func needed(_ plan: MediaExportPlan, drive: MediaExportDrive) -> UInt64 {
        let c = max(drive.cluster, 512)
        let per: UInt64 = drive.companions ? c : 0
        var need: UInt64 = 0
        for copy in plan.copies { need += (copy.size + c - 1) / c * c + per }
        need += UInt64(plan.newFolders.count) * (c + per)
        return need + max(need / 100, 16 * 1024 * 1024)
    }

    /// nil when it fits, or the free space can't be read
    public static func refusal(_ plan: MediaExportPlan, drive: MediaExportDrive) -> MediaExportError? {
        guard let free = drive.free, !plan.copies.isEmpty else { return nil }
        let need = needed(plan, drive: drive)
        return free >= need ? nil : .notEnoughRoom(needed: need, free: free, drive: drive.name)
    }
}

public enum MediaExportError: Error, LocalizedError, Equatable {
    case notEnoughRoom(needed: UInt64, free: UInt64, drive: String)
    /// writing into the folder exported to failed: the export ends there. (A file that
    /// can't be read from the version is skipped instead; see MediaExportOutcome.)
    case saveFailed(name: String, folder: String, reason: String, copied: Int, of: Int)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .notEnoughRoom(let needed, let free, let drive):
            return "There isn't room on \(drive): this export needs about \(MediaExport.size(needed)) and there is \(MediaExport.size(free)) free. Nothing was copied. Choose fewer kinds or months, free up space, or choose a folder on another drive."
        case .saveFailed(let name, let folder, let reason, let copied, let of):
            return "Couldn't save “\(name)” in the folder “\(folder)”: \(reason) \(MediaExport.count(copied)) of \(MediaExport.count(of)) files were copied; exporting again skips them."
        case .notFound(let folder):
            return "There's no \(folder) folder in this backup, so there's nothing to export."
        }
    }
}

public struct MediaExportProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case looking, checking, copying }
    public var phase: Phase
    /// 0…1; nil while looking, when the total isn't known yet
    public var fraction: Double?
    public var detail: String
}

public struct MediaExportOutcome: Sendable, Equatable {
    public var copied = 0
    public var bytes: UInt64 = 0
    /// the files the plan said to copy
    public var planned = 0
    public var alreadyThere = 0
    public var tooLarge: [String] = []
    public var stopped = false
    /// files of the chosen kinds and months, before any were found already there
    public var matched = 0
    /// files in the version that couldn't be read (a damaged copy, a file no one may
    /// read), by their path in it: skipped, so the rest still go out
    public var unreadable: [String] = []

    public init() {}

    /// what to tell the person, naming the folder exported to
    public func summary(folder: String) -> String {
        if stopped {
            let out = copied == 0 ? "Stopped before anything was copied."
                : "Stopped after \(MediaExport.count(copied)) of \(MediaExport.count(planned)) files. Exporting again skips what's done."
            return out + unreadableNote
        }
        var out: String
        if matched == 0 {
            out = "Nothing to export: no files of those kinds from those months."
        } else if copied == 0 && tooLarge.isEmpty && unreadable.isEmpty {
            out = "Everything was already in “\(folder)”: \(MediaExport.count(alreadyThere)) \(alreadyThere == 1 ? "file" : "files")."
        } else {
            out = "Copied \(MediaExport.count(copied)) \(copied == 1 ? "file" : "files") (\(MediaExport.size(bytes))) into month folders in “\(folder)”."
            if alreadyThere > 0 { out += " \(MediaExport.count(alreadyThere)) were already there." }
        }
        if !tooLarge.isEmpty {
            let names = tooLarge.prefix(3).joined(separator: ", ") + (tooLarge.count > 3 ? ", …" : "")
            out += " \(MediaExport.count(tooLarge.count)) \(tooLarge.count == 1 ? "file was" : "files were") skipped (\(names)): a file of 4 GB or more doesn't fit on a FAT32 drive. An exFAT or Mac drive can take them."
        }
        return out + unreadableNote
    }

    /// the files that couldn't be read, the first few by name; empty when there were none
    var unreadableNote: String {
        guard !unreadable.isEmpty else { return "" }
        let shown = unreadable.prefix(3).joined(separator: ", ") + (unreadable.count > 3 ? ", …" : "")
        let n = unreadable.count
        return " \(MediaExport.count(n)) \(n == 1 ? "file" : "files") couldn't be read from this backup and \(n == 1 ? "wasn't" : "weren't") copied: \(shown). Another version of the backup may have \(n == 1 ? "it" : "them")."
    }
}

/// Runs an export: looks through `folder` in an opened version, then checks and
/// copies into `destination`.
public struct MediaExport: Sendable {
    /// names what an export keeps in the folder exported to only while it writes (its
    /// list of files; see writeList). Nothing by this name stays after a Stop.
    public static let tempPrefix = ".cryoframe-export-"
    static let chunk = 4 * 1024 * 1024

    let calendar: Calendar
    /// how often progress is passed on, at most
    let interval: TimeInterval

    public init(calendar: Calendar = .current, interval: TimeInterval = 0.1) {
        self.calendar = calendar; self.interval = interval
    }

    static func count(_ n: Int) -> String { n.formatted() }
    static func size(_ b: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: b), countStyle: .file) }

    /// Export what `filter` picks from `folder` into `destination`. A Stop returns the
    /// outcome so far, marked stopped. Throws a MediaExportError for a drive without
    /// room (before anything is written) and a file that won't copy.
    public func run(from folder: URL, to destination: URL, filter: MediaExportFilter,
                    drive: MediaExportDrive? = nil, control: RunControl,
                    progress: @escaping @Sendable (MediaExportProgress) -> Void) throws -> MediaExportOutcome {
        var out = MediaExportOutcome()
        let tell = MediaExportThrottle(interval: interval, progress)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            throw MediaExportError.notFound(folder.lastPathComponent)
        }
        do {
            // what an export cut off by a crash left part-written goes first
            Self.finishInterrupted(in: destination)
            tell(.init(phase: .looking, fraction: nil, detail: "Looking for files…"), force: true)
            let files = try Self.look(in: folder, control: control) { n in
                tell(.init(phase: .looking, fraction: nil, detail: "Looking for files… \(Self.count(n)) found"))
            }
            let entries = MediaCatalog.entries(files).filter { filter.includes($0, calendar: calendar) }
            out.matched = entries.reduce(0) { $0 + $1.files.count }
            guard !entries.isEmpty else { return out }

            var drive = drive ?? MediaExportDrive.of(destination)
            if drive.companions { drive.companions = Self.writesGetCompanions(in: destination) }
            let total = max(entries.reduce(0) { $0 + $1.bytes }, 1)
            tell(.init(phase: .checking, fraction: 0, detail: "Checking for files exported before…"), force: true)
            let plan = try MediaExportPlanner.plan(entries, drive: drive, probe: Self.probe(source: folder, destination: destination, control: control),
                                                   calendar: calendar, control: control) { done in
                tell(.init(phase: .checking, fraction: Double(done) / Double(total), detail: "Checking for files exported before…"))
            }
            out.planned = plan.copies.count; out.alreadyThere = plan.alreadyThere; out.tooLarge = plan.tooLarge
            if let refusal = MediaExportRoom.refusal(plan, drive: drive) { throw refusal }

            try copy(plan, from: folder, to: destination, control: control, outcome: &out, tell: tell)
        } catch is CancelledError {
            out.stopped = true
        }
        return out
    }

    private func copy(_ plan: MediaExportPlan, from folder: URL, to destination: URL, control: RunControl,
                      outcome out: inout MediaExportOutcome, tell: MediaExportThrottle) throws {
        let total = max(plan.bytes, 1), files = plan.copies.count
        guard let first = plan.copies.first else { return }
        do {
            try Self.writeList(plan, in: destination)
        } catch {
            throw MediaExportError.saveFailed(name: first.name, folder: first.folder, reason: Self.writeReason(error), copied: 0, of: files)
        }
        // A part-written file left behind (its removal failed: the drive went away)
        // keeps the list, so the next export finds it.
        var keepList = false
        defer { if !keepList { try? FileManager.default.removeItem(at: destination.appendingPathComponent(Self.listName)) } }
        var made = Set<String>(), partLeft = false
        var done: UInt64 = 0, handled = 0
        func say(_ extra: UInt64, force: Bool = false) {
            let bytes = done + extra, at = min(handled + 1, files)
            tell(.init(phase: .copying, fraction: Double(bytes) / Double(total),
                       detail: "Copying \(Self.count(at)) of \(Self.count(files)) · \(Self.size(bytes)) of \(Self.size(plan.bytes))"),
                 force: force)
        }
        say(0, force: true)
        for c in plan.copies {
            if control.isCancelled { throw CancelledError() }
            let dir = destination.appendingPathComponent(c.folder, isDirectory: true)
            do {
                if !made.contains(c.folder) {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    made.insert(c.folder)
                }
                try Self.copyFile(folder.appendingPathComponent(c.source), into: dir, as: c.name, modified: c.modified,
                                  control: control, partLeft: &partLeft) { say($0) }
                out.copied += 1; out.bytes += c.size
            } catch is CancelledError {
                keepList = partLeft
                throw CancelledError()
            } catch is ReadFailure {
                // One file, not the drive: the rest still go out. Its name stays its own
                // (the plan is the same on every export), so nothing after it moves.
                out.unreadable.append(c.source)
            } catch {
                keepList = partLeft
                throw MediaExportError.saveFailed(name: c.name, folder: c.folder, reason: Self.writeReason(error),
                                                  copied: out.copied, of: files)
            }
            handled += 1; done += c.size
            say(0)
        }
    }

    /// reading the file in the version failed, not writing it out
    struct ReadFailure: Error {
        let underlying: Error
    }

    /// why a file couldn't be written into the folder exported to, as a sentence
    static func writeReason(_ error: Error) -> String {
        let ns = error as NSError
        let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        func any(_ posix: Set<Int32>, _ cocoa: Set<CocoaError.Code>) -> Bool {
            [ns, underlying].contains { e in
                guard let e else { return false }
                return (e.domain == NSPOSIXErrorDomain && posix.contains(Int32(e.code)))
                    || (e.domain == NSCocoaErrorDomain && cocoa.contains(CocoaError.Code(rawValue: e.code)))
            }
        }
        if any([ENOSPC, EDQUOT], [.fileWriteOutOfSpace]) { return "the drive is full." }
        if any([EROFS], [.fileWriteVolumeReadOnly]) { return "the drive can only be read, not written to." }
        if any([EACCES, EPERM], [.fileWriteNoPermission]) { return "Cryoframe isn't allowed to save files there." }
        if any([EIO, ENXIO, ENODEV], []) { return "the drive stopped answering. Check that it's still connected." }
        let text = ns.localizedDescription
        return text.hasSuffix(".") ? text : text + "."
    }

    // MARK: - the file system

    /// Every file under `folder` an export could copy, without going into packages or
    /// hidden folders. Paths come from the walk itself, relative to `folder`: a
    /// temporary folder is "/var/…" to its caller and "/private/var/…" to the file
    /// system, so they're never worked out by comparing the two.
    static func look(in folder: URL, control: RunControl, found: (Int) -> Void) throws -> [MediaFile] {
        guard let walk = FileManager.default.enumerator(atPath: folder.path) else { return [] }
        var files: [MediaFile] = []
        var seen = 0
        while let path = walk.nextObject() as? String {
            seen += 1
            if seen % 256 == 0 {
                if control.isCancelled { throw CancelledError() }
                found(files.count)
            }
            let name = (path as NSString).lastPathComponent
            let attrs = walk.fileAttributes
            switch attrs?[.type] as? FileAttributeType {
            case .typeDirectory?:
                let isPackage = (try? folder.appendingPathComponent(path).resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
                if name.hasPrefix(".") || isPackage { walk.skipDescendants() }
            case .typeRegular? where !MediaCatalog.isLeftOut(name):
                files.append(MediaFile(path: path, size: (attrs?[.size] as? NSNumber)?.uint64Value ?? 0,
                                       modified: attrs?[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)))
            default:
                continue
            }
        }
        if control.isCancelled { throw CancelledError() }
        found(files.count)
        return files
    }

    static func probe(source: URL, destination: URL, control: RunControl) -> MediaExportProbe {
        @Sendable func url(_ at: MediaLocation) -> URL {
            switch at {
            case .source(let path): source.appendingPathComponent(path)
            case .exported(let folder, let name): destination.appendingPathComponent(folder).appendingPathComponent(name)
            }
        }
        return MediaExportProbe(contents: { folder in
            let dir = destination.appendingPathComponent(folder, isDirectory: true)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) else { return nil }
            // a file where the folder would go: the copy says it can't make the folder
            guard isDir.boolValue, let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [:] }
            var out: [String: UInt64] = [:]
            for name in names where !name.hasPrefix(".") {
                let attrs = try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)
                let regular = attrs?[.type] as? FileAttributeType == .typeRegular
                out[name] = regular ? (attrs?[.size] as? NSNumber)?.uint64Value ?? 0 : UInt64.max
            }
            return out
        }, sameBytes: { a, b, read in
            try sameBytes(url(a), url(b), control: control, read: read)
        })
    }

    /// whether two files hold the same bytes, read a chunk at a time
    static func sameBytes(_ a: URL, _ b: URL, control: RunControl, read: (UInt64) -> Void) throws -> Bool {
        guard let fa = try? FileHandle(forReadingFrom: a), let fb = try? FileHandle(forReadingFrom: b) else { return false }
        defer { try? fa.close(); try? fb.close() }
        var n: UInt64 = 0
        while true {
            if control.isCancelled { throw CancelledError() }
            let da = (try? fa.read(upToCount: chunk)) ?? nil, db = (try? fb.read(upToCount: chunk)) ?? nil
            if da != db { return false }
            guard let da, !da.isEmpty else { return true }
            n += UInt64(da.count)
            read(n)
        }
    }

    /// Write `source` into `dir` as `name`, then give it the source's modification
    /// date, on the open file, as the last step: a file there with its source's size
    /// and date is whole. Never replaces a file: the name was free when planned. On
    /// Stop or a failure the part-written file is removed (`partLeft` says when it
    /// couldn't be); after a crash, the export's list finds it (see finishInterrupted).
    ///
    /// Straight to its name, not through a temporary one: on an exFAT drive a rename
    /// cost more than the copy (measured on macOS 27, 1,500 files of 400 KB: 43 s to
    /// copy, 89 s with a temporary name and a rename each).
    static func copyFile(_ source: URL, into dir: URL, as name: String, modified: Date, control: RunControl,
                         partLeft: inout Bool, wrote: (UInt64) -> Void) throws {
        // opened first: a file that can't be read leaves nothing behind on the drive
        let input: FileHandle
        do { input = try FileHandle(forReadingFrom: source) } catch { throw ReadFailure(underlying: error) }
        defer { try? input.close() }
        let target = dir.appendingPathComponent(name)
        let fd = open(target.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var whole = false
        defer {
            close(fd)
            // a part-written file that won't go (the drive went away) is the next export's
            if !whole, unlink(target.path) != 0, errno != ENOENT { partLeft = true }
        }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var n: UInt64 = 0
        while true {
            if control.isCancelled { throw CancelledError() }
            let read: Data?
            do { read = try input.read(upToCount: chunk) } catch { throw ReadFailure(underlying: error) }
            guard let data = read, !data.isEmpty else { break }
            try output.write(contentsOf: data)
            n += UInt64(data.count)
            wrote(n)
        }
        try output.synchronize()
        let t = modified.timeIntervalSince1970, seconds = t.rounded(.down)
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
                     timespec(tv_sec: Int(seconds), tv_nsec: min(Int(((t - seconds) * 1e9).rounded()), 999_999_999))]
        guard futimens(fd, &times) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        whole = true
    }

    /// Whether a file this app writes into `folder` gets a hidden `._` companion. An
    /// export copies only bytes and a date, so the version's extended attributes and
    /// resource forks never come along: a companion comes only from macOS itself,
    /// which tags what some apps write (com.apple.provenance), and a drive that isn't
    /// a Mac's keeps the tag in a `._` file. Measured on macOS 27 with exFAT: a tool
    /// started from Terminal got one for every file, the test runner none. So one
    /// small file is written, looked at and removed. Can't tell: counted.
    static func writesGetCompanions(in folder: URL) -> Bool {
        let probe = folder.appendingPathComponent(tempPrefix + "probe-" + UUID().uuidString)
        let fd = open(probe.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else { return true }
        _ = write(fd, "x", 1)
        close(fd)
        defer { unlink(probe.path) }
        return listxattr(probe.path, nil, 0, XATTR_NOFOLLOW) != 0
    }

    // MARK: - what a crash leaves

    /// the files an export is writing, in the folder exported to, while it writes them
    static let listName = tempPrefix + "list"

    struct ListEntry: Codable, Equatable {
        var folder: String
        var name: String
        var size: UInt64
        /// seconds since 1970
        var modified: Double
    }

    /// Before copying: say which files this export writes, under which names, and with
    /// which size and date, so a crash part way can be found (see finishInterrupted).
    /// Written once and flushed, not once per file.
    static func writeList(_ plan: MediaExportPlan, in destination: URL) throws {
        let entries = plan.copies.map { ListEntry(folder: $0.folder, name: $0.name, size: $0.size, modified: $0.modified.timeIntervalSince1970) }
        let data = try JSONEncoder().encode(entries)
        let url = destination.appendingPathComponent(listName)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
    }

    /// After a crash part way through an export: each file it meant to write that is
    /// there without its source's size and date (2 s either way: FAT32 keeps dates to
    /// 2 s) wasn't finished, and is removed, so this export writes it again under the
    /// same name. A Stop or a failure leaves no list: it removes its own part-written
    /// file. Returns how many were removed.
    @discardableResult
    static func finishInterrupted(in destination: URL) -> Int {
        let fm = FileManager.default
        let list = destination.appendingPathComponent(listName)
        guard let data = fm.contents(atPath: list.path) else { return 0 }
        var removed = 0
        for e in (try? JSONDecoder().decode([ListEntry].self, from: data)) ?? [] {
            let url = destination.appendingPathComponent(e.folder).appendingPathComponent(e.name)
            guard let a = try? fm.attributesOfItem(atPath: url.path), a[.type] as? FileAttributeType == .typeRegular else { continue }
            let size = (a[.size] as? NSNumber)?.uint64Value
            let date = (a[.modificationDate] as? Date)?.timeIntervalSince1970
            let whole = size == e.size && date.map { abs($0 - e.modified) <= 2 } == true
            if !whole, (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        try? fm.removeItem(at: list)
        return removed
    }
}

/// passes progress on no more often than `interval`, except when forced
final class MediaExportThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    private let interval: TimeInterval
    private let send: @Sendable (MediaExportProgress) -> Void

    init(interval: TimeInterval, _ send: @escaping @Sendable (MediaExportProgress) -> Void) {
        self.interval = interval; self.send = send
    }

    func callAsFunction(_ p: MediaExportProgress, force: Bool = false) {
        lock.lock()
        let now = Date()
        let go = force || now.timeIntervalSince(last) >= interval
        if go { last = now }
        lock.unlock()
        if go { send(p) }
    }
}
