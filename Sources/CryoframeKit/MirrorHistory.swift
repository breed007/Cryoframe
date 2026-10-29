//
//  MirrorHistory.swift
//  CryoframeKit
//
//  Earlier copies of a live mirror, kept as APFS clones of its disk image.
//
//  A mirror holds one copy, so a file deleted or damaged in the library is gone from
//  the mirror after the next run. At the end of each run that seals the mirror, its
//  disk image is cloned into `Mirror history/<stamp>/` beside it, with copies of the
//  manifest and the band table (see BandTable). An entry has the layout of a mirror's
//  own folder, so the checksum check, the read-only attach and Restore work on it as
//  they do on the mirror.
//
//  A clone shares its blocks with the image until a later run writes over them, so an
//  entry costs about what the runs after it wrote (measured on macOS 27.0.1: a clone
//  costs nothing at first, then the bytes each later run writes into the image). How
//  much a single entry holds on its own can't be read without deleting it, so what
//  history takes is shown as "about", from the bytes each run wrote.
//
//  The same sharing means history protects against deletes and bad updates, never
//  against the drive failing: decay in the mirror's bands is decay in every entry that
//  still shares them.
//
//  Only on an APFS drive connected to this Mac, whose volume can clone, and not in a
//  cloud folder, which would upload a whole copy for each entry. 1.7 doesn't know the
//  folder: its listings never go into it, its sweeps match only dated version folders,
//  and deleting a job takes it with the library's folder.
//

import Foundation

public enum MirrorHistoryError: Error, Equatable, LocalizedError {
    /// the entry's image is attached on this Mac, or whether it is couldn't be told
    case inUse(String)

    public var errorDescription: String? {
        switch self {
        case .inUse(let image):
            return "the earlier copy (\(image)) is open on this Mac, or that couldn't be told, so it was left in place; close what has it open and try again"
        }
    }
}

public enum MirrorHistory {
    /// the folder beside a mirror's disk image that holds its history
    public static let folderName = "Mirror history"
    /// an entry being made; renamed once complete, swept if a run died first
    static let partialSuffix = ".partial"
    /// what an entry records of the run that made it
    static let infoName = "cryoframe-history.v1"
    /// in an entry made before its mirror was started over: why the old image was
    /// found decayed then, or nothing when it wasn't (see markStartedOver)
    static let startedOverName = ".cryoframe-history-started-over"

    public static let defaultNights = 7
    /// what the job editor offers: off, or the nights to keep
    public static let choices = [0, 7, 14, 30]

    /// one earlier copy of a mirror
    public struct Entry: Sendable, Equatable, Identifiable {
        public var id: String { dir.path }
        public let dir: URL
        public let date: Date
        /// the bytes written into the mirror by the run that made it, and by the runs
        /// of any entries removed since the one before it; nil when not recorded
        public let written: UInt64?
        /// of what its own run wrote, what wasn't the library growing: files changed and
        /// written again (see writeEstimate); nil when not recorded
        public let rewrote: UInt64?
        /// the library's size when its run copied it; nil when not recorded
        public let library: UInt64?

        /// made before the mirror was started over: why its image was decayed then, or
        /// "" when it wasn't; nil when it was made of the image the mirror has now
        public let startedOver: String?

        /// a clone of the image a start over replaced, not of the one the mirror has now
        public var madeBeforeStartOver: Bool { startedOver != nil }

        public init(dir: URL, date: Date, written: UInt64?, rewrote: UInt64? = nil, library: UInt64? = nil,
                    startedOver: String? = nil) {
            self.dir = dir; self.date = date; self.written = written; self.rewrote = rewrote; self.library = library
            self.startedOver = startedOver
        }
    }

    public static func folder(in dir: URL) -> URL {
        dir.appendingPathComponent(folderName, isDirectory: true)
    }

    /// the complete entries beside the mirror in `dir`, newest first. An entry still
    /// being made, or left part made, isn't one.
    public static func entries(in dir: URL) -> [Entry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder(in: dir).path)) ?? []
        return names.compactMap { name -> Entry? in
            guard let date = VersionStamp.date(name) else { return nil }
            let entry = folder(in: dir).appendingPathComponent(name, isDirectory: true)
            guard FileManager.default.fileExists(atPath: entry.appendingPathComponent(ArchiveManifest.sidecarName).path) else { return nil }
            return Entry(dir: entry, date: date, written: recorded(writtenKey, in: entry), rewrote: recorded(rewroteKey, in: entry),
                         library: recorded(libraryKey, in: entry), startedOver: startedOver(entry))
        }.sorted { $0.date > $1.date }
    }

    // MARK: what it takes

    /// About what `entry` alone holds on the drive: what the runs after it wrote, up to
    /// the next entry (whose record carries them). The newest shares everything with
    /// the mirror, so it holds about nothing until the next run. Entries made before a
    /// start over are clones of the old image, so they are counted among themselves.
    public static func aboutBytes(of entry: Entry, among entries: [Entry]) -> UInt64 {
        let newestFirst = entries.filter { $0.madeBeforeStartOver == entry.madeBeforeStartOver }.sorted { $0.date > $1.date }
        guard let i = newestFirst.firstIndex(where: { $0.dir == entry.dir }), i > 0 else { return 0 }
        return newestFirst[i - 1].written ?? 0
    }

    /// about what all of `entries` hold on the drive: what every run since the oldest wrote
    public static func aboutBytes(_ entries: [Entry]) -> UInt64 {
        entries.reduce(UInt64(0)) { sum, e in sum + aboutBytes(of: e, among: entries) }
    }

    // MARK: where it can be kept

    /// why history can't be kept on a drive
    public enum Unavailable: Sendable, Equatable {
        /// a cloud folder: each entry would be uploaded as a whole copy
        case cloud
        /// a network share: a server can't be counted on to clone
        case network
        /// a drive that can't clone (exFAT, FAT32, Mac OS Extended, an APFS volume that says it can't)
        case noClones(described: String)
    }

    /// whether history can be kept on a drive of `profile` that `clones` or not (pure)
    public static func unavailable(_ profile: FileSystemProfile, clones: Bool) -> Unavailable? {
        switch profile.kind {
        case .cloud: return .cloud
        case .network: return .network
        case .apfs: return clones ? nil : .noClones(described: profile.described)
        case .hfs, .exfat, .fat32, .other: return .noClones(described: profile.described)
        }
    }

    /// whether history can be kept in `dir`, a destination of `target`
    public static func unavailable(at dir: URL, target: Target?) -> Unavailable? {
        unavailable(FileSystemProfile.of(dir, target: target), clones: clones(dir))
    }

    /// whether the volume holding `dir` (or its nearest existing folder) can clone
    static func clones(_ dir: URL) -> Bool {
        var url = dir
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" { url.deleteLastPathComponent() }
        url.removeAllCachedResourceValues()
        return (try? url.resourceValues(forKeys: [.volumeSupportsFileCloningKey]))?.volumeSupportsFileCloning == true
    }

    // MARK: what goes

    /// The entries to remove to keep `nights`: the newest entry of each of the last
    /// `nights` days a run made one. The newest entry is always kept.
    public static func doomed(_ dates: [Date], nights: Int, calendar: Calendar = .current) -> Set<Date> {
        guard nights > 0 else { return [] }
        return retentionPrune(dates, policy: .gfs(daily: nights, weekly: 0, monthly: 0), calendar: calendar)
    }

    /// The entries removed, oldest first, to make room for the mirror: one at a time
    /// until `fits` says the run fits, or none is left. The mirror always comes first,
    /// but only when it would fit with every entry gone (`fitsWithAllGone`): removing
    /// history for a run that can't fit anyway lost it all for nothing. `remove` says
    /// whether an entry went; one that wouldn't go ends it there, as the next is newer
    /// and holds no more.
    static func makeRoom(_ entries: [Entry], fits: () -> Bool, fitsWithAllGone: () -> Bool = { true },
                         remove: (Entry) -> Bool) -> [Entry] {
        guard !entries.isEmpty, !fits(), fitsWithAllGone() else { return [] }
        var gone: [Entry] = []
        for e in entries.sorted(by: { $0.date < $1.date }) {
            if fits() { break }
            guard remove(e) else { break }
            gone.append(e)
        }
        return gone
    }

    /// About what the next run of a mirror whose library is now `library` bytes will
    /// write into its image: what the library grew by since the newest entry, and what
    /// that entry's run wrote again of files that changed. nil when there is no history.
    ///
    /// With history, every block written into the image takes new room on the drive,
    /// since a clone still holds the block it replaces (measured on macOS 27.0.1: +32 MB
    /// for 32 MB written over), so the room check counts it all (see
    /// SparseBundleMirrorEngine.roomVerdict). Without history, files written over reuse
    /// the room the copies they replace gave back inside the image.
    /// Entries made before a start over are clones of the old image, so they share
    /// nothing with the new one and don't count.
    static func writeEstimate(_ entries: [Entry], library: UInt64) -> UInt64? {
        guard let newest = sharing(entries).max(by: { $0.date < $1.date }) else { return nil }
        let grown = newest.library.map { library > $0 ? library - $0 : 0 } ?? 0
        return grown + (newest.rewrote ?? 0)
    }

    /// what of `written` wasn't the library growing from `before` to `library` bytes.
    /// With no entry before it to say (the first, the first since history was off, or
    /// the first since a start over), it is all taken as growth: counting a first
    /// run's whole copy as written over would have the next run remove all the history
    /// it has for room it doesn't need.
    static func rewrote(written: UInt64, library: UInt64, before: UInt64?) -> UInt64 {
        let base = before ?? 0
        let grown = library > base ? library - base : 0
        return written > grown ? written - grown : 0
    }

    /// the entries that are clones of the image the mirror has now
    static func sharing(_ entries: [Entry]) -> [Entry] { entries.filter { !$0.madeBeforeStartOver } }

    /// About what removing all of `entries` would give back to the drive. Those made
    /// before a start over share the old image's blocks while it is kept aside
    /// (`oldImageKept`); once it is gone, the newest of them holds all of it.
    static func roomFreed(byRemoving entries: [Entry], oldImageKept: Bool) -> UInt64 {
        let old = entries.filter(\.madeBeforeStartOver)
        let alone = oldImageKept ? 0 : old.max(by: { $0.date < $1.date }).flatMap { image(in: $0.dir) }.map(Checksum.byteSize) ?? 0
        return aboutBytes(entries) + alone
    }

    /// the disk image in the entry `dir`
    static func image(in dir: URL) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.sorted().first { !$0.hasPrefix(".") && $0.hasSuffix(".sparsebundle") }
            .map { dir.appendingPathComponent($0, isDirectory: true) }
    }

    // MARK: a mirror started over

    /// Mark the entries in `dir` as made before its mirror was started over: they are
    /// clones of the old image, not of the new one. `decay`: why the old image was
    /// found decayed, if it was. Decay is in the drive's blocks, which the entries
    /// share, so it stays said of them after the mirror's own marks are cleared (see
    /// restoreWarning); a mirror started over after its drive filled is damaged in
    /// writes the entries never shared. Throws when one can't be marked, so the start
    /// over doesn't go ahead with entries that would restore without a word.
    static func markStartedOver(in dir: URL, decay: String?) throws {
        for e in entries(in: dir) where !e.madeBeforeStartOver {
            try Data((decay ?? "").utf8).write(to: e.dir.appendingPathComponent(startedOverName), options: .atomic)
        }
    }

    /// what the start-over mark in the entry `dir` says; nil when it has none
    static func startedOver(_ dir: URL) -> String? {
        (try? Data(contentsOf: dir.appendingPathComponent(startedOverName)))
            .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// What Restore says before it uses the entry at `entry` of the mirror in `mirror`,
    /// when the entry may hold decay: it was made of an image found decayed and since
    /// started over, or of the mirror's image, which is decayed now. nil otherwise.
    public static func restoreWarning(entry: URL, mirror: URL) -> String? {
        if let over = startedOver(entry) {
            guard !over.isEmpty else { return nil }
            return "This earlier copy was made before the mirror was started over, when the mirror was found decayed (\(over)). It shares the same parts of the drive, so it may hold the same damage."
        }
        guard MirrorSeal.isDecayed(mirror), let why = MirrorSeal.damage(in: mirror) else { return nil }
        return "The current mirror was found decayed (\(why)). This earlier copy shares the same parts of the drive, so it may hold the same damage."
    }

    /// what a run says of the entries it removed to make room
    static func roomNote(_ gone: [Entry]) -> String? {
        guard let oldest = gone.map(\.date).min(), let newest = gone.map(\.date).max() else { return nil }
        let day = { (d: Date) in d.formatted(date: .abbreviated, time: .omitted) }
        let span = Calendar.current.isDate(oldest, inSameDayAs: newest) ? day(oldest) : "\(day(oldest)) to \(day(newest))"
        return "removed the mirror's history from \(span) to make room for the mirror itself"
    }

    // MARK: making and removing

    /// Clone the sealed image `bundle`, with the manifest and band table beside it in
    /// `dir`, into a new entry stamped `date`. Made under a `.partial` name and renamed
    /// once whole, so a crash never leaves an entry that looks complete. nil when an
    /// entry of that stamp is already there.
    @discardableResult
    static func save(bundle: URL, in dir: URL, written: UInt64, library: UInt64? = nil, at date: Date) throws -> Entry? {
        let fm = FileManager.default
        let history = folder(in: dir)
        try fm.createDirectory(at: history, withIntermediateDirectories: true)
        let stamp = VersionStamp.string(date)
        let entry = history.appendingPathComponent(stamp, isDirectory: true)
        guard !fm.fileExists(atPath: entry.path) else { return nil }
        let partial = history.appendingPathComponent(stamp + partialSuffix, isDirectory: true)
        // what of this run's write wasn't the library growing since the newest entry of
        // this image: after a start over the first one's whole copy is growth
        let rewrote = library.map { rewrote(written: written, library: $0, before: sharing(entries(in: dir)).first?.library) }
        try? fm.removeItem(at: partial)
        try fm.createDirectory(at: partial, withIntermediateDirectories: false)
        do {
            try clone(bundle, to: partial.appendingPathComponent(bundle.lastPathComponent))
            try fm.copyItem(at: dir.appendingPathComponent(ArchiveManifest.sidecarName),
                            to: partial.appendingPathComponent(ArchiveManifest.sidecarName))
            let bands = dir.appendingPathComponent(BandTable.fileName)
            if fm.fileExists(atPath: bands.path) {
                try fm.copyItem(at: bands, to: partial.appendingPathComponent(BandTable.fileName))
            }
            try record(written: written, rewrote: rewrote, library: library, in: partial)
            try fm.moveItem(at: partial, to: entry)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        return Entry(dir: entry, date: date, written: written, rewrote: rewrote, library: library)
    }

    /// clonefile(2) of a whole folder: its blocks are shared, not copied
    static func clone(_ src: URL, to dst: URL) throws {
        guard clonefile(src.path, dst.path, UInt32(CLONE_NOFOLLOW)) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: dst.path,
                                                           NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)])
        }
    }

    /// remove what a run that died while making an entry left
    static func sweepPartials(in dir: URL) {
        let history = folder(in: dir)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: history.path)) ?? [] where name.hasSuffix(partialSuffix) {
            try? FileManager.default.removeItem(at: history.appendingPathComponent(name))
        }
    }

    /// Remove `entry`. What its run wrote is then held by the next newer entry, which
    /// takes it into its own record, so the sizes shown stay about right.
    ///
    /// Refused while its image is attached (a restore of it, say), or when that can't
    /// be told: removing the bands under an open restore failed it part way. It is
    /// renamed to a part-made entry first, so a removal cut short leaves what the next
    /// run sweeps (see sweepPartials), never an entry without its manifest that nothing
    /// lists or one half gone that won't restore.
    public static func remove(_ entry: Entry, in dir: URL, runner: CommandRunner = ProcessCommandRunner()) throws {
        let fm = FileManager.default
        if let image = image(in: entry.dir) {
            let target = image.resolvingSymlinksInPath().path
            guard let attached = MirrorMounts.attachedImagesIfKnown(runner: runner),
                  !attached.contains(where: { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == target }) else {
                throw MirrorHistoryError.inUse(image.path)
            }
        }
        let all = entries(in: dir)
        let going = folder(in: dir).appendingPathComponent(entry.dir.lastPathComponent + partialSuffix, isDirectory: true)
        try? fm.removeItem(at: going)
        try fm.moveItem(at: entry.dir, to: going)
        if let newer = all.filter({ $0.date > entry.date }).min(by: { $0.date < $1.date }) {
            try? record(written: (newer.written ?? 0) + (entry.written ?? 0), rewrote: newer.rewrote, library: newer.library, in: newer.dir)
        }
        try fm.removeItem(at: going)
        rmdir(folder(in: dir).path)         // only once nothing is left in it
    }

    /// keep `nights` of history in `dir`; what couldn't be removed, said for the run
    static func prune(in dir: URL, nights: Int) -> [String] {
        let all = entries(in: dir)
        let going = doomed(all.map(\.date), nights: nights)
        var failures: [String] = []
        for e in all.reversed() where going.contains(e.date) {
            do { try remove(e, in: dir) }
            catch { failures.append("couldn't remove the mirror's history from \(e.date.formatted(date: .abbreviated, time: .shortened)): \(error.localizedDescription)") }
        }
        return failures
    }

    // MARK: an entry's record

    private static let writtenKey = "written", rewroteKey = "rewrote", libraryKey = "library"

    /// a figure of an entry's record: its first line names the record, each after it
    /// is a name and a number, apart
    private static func recorded(_ name: String, in entry: URL) -> UInt64? {
        guard let data = try? Data(contentsOf: entry.appendingPathComponent(infoName)) else { return nil }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        guard lines.first == Substring(infoName) else { return nil }
        for line in lines.dropFirst() {
            let f = line.split(separator: "\t")
            if f.count == 2, f[0] == Substring(name) { return UInt64(f[1]) }
        }
        return nil
    }

    static func record(written: UInt64, rewrote: UInt64? = nil, library: UInt64? = nil, in entry: URL) throws {
        var lines = [infoName, writtenKey + "\t" + String(written)]
        if let rewrote { lines.append(rewroteKey + "\t" + String(rewrote)) }
        if let library { lines.append(libraryKey + "\t" + String(library)) }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: entry.appendingPathComponent(infoName), options: .atomic)
    }
}
