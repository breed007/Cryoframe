//
//  PlainCopy.swift
//  CryoframeKit
//
//  The "plain files" format: one up-to-date copy of a library as ordinary files and
//  folders, which any computer can read, with what was deleted from the library kept
//  beside it. In the library's folder at the destination:
//
//    <library folder>/<name>/                    the copy (the library's own folder name)
//    <library folder>/Removed items/<date>/…     what the library no longer holds
//    <library folder>/.cryoframe-library.json    whose folder this is (LibraryIdentity)
//    <library folder>/.cryoframe-copy-open       while a copy updated in place is changing
//    <library folder>/.cryoframe-staging/<name>  while a copy swapped in whole is being made
//
//  Nothing is deleted. An item gone from the library is moved into Removed items,
//  under the day it went, once the copy has been read back; a file that changed is
//  replaced (one copy, no history: history is what dated versions are for). Only the
//  person deletes removed items, in Storage.
//
//  How a copy is brought up to date depends on the drive (see FileSystemProfile):
//    - APFS on a drive of this Mac: a clone of the copy is updated beside it, read
//      back, and swapped in whole, as a mirror's is (see MirrorCopy). At every instant
//      the copy is complete. Only here can an app library (Photos…) be kept.
//    - Anywhere else (Mac OS Extended, exFAT, FAT32, a network drive, a cloud folder):
//      in place. A mark is written first and removed last, so a run stopped part way
//      leaves a copy Restore says may be part old and part new; nothing has moved to
//      Removed items then. Copying the whole library beside it was rejected: twice the
//      room, and no clones.
//
//  Names are compared as the drive compares them (see FileSystemProfile.identity): a
//  name whose capitals or accents changed is renamed, not removed and copied again,
//  and of two library items the drive can't tell apart, the one already in the copy
//  stays (or the first, by its bytes, in a new copy), every run, so a copy never
//  flips between them. The other isn't copied, and the run says so. So are a "._"
//  file beside its namesake on a drive that keeps "._" companions, a file too large
//  for the drive, a name the drive refuses, and what won't fit in a FAT32 folder.
//
//  Every step after the plan says how far it has got, and Stop ends each of them (see
//  RunStep): a first run of a large library to a card spent up to an hour in steps
//  that said nothing.
//

import Foundation

/// The names a plain-files copy uses in its library folder (see the top).
public enum PlainCopyLayout {
    public static let removedFolder = "Removed items"
    public static let openMark = ".cryoframe-copy-open"
    public static let staging = ".cryoframe-staging"
    /// the folder names are tried in while the plan is made
    static let nameProbe = ".cryoframe-names"

    /// the copy of the library called `name` in `folder`
    public static func copy(named name: String, in folder: URL) -> URL {
        folder.appendingPathComponent(name, isDirectory: true)
    }

    /// whether the last update of the copy in `folder` was stopped before it finished
    public static func isOpen(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(openMark).path)
    }

    /// the folder removed items go into, for a day
    static func removedDay(_ folder: URL, _ date: Date, calendar: Calendar = .current) -> URL {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let day = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        return folder.appendingPathComponent(removedFolder, isDirectory: true).appendingPathComponent(day, isDirectory: true)
    }
}

/// Why an item of the library isn't in the copy.
public enum PlainCopyExclusion: Sendable, Equatable {
    /// its name and `kept`'s are one name on this drive
    case sameName(kept: String)
    /// too large for this drive (FAT32, or a cloud provider's limit)
    case tooLarge(UInt64)
    /// a "._" file beside its namesake, on a drive that keeps "._" companions
    case companionName
    /// the drive refused its name
    case nameRefused
    /// a FAT32 folder has no room left for it
    case folderFull
    /// the library leaves it out of every backup (see ContentType.leavesOut); not said
    case leftOutByLibrary
}

/// What a plain-files copy will do, worked out before it changes anything.
struct PlainCopyPlan: Sendable, Equatable {
    enum Kind: Sendable, Equatable { case file, folder, link }
    struct Item: Sendable, Equatable {
        var rel: String
        var kind: Kind
        var size: UInt64
        /// in the copy now, as the same kind of item
        var inCopy: Bool
        /// the library item's modification date, seconds since 1970
        var modified: Int = 0
    }
    /// every library item copied, folders before what is in them
    var items: [Item] = []
    /// files and links rsync writes: new, or of another size or date
    var written: [String] = []
    var writtenBytes: UInt64 = 0
    /// room the copy needs on the drive, beyond what it takes now
    var room: UInt64 = 0
    /// renames in the copy, in order: the item at `from` (its folder already renamed)
    /// takes the name `to`, the library's spelling
    var renames: [(from: String, to: String)] = []
    /// items in the copy of another kind than the library's of that name: set aside
    /// in Removed items before the copy (rsync can't put a file where a folder is)
    var replaced: [String] = []
    /// items in the copy the library no longer holds
    var removed: [String] = []
    /// rsync's leftover temporary files from a run that was cut off
    var temps: [String] = []
    /// library items not copied, and why
    var excluded: [(rel: String, why: PlainCopyExclusion)] = []
    /// named pipes, sockets and devices (see MirrorCopy.isLeftOut)
    var leftOut: [String] = []
    /// folders the copy doesn't have yet
    var newFolders: [String] = []
    /// files dated outside what the drive keeps (see FileSystemProfile.dateRange):
    /// copied, and dated the nearest it keeps
    var outOfRange: [String] = []

    static func == (a: PlainCopyPlan, b: PlainCopyPlan) -> Bool {
        a.items == b.items && a.written == b.written && a.removed == b.removed && a.replaced == b.replaced
            && a.renames.map { [$0.from, $0.to] } == b.renames.map { [$0.from, $0.to] } && a.temps == b.temps
            && a.excluded.map(\.rel) == b.excluded.map(\.rel) && a.leftOut == b.leftOut && a.newFolders == b.newFolders
            && a.outOfRange == b.outOfRange
    }

    var excludedPaths: Set<String> { Set(excluded.map(\.rel)) }
}

/// Looks through a library and its copy, and says what a run will do (see PlainCopyPlan).
struct PlainCopyPlanner {
    let profile: FileSystemProfile
    /// whether the drive takes a name (see NameProbe); called only for names a drive
    /// that isn't a Mac's might refuse
    let accepts: (String) -> Bool
    let control: RunControl?
    /// whether a name like one of rsync's temporary files is taken for one (see
    /// isTemp): only when the copy is still marked by a run that was cut off, the only
    /// kind that leaves them. Otherwise it is the library's own (".backup.2026100201"
    /// beside "backup"), kept in Removed items when the library deletes it.
    let sweepsTemps: Bool
    /// what the library leaves out of its backups, relative to it (see ArchiveSource)
    let leftOutByLibrary: Set<String>

    init(profile: FileSystemProfile, accepts: @escaping (String) -> Bool = { _ in true }, control: RunControl? = nil,
         sweepsTemps: Bool = false, excluded: [String] = []) {
        self.profile = profile; self.accepts = accepts; self.control = control; self.sweepsTemps = sweepsTemps
        self.leftOutByLibrary = Set(excluded)
    }

    /// Characters a drive that isn't a Mac's may refuse in a name (Windows' rules). On
    /// macOS 27 FSKit's exFAT and FAT32 took them all; a network drive may not.
    static func mightBeRefused(_ name: String) -> Bool {
        name.unicodeScalars.contains { $0.value < 0x20 || "\\:*?\"<>|".unicodeScalars.contains($0) }
            || name.hasSuffix(".") || name.hasSuffix(" ")
    }

    /// whether `name` is one openrsync writes while it copies `of`: ".<of>.<10 letters
    /// and digits>" (measured: ".big.o4stnEmcy9"; a SIGKILL leaves it behind)
    static func isTemp(_ name: String, of siblings: Set<String>) -> Bool {
        guard name.hasPrefix("."), let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let tail = name[name.index(after: dot)...]
        guard tail.count == 10, tail.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return false }
        return siblings.contains(String(name[name.index(after: name.startIndex)..<dot]))
    }

    func plan(source: URL, copy: URL?) throws -> PlainCopyPlan {
        var plan = PlainCopyPlan()
        control?.begin("Comparing the library with its copy", stage: .preparing)
        var seen = 0
        try walk(source.path, rel: "", copyAt: copy?.path, into: &plan, seen: &seen)
        return plan
    }

    private func walk(_ sourceDir: String, rel: String, copyAt copyDir: String?, into plan: inout PlainCopyPlan,
                      seen: inout Int) throws {
        func join(_ name: String) -> String { rel.isEmpty ? name : rel + "/" + name }
        let names = PlainCopy.list(sourceDir).sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        let nameSet = Set(names)
        var copyNames = copyDir.map(PlainCopy.list) ?? []
        if !profile.keepsMacDetails {
            // a drive's own "._" companion of an item, never a library item
            let all = Set(copyNames)
            copyNames.removeAll { $0.hasPrefix("._") && all.contains(String($0.dropFirst(2))) }
        }
        let copyExact = Set(copyNames)
        var copyByIdentity: [String: String] = [:]
        for n in copyNames where copyByIdentity[profile.identity(of: n)] == nil { copyByIdentity[profile.identity(of: n)] = n }

        // what each library item is, and which are copied
        var stats: [String: stat] = [:]
        var groups: [String: [String]] = [:], order: [String] = []
        var allIdentities = Set<String>()
        for name in names {
            seen += 1
            if seen % 512 == 0, control?.isCancelled == true { throw CancelledError() }
            control?.advance()
            var st = stat()
            guard lstat(sourceDir + "/" + name, &st) == 0 else { continue }
            let id = profile.identity(of: name)
            allIdentities.insert(id)
            if leftOutByLibrary.contains(join(name)) { plan.excluded.append((join(name), .leftOutByLibrary)); continue }
            if MirrorCopy.isLeftOut(st.st_mode) { plan.leftOut.append(join(name)); continue }
            if !profile.keepsMacDetails, name.hasPrefix("._"), nameSet.contains(String(name.dropFirst(2))) {
                plan.excluded.append((join(name), .companionName)); continue
            }
            if st.st_mode & S_IFMT == S_IFREG, let limit = profile.maxFileSize, UInt64(max(st.st_size, 0)) >= limit {
                plan.excluded.append((join(name), .tooLarge(UInt64(st.st_size)))); continue
            }
            if !profile.keepsMacDetails, Self.mightBeRefused(name), !accepts(name) {
                plan.excluded.append((join(name), .nameRefused)); continue
            }
            stats[name] = st
            if groups[id] == nil { order.append(id) }
            groups[id, default: []].append(name)
        }
        // of names the drive takes for one, the one already in the copy, else the first
        var kept: [String] = []
        for id in order {
            let group = groups[id] ?? []
            let winner = group.first(where: { copyExact.contains($0) }) ?? group[0]
            kept.append(winner)
            for other in group where other != winner { plan.excluded.append((join(other), .sameName(kept: winner))) }
        }
        kept.sort { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        // what fits in a FAT32 folder: those already in the copy first
        if profile.kind == .fat32 {
            var budget = FileSystemProfile.fat32FolderEntries - (rel.isEmpty ? 0 : 2)
            var fits: [String] = []
            let byPlace = kept.filter { copyByIdentity[profile.identity(of: $0)] != nil } + kept.filter { copyByIdentity[profile.identity(of: $0)] == nil }
            for name in byPlace {
                let need = profile.fat32Entries(name)
                if need <= budget { budget -= need; fits.append(name) } else { plan.excluded.append((join(name), .folderFull)) }
            }
            let fitting = Set(fits)
            kept.removeAll { !fitting.contains($0) }
        }

        var matched = Set<String>()
        var changedPeak: UInt64 = 0
        for name in kept {
            guard let a = stats[name] else { continue }
            let itemRel = join(name)
            let id = profile.identity(of: name)
            var inCopy = false
            var b = stat()
            var copyPath: String?
            if let copyDir, let there = copyByIdentity[id] {
                matched.insert(id)
                if there != name { plan.renames.append((join(there), name)) }
                if lstat(copyDir + "/" + there, &b) == 0 {
                    if b.st_mode & S_IFMT == a.st_mode & S_IFMT {
                        inCopy = true
                        copyPath = copyDir + "/" + there
                    } else {
                        plan.replaced.append(itemRel)
                    }
                }
            }
            switch a.st_mode & S_IFMT {
            case S_IFDIR:
                plan.items.append(.init(rel: itemRel, kind: .folder, size: 0, inCopy: inCopy, modified: a.st_mtimespec.tv_sec))
                if !inCopy { plan.newFolders.append(itemRel); plan.room += profile.roomForFolder }
                try walk(sourceDir + "/" + name, rel: itemRel, copyAt: copyPath, into: &plan, seen: &seen)
            case S_IFLNK:
                plan.items.append(.init(rel: itemRel, kind: .link, size: 0, inCopy: inCopy, modified: a.st_mtimespec.tv_sec))
                let target = try? FileManager.default.destinationOfSymbolicLink(atPath: sourceDir + "/" + name)
                let current = copyPath.flatMap { try? FileManager.default.destinationOfSymbolicLink(atPath: $0) }
                if !inCopy || target != current { plan.written.append(itemRel); plan.room += profile.room(forFile: 0, new: !inCopy) }
            case S_IFREG:
                let size = UInt64(max(a.st_size, 0))
                plan.items.append(.init(rel: itemRel, kind: .file, size: size, inCopy: inCopy, modified: a.st_mtimespec.tv_sec))
                if profile.clamped(a.st_mtimespec.tv_sec) != a.st_mtimespec.tv_sec { plan.outOfRange.append(itemRel) }
                if !inCopy || b.st_size != a.st_size || !profile.sameDate(library: a.st_mtimespec.tv_sec, copy: b.st_mtimespec.tv_sec) {
                    plan.written.append(itemRel)
                    plan.writtenBytes += size
                    if inCopy {
                        // written beside the old file and renamed over it: both are on
                        // the drive for a moment, then the old one's room comes back
                        let old = profile.roundUp(UInt64(max(b.st_size, 0)))
                        let new = profile.roundUp(size)
                        if new > old { plan.room += new - old }
                        changedPeak = max(changedPeak, min(new, old))
                    } else {
                        plan.room += profile.room(forFile: size, new: true)
                    }
                }
            default:
                break
            }
        }
        plan.room += changedPeak
        // what the copy holds that the library doesn't (an item left out is still the
        // library's: what the copy has of it stays)
        if let copyDir {
            let siblings = nameSet
            for name in copyNames.sorted() where !matched.contains(profile.identity(of: name))
                && !allIdentities.contains(profile.identity(of: name)) {
                if sweepsTemps, Self.isTemp(name, of: siblings) { plan.temps.append(join(name)); continue }
                // Finder's own file, left by a look at the copy in Finder: not the library's
                if name == ".DS_Store" { continue }
                var st = stat()
                guard lstat(copyDir + "/" + name, &st) == 0 else { continue }
                plan.removed.append(join(name))
            }
        }
    }
}

/// Tries names on the drive (see PlainCopyPlanner.accepts): each is written in a
/// folder of its own beside the copy, looked for, and removed. What a drive does
/// with a name it takes but changes (lists back otherwise) counts as refused.
final class NameProbe: @unchecked Sendable {
    private let dir: URL
    private var answers: [String: Bool] = [:]
    private var made = false

    init(in folder: URL) { dir = folder.appendingPathComponent(PlainCopyLayout.nameProbe, isDirectory: true) }

    func accepts(_ name: String) -> Bool {
        if let known = answers[name] { return known }
        if !made { made = true; try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let path = dir.path + "/" + name
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        var ok = false
        if fd >= 0 {
            close(fd)
            ok = PlainCopy.list(dir.path).contains(name)
            unlink(path)
        }
        answers[name] = ok
        return ok
    }

    func finish() { if made { try? FileManager.default.removeItem(at: dir) } }
}

/// What a plain-files run did.
public struct PlainCopyOutcome: Sendable, Equatable {
    /// the copy
    public var copy: URL
    /// files written this run, and their bytes
    public var written: Int = 0
    public var writtenBytes: UInt64 = 0
    /// items moved into Removed items this run
    public var removed: Int = 0
    /// library items not copied, and why
    public var excluded: [String: PlainCopyExclusion] = [:]
    /// what the run says, for its warning
    public var notes: [String] = []
}

public enum PlainCopyError: Error, Equatable {
    /// the drive hasn't room for what the run would write
    case notEnoughRoom(needed: UInt64, free: UInt64, removedBytes: UInt64)
    /// the copy, read back from the drive, didn't match the library
    case readBackMismatch(count: Int, examples: [String])
    /// a name couldn't be put right, or an item moved to Removed items
    case couldNotMove(String, String)
    /// what an earlier run left beside the copy couldn't be removed
    case stagingStuck(String)
}

extension PlainCopyError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notEnoughRoom(let needed, let free, let removed):
            let hint = removed > 0
                ? " Removed items take \(JobExecutor.human(removed)) of it: delete those you no longer need in Storage." : ""
            return "not enough room on the drive: this update needs about \(JobExecutor.human(needed)), and \(JobExecutor.human(free)) is free.\(hint)"
        case .readBackMismatch(let count, let examples):
            return "the copy, read back from the drive, didn't match the library (\(count) item\(count == 1 ? "" : "s"): \(examples.joined(separator: "; "))). Run again; if it happens again, check the drive in Disk Utility."
        case .couldNotMove(let item, let why):
            return "couldn't move “\(item)” in the copy: \(why)"
        case .stagingStuck(let path):
            return "an unfinished copy an earlier run left at \(path) couldn't be removed; remove it and run again"
        }
    }
}

/// Brings a plain-files copy up to date (see the top).
public struct PlainCopy {
    let profile: FileSystemProfile
    let runner: CommandRunner
    let now: Date
    let calendar: Calendar
    /// free bytes on the drive (tests set it)
    let freeSpace: (URL) -> UInt64?
    /// whether files written get a "._" companion; nil: what the probe found (see
    /// DriveAllocation)
    let companions: Bool?
    /// whether the drive takes a name; nil: try it on the drive (see NameProbe)
    let accepts: ((String) -> Bool)?
    /// what a file written in a folder takes there, and whether it gets a companion;
    /// nil: a file is written there and measured (see DriveAllocation). On exFAT and
    /// FAT the room check counts what this measured, as statfs said 512 bytes for a
    /// drive of 128 KiB clusters on macOS 15; elsewhere the larger of the two.
    let probe: ((URL) -> DriveAllocation)?
    /// files given to one rsync, at most, so the copy can say how far it has got
    let batchFiles: Int
    let batchBytes: UInt64

    public init(profile: FileSystemProfile, runner: CommandRunner, now: Date = Date(), calendar: Calendar = .current,
                freeSpace: @escaping (URL) -> UInt64? = { JobExecutor.freeNow(for: $0) },
                companions: Bool? = nil, accepts: ((String) -> Bool)? = nil,
                probe: ((URL) -> DriveAllocation)? = nil,
                batchFiles: Int = 2_000, batchBytes: UInt64 = 1 << 30) {
        self.profile = profile; self.runner = runner; self.now = now; self.calendar = calendar
        self.freeSpace = freeSpace; self.companions = companions; self.accepts = accepts
        self.probe = probe
        self.batchFiles = max(batchFiles, 1); self.batchBytes = max(batchBytes, 1)
    }

    var control: RunControl? { runner.control }

    /// Bring the copy of `source` in `folder` (the library's folder) up to date.
    /// `listing`, when given, is handed every item the copy holds once it is up to
    /// date (Find a File's list; see ContentsListing). `excluded`: what the library
    /// leaves out of its backups (see ArchiveSource), copied by no run.
    public func run(_ source: URL, in folder: URL, listing: ContentsListing.Collector? = nil,
                    excluded: [String] = []) throws -> PlainCopyOutcome {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { throw ArchiveError.sourceMissing(source.path) }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        control?.endStep()
        defer { control?.endStep() }
        var profile = self.profile
        let probed = (probe ?? DriveAllocation.probe(at:))(folder)
        if profile.companions { profile.companions = companions ?? probed.companion ?? true }
        profile.cluster = DriveAllocation.cluster(statfsBlockSize: profile.cluster, fsType: profile.fsType, probed: probed)
        let (outcome, plan) = profile.swapsWholeCopy ? try swapped(source, in: folder, profile: profile, excluded: excluded)
                                                     : try inPlace(source, in: folder, profile: profile, excluded: excluded)
        if let listing {
            for item in plan.items {
                listing.add(item.rel, size: item.size, modified: Date(timeIntervalSince1970: TimeInterval(item.modified)),
                            kind: item.kind == .folder ? .folder : item.kind == .link ? .link : .file)
            }
        }
        return outcome
    }

    // MARK: updated in place

    private func inPlace(_ source: URL, in folder: URL, profile: FileSystemProfile,
                         excluded: [String]) throws -> (PlainCopyOutcome, PlainCopyPlan) {
        let fm = FileManager.default
        let copy = PlainCopyLayout.copy(named: source.lastPathComponent, in: folder)
        let probe = NameProbe(in: folder)
        defer { probe.finish() }
        let planner = PlainCopyPlanner(profile: profile, accepts: accepts ?? probe.accepts, control: control,
                                       sweepsTemps: PlainCopyLayout.isOpen(folder), excluded: excluded)
        let plan = try planner.plan(source: source, copy: fm.fileExists(atPath: copy.path) ? copy : nil)
        try checkRoom(plan, folder: folder)

        // from here the copy changes: marked until the run has finished (see the top)
        try Self.mark(folder)
        try fm.createDirectory(at: copy, withIntermediateDirectories: true)
        for rel in plan.temps {
            let path = copy.appendingPathComponent(rel).path
            Self.withOwnerWrite([(path as NSString).deletingLastPathComponent]) { _ = unlink(path) }
        }
        try rename(plan.renames, in: copy)
        var outcome = PlainCopyOutcome(copy: copy)
        outcome.removed += try moveToRemoved(plan.replaced, from: copy, in: folder, title: "Setting aside items replaced by another kind")
        for rel in plan.newFolders {
            // in a folder its owner can't write to, kept so on a Mac's drive
            let url = copy.appendingPathComponent(rel)
            try Self.withOwnerWrite([url.deletingLastPathComponent().path]) {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }

        if profile.keepsMacDetails {
            control?.begin("Copying what changed", stage: .archiving)
            try MirrorCopy.sync(source, into: copy, runner: runner,
                                options: .init(excluded: plan.excluded.map(\.rel), inPlace: true), execute: execute)
        } else {
            try copyFiles(plan, from: source, to: copy, profile: profile)
            try finishDates(plan, from: source, to: copy)
        }
        datesTheDriveKeeps(plan, in: copy, profile: profile)
        // pushed to the drive before it is read back: a step of its own, which can't be
        // stopped part way (sync(2)), so it says what it is doing
        control?.begin("Writing the copy out to the drive", stage: .finishing)
        MirrorCopy.flush(volume: copy)
        try readBack(plan, source: source, copy: copy, profile: profile)
        outcome.removed += try moveToRemoved(plan.removed, from: copy, in: folder, title: "Moving deleted items to Removed items")
        Self.unmark(folder)
        return (finished(outcome, plan), plan)
    }

    /// rsync the files the plan writes, a batch at a time, so the step can count them
    private func copyFiles(_ plan: PlainCopyPlan, from source: URL, to copy: URL, profile: FileSystemProfile) throws {
        let fm = FileManager.default
        control?.begin("Copying", stage: .archiving, unit: .bytes, total: plan.writtenBytes)
        guard !plan.written.isEmpty else { return }
        let lists = fm.temporaryDirectory.appendingPathComponent("cf-plain-\(UUID().uuidString)")
        try fm.createDirectory(at: lists, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: lists) }
        let sizes = Dictionary(plan.items.map { ($0.rel, $0.size) }, uniquingKeysWith: { a, _ in a })
        var batch: [String] = [], bytes: UInt64 = 0
        func send() throws {
            guard !batch.isEmpty else { return }
            if control?.isCancelled == true { throw CancelledError() }
            let list = lists.appendingPathComponent("files")
            // "./" first: openrsync reads a line starting with "#" or ";" as a comment
            try Data(batch.map { "./" + $0 + "\0" }.joined().utf8).write(to: list)
            var args = ["-lt", "-0", "--files-from=\(list.path)"]
            if profile.modifyWindow { args.append("--modify-window=1") }
            try execute(Command("/usr/bin/rsync", args + [source.path + "/", copy.path + "/"]))
            control?.advance(by: bytes)
            batch = []; bytes = 0
        }
        for rel in plan.written {
            batch.append(rel); bytes += sizes[rel] ?? 0
            if batch.count >= batchFiles || bytes >= batchBytes { try send() }
        }
        try send()
    }

    /// files given their library dates where the drive rounded them, and folders theirs,
    /// deepest first (what was copied into a folder changed its date)
    private func finishDates(_ plan: PlainCopyPlan, from source: URL, to copy: URL) throws {
        let folders = plan.items.filter { $0.kind == .folder }.map(\.rel).reversed() + [""]
        control?.begin("Finishing the copy", stage: .finishing, total: UInt64(folders.count))
        for (n, rel) in folders.enumerated() {
            if n % 512 == 0, control?.isCancelled == true { throw CancelledError() }
            control?.advance()
            let from = rel.isEmpty ? source.path : source.appendingPathComponent(rel).path
            let to = rel.isEmpty ? copy.path : copy.appendingPathComponent(rel).path
            var a = stat(), b = stat()
            guard lstat(from, &a) == 0, lstat(to, &b) == 0, a.st_mtimespec.tv_sec != b.st_mtimespec.tv_sec else { continue }
            var times = [a.st_atimespec, a.st_mtimespec]
            _ = utimensat(AT_FDCWD, to, &times, AT_SYMLINK_NOFOLLOW)
        }
    }

    /// files dated outside what the drive keeps given the nearest date it keeps, so
    /// the copy is dated the same way every run and the read-back finds what it
    /// expects (see FileSystemProfile.dateRange). Folders aren't judged by date.
    private func datesTheDriveKeeps(_ plan: PlainCopyPlan, in copy: URL, profile: FileSystemProfile) {
        let modified = Dictionary(plan.items.map { ($0.rel, $0.modified) }, uniquingKeysWith: { a, _ in a })
        for rel in plan.outOfRange {
            guard let library = modified[rel] else { continue }
            let path = copy.appendingPathComponent(rel).path
            var b = stat()
            let date = profile.clamped(library)
            guard lstat(path, &b) == 0, b.st_mtimespec.tv_sec != date else { continue }
            let when = timespec(tv_sec: date, tv_nsec: 0)
            var times = [when, when]
            _ = utimensat(AT_FDCWD, path, &times, AT_SYMLINK_NOFOLLOW)
        }
    }

    /// Check the copy against the library: every item copied is there under the
    /// library's spelling, of the same kind, a file of the same size and date (the date
    /// the drive keeps for the library's: see FileSystemProfile.sameDate) and a link to
    /// the same place; and what this run wrote matches
    /// the library byte for byte. The drive's own companions, and what the copy holds
    /// that the library doesn't (moved to Removed items next), aren't judged.
    private func readBack(_ plan: PlainCopyPlan, source: URL, copy: URL, profile: FileSystemProfile) throws {
        let control = self.control
        var bad: [(String, String)] = []
        control?.begin("Checking the copy", stage: .verifying, total: UInt64(plan.items.count))
        var listings: [String: Set<String>] = [:]
        for (n, item) in plan.items.enumerated() {
            if n % 512 == 0, control?.isCancelled == true { throw CancelledError() }
            control?.advance()
            let parent = (item.rel as NSString).deletingLastPathComponent
            let name = (item.rel as NSString).lastPathComponent
            if listings[parent] == nil {
                listings[parent] = Set(Self.list(parent.isEmpty ? copy.path : copy.appendingPathComponent(parent).path))
            }
            guard listings[parent]?.contains(name) == true else {
                bad.append((item.rel, "is missing (or is spelled differently)")); continue
            }
            var a = stat(), b = stat()
            guard lstat(source.appendingPathComponent(item.rel).path, &a) == 0 else { continue }
            guard lstat(copy.appendingPathComponent(item.rel).path, &b) == 0, a.st_mode & S_IFMT == b.st_mode & S_IFMT else {
                bad.append((item.rel, "is the wrong kind of item")); continue
            }
            switch item.kind {
            case .link:
                let t1 = try? FileManager.default.destinationOfSymbolicLink(atPath: source.appendingPathComponent(item.rel).path)
                let t2 = try? FileManager.default.destinationOfSymbolicLink(atPath: copy.appendingPathComponent(item.rel).path)
                if t1 != t2 { bad.append((item.rel, "points somewhere else")) }
            case .file:
                if a.st_size != b.st_size || !profile.sameDate(library: a.st_mtimespec.tv_sec, copy: b.st_mtimespec.tv_sec) {
                    bad.append((item.rel, "has the wrong size or date"))
                }
            case .folder:
                break
            }
        }
        if profile.keepsMacDetails {
            // a Mac's drive keeps extended attributes and access lists: checked as a
            // mirror's are (see MirrorCopy.verify)
            let present = [""] + plan.items.filter { $0.kind != .link }.map(\.rel)
            control?.begin("Checking attributes", stage: .verifying, total: UInt64(present.count))
            bad += MirrorCopy.inParallel(present, control: control) { rel, _, _, _ in
                defer { control?.advance() }
                return MirrorCopy.differentAttributes(rel.isEmpty ? source.path : source.appendingPathComponent(rel).path,
                                                      rel.isEmpty ? copy.path : copy.appendingPathComponent(rel).path)
            }
        }
        let files = Set(plan.items.filter { $0.kind == .file }.map(\.rel))
        let written = plan.written.filter { files.contains($0) }
        control?.begin("Reading the copy back", stage: .verifying, unit: .bytes, total: plan.writtenBytes)
        bad += MirrorCopy.inParallel(written, control: control) { rel, x, y, size in
            MirrorCopy.byteDifference(source.appendingPathComponent(rel).path, copy.appendingPathComponent(rel).path,
                                      x, y, size, control: control, uncached: true)
        }
        if control?.isCancelled == true { throw CancelledError() }
        guard bad.isEmpty else {
            var seen = Set<String>(), examples: [String] = []
            for (rel, what) in bad where seen.insert(rel).inserted && examples.count < 3 { examples.append("\(rel) \(what)") }
            throw PlainCopyError.readBackMismatch(count: Set(bad.map(\.0)).count, examples: examples)
        }
    }

    // MARK: swapped in whole

    private func swapped(_ source: URL, in folder: URL, profile: FileSystemProfile,
                         excluded: [String]) throws -> (PlainCopyOutcome, PlainCopyPlan) {
        let fm = FileManager.default
        let name = source.lastPathComponent
        let current = PlainCopyLayout.copy(named: name, in: folder)
        let staging = folder.appendingPathComponent(PlainCopyLayout.staging, isDirectory: true)
        let next = staging.appendingPathComponent(name, isDirectory: true)
        // never start from what an earlier run left (see MirrorCopy.stage)
        if fm.fileExists(atPath: staging.path) {
            control?.begin("Removing an unfinished copy an earlier run left", stage: .preparing)
            MirrorCopy.removeStaging(staging, runner: runner.forTeardown, control: control)
            if control?.isCancelled == true { throw CancelledError() }
            if fm.fileExists(atPath: staging.path) { throw PlainCopyError.stagingStuck(staging.path) }
        }
        let planner = PlainCopyPlanner(profile: profile, control: control, excluded: excluded)
        let plan = try planner.plan(source: source, copy: fm.fileExists(atPath: current.path) ? current : nil)
        try checkRoom(plan, folder: folder)

        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let staged = MirrorCopy.Staged(volume: folder, current: current, staging: staging, next: next)
        do {
            if fm.fileExists(atPath: current.path) {
                control?.begin("Copying what changed", stage: .archiving)
                try MirrorCopy.clone(current, to: next, runner: runner)
                try rename(plan.renames, in: next)
            } else {
                try fm.createDirectory(at: next, withIntermediateDirectories: true)
            }
            control?.begin("Copying what changed", stage: .archiving)
            try MirrorCopy.sync(source, into: next, runner: runner, options: .init(excluded: plan.excluded.map(\.rel)),
                                execute: execute)
            control?.begin("Writing the copy out to the drive", stage: .finishing)
            MirrorCopy.flush(volume: folder)
            try MirrorCopy.verify(staged, against: source, control: control, excluded: plan.excludedPaths, uncached: true)
        } catch {
            if !(error is CancelledError) {
                control?.begin("Removing the unfinished copy", stage: .finishing)
                MirrorCopy.removeStaging(staging, runner: runner.forTeardown, control: control)
            }
            throw error
        }
        // what the library no longer holds is kept before the previous copy goes: a
        // clone of each, which costs no room; one already there (a run that stopped
        // after this) stays as it is
        var outcome = PlainCopyOutcome(copy: current)
        outcome.removed = try cloneToRemoved(plan.removed + plan.replaced, from: current, in: folder)
        try MirrorCopy.putInPlace(next, current)
        control?.begin("Removing the previous copy", stage: .finishing)
        MirrorCopy.removeStaging(staging, runner: runner, control: control)
        return (finished(outcome, plan), plan)
    }

    // MARK: steps

    /// refuse a run the drive hasn't room for, before anything is written
    private func checkRoom(_ plan: PlainCopyPlan, folder: URL) throws {
        guard plan.room > 0, let free = freeSpace(folder), free < plan.room else { return }
        let removed = folder.appendingPathComponent(PlainCopyLayout.removedFolder)
        let removedBytes = FileManager.default.fileExists(atPath: removed.path) ? JobExecutor.directorySize(removed) : 0
        throw PlainCopyError.notEnoughRoom(needed: plan.room, free: free, removedBytes: removedBytes)
    }

    /// put right the names whose capitals or accents changed in the library. On a drive
    /// that folds case a rename to the same name differently spelled goes through a
    /// temporary name.
    private func rename(_ renames: [(from: String, to: String)], in copy: URL) throws {
        guard !renames.isEmpty else { return }
        control?.begin("Putting right names whose capitals or accents changed", stage: .preparing, total: UInt64(renames.count))
        for r in renames {
            if control?.isCancelled == true { throw CancelledError() }
            control?.advance()
            let from = copy.appendingPathComponent(r.from).path
            let to = (from as NSString).deletingLastPathComponent + "/" + r.to
            let temp = (from as NSString).deletingLastPathComponent + "/.cryoframe-rename-" + UUID().uuidString
            if let why = Self.move(from, to: temp) { throw PlainCopyError.couldNotMove(r.from, why) }
            if let why = Self.move(temp, to: to) {
                _ = Self.move(temp, to: from)
                throw PlainCopyError.couldNotMove(r.from, why)
            }
        }
    }

    /// move each of `rels` in the copy into Removed items, under today, keeping where
    /// it was. One rename each, so a Stop leaves each item in one place or the other;
    /// each deletion is kept under a name of its own (see RemovedItems.place).
    private func moveToRemoved(_ rels: [String], from copy: URL, in folder: URL, title: String) throws -> Int {
        guard !rels.isEmpty else { return 0 }
        control?.begin(title, stage: .finishing, total: UInt64(rels.count))
        let day = PlainCopyLayout.removedDay(folder, now, calendar: calendar)
        var moved = 0
        for rel in rels {
            if control?.isCancelled == true { throw CancelledError() }
            control?.advance()
            let to = try RemovedItems.place(rel, in: day)
            if let why = Self.move(copy.appendingPathComponent(rel).path, to: to.path) { throw PlainCopyError.couldNotMove(rel, why) }
            moved += 1
        }
        return moved
    }

    /// a clone of each of `rels` in the copy, in Removed items under today (see
    /// swapped). One a run stopped after this already kept (the previous copy is
    /// still in place then) isn't kept twice.
    private func cloneToRemoved(_ rels: [String], from copy: URL, in folder: URL) throws -> Int {
        try RemovedItems.keep(rels, from: copy, in: folder, now: now, calendar: calendar, runner: runner)
    }

    /// Rename `from` to `to`; nil once done, else why not. A Mac's drive keeps a
    /// library's read-only folders (0555) and locked items as they are, and neither
    /// can be renamed out of or into as it is: the folders on either side, and a
    /// folder being moved (whose ".." changes), get owner write access for the move,
    /// and a locked item is unlocked; each is put back as it was afterwards.
    static func move(_ from: String, to: String) -> String? {
        let fromDir = (from as NSString).deletingLastPathComponent, toDir = (to as NSString).deletingLastPathComponent
        var st = stat()
        guard lstat(from, &st) == 0 else { return String(cString: strerror(errno)) }
        let locked = st.st_flags & MirrorCopy.lockingFlags
        let isDir = st.st_mode & S_IFMT == S_IFDIR
        let selfMode = st.st_mode & 0o7777
        if Darwin.rename(from, to) == 0 { return nil }
        guard errno == EACCES || (errno == EPERM && locked != 0) else { return String(cString: strerror(errno)) }
        if locked != 0, lchflags(from, st.st_flags & ~MirrorCopy.lockingFlags) != 0 { return String(cString: strerror(errno)) }
        let opened = isDir && selfMode & S_IWUSR == 0 && chmod(from, selfMode | S_IWUSR) == 0
        let moved = withOwnerWrite([fromDir, toDir]) { Darwin.rename(from, to) == 0 ? 0 : errno }
        let at = moved == 0 ? to : from
        if opened { _ = chmod(at, selfMode) }
        if locked != 0 { _ = lchflags(at, st.st_flags) }
        return moved == 0 ? nil : String(cString: strerror(moved))
    }

    /// `body`, with each of `folders` its owner can't write to made writable for the
    /// owner while it runs, and put back after
    static func withOwnerWrite<T>(_ folders: [String], _ body: () throws -> T) rethrows -> T {
        var opened: [(String, mode_t)] = []
        for path in Set(folders) {
            var st = stat()
            guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_mode & S_IWUSR == 0 else { continue }
            if chmod(path, (st.st_mode & 0o7777) | S_IWUSR) == 0 { opened.append((path, st.st_mode & 0o7777)) }
        }
        defer { for (path, mode) in opened { _ = chmod(path, mode) } }
        return try body()
    }

    /// what the run says of what it left out and what the drive keeps
    private func finished(_ outcome: PlainCopyOutcome, _ plan: PlainCopyPlan) -> PlainCopyOutcome {
        var out = outcome
        out.written = plan.written.count
        out.writtenBytes = plan.writtenBytes
        for (rel, why) in plan.excluded { out.excluded[rel] = why }
        out.notes = Self.notes(plan.excluded)
        if let note = Self.datesNote(plan.outOfRange, profile: profile) { out.notes.append(note) }
        return out
    }

    /// The run's words for files dated outside what the drive keeps (see
    /// FileSystemProfile.dateRange): copied, and dated the nearest it keeps.
    static func datesNote(_ rels: [String], profile: FileSystemProfile) -> String? {
        guard !rels.isEmpty, let range = profile.dateRange else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? utc.timeZone
        let first = utc.component(.year, from: Date(timeIntervalSince1970: TimeInterval(range.lowerBound)))
        let last = utc.component(.year, from: Date(timeIntervalSince1970: TimeInterval(range.upperBound))) - 1
        let shown = rels.prefix(3).map { "“\($0)”" }.joined(separator: ", ") + (rels.count > 3 ? " and \(rels.count - 3) more" : "")
        let files = rels.count == 1 ? "1 file is" : "\(rels.count) files are"
        return "\(files) dated before \(first) or after \(last) (\(shown)), which \(profile.described) can't keep. They are copied, with the nearest date it keeps."
    }

    /// The run's words for what it left out, one line per reason.
    static func notes(_ excluded: [(rel: String, why: PlainCopyExclusion)]) -> [String] {
        func items(_ n: Int) -> String { n == 1 ? "1 item wasn't copied" : "\(n) items weren't copied" }
        func named(_ rels: [String]) -> String {
            let shown = rels.prefix(3).map { "“\($0)”" }.joined(separator: ", ")
            return rels.count > 3 ? "\(shown) and \(rels.count - 3) more" : shown
        }
        var out: [String] = []
        let same = excluded.filter { if case .sameName = $0.why { return true }; return false }.map(\.rel)
        if !same.isEmpty {
            out.append("\(items(same.count)) (\(named(same))): their names differ only in capitals or accents from another's, which this drive can't tell apart. Rename one of them to copy both.")
        }
        let large = excluded.filter { if case .tooLarge = $0.why { return true }; return false }.map(\.rel)
        if !large.isEmpty {
            out.append("\(items(large.count)) (\(named(large))): too large for this drive. An exFAT or Mac drive can take them.")
        }
        let companion = excluded.filter { $0.why == .companionName }.map(\.rel)
        if !companion.isEmpty {
            out.append("\(items(companion.count)) (\(named(companion))): this drive keeps its own hidden files of those names. A Mac drive can take them.")
        }
        let refused = excluded.filter { $0.why == .nameRefused }.map(\.rel)
        if !refused.isEmpty {
            out.append("\(items(refused.count)) (\(named(refused))): this drive doesn't take their names. Rename them to copy them.")
        }
        let full = excluded.filter { $0.why == .folderFull }.map(\.rel)
        if !full.isEmpty {
            out.append("\(items(full.count)) (\(named(full))): a folder on a FAT32 drive can't hold that many items. An exFAT or Mac drive can take them.")
        }
        return out
    }

    private func execute(_ command: Command) throws {
        let r = try runner.run(command.tool, command.args, stdin: nil)
        if control?.isCancelled == true { throw CancelledError() }
        guard r.ok else {
            throw ArchiveError.toolFailed(tool: (command.tool as NSString).lastPathComponent, status: r.status, stderr: r.stderr)
        }
    }

    // MARK: helpers

    /// the names in a folder, as the drive lists them: Foundation's listings leave out
    /// "._" files on a drive that isn't a Mac's, and those matter here
    static func list(_ path: String) -> [String] {
        guard let dir = opendir(path) else { return [] }
        defer { closedir(dir) }
        var out: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if name != "." && name != ".." { out.append(name) }
        }
        return out
    }

    /// mark the copy as changing, on the drive before anything else is written
    static func mark(_ folder: URL) throws {
        let path = folder.appendingPathComponent(PlainCopyLayout.openMark).path
        let fd = open(path, O_WRONLY | O_CREAT, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        _ = fcntl(fd, F_FULLFSYNC)
        close(fd)
    }

    static func unmark(_ folder: URL) {
        unlink(folder.appendingPathComponent(PlainCopyLayout.openMark).path)
    }
}

/// What a plain-files copy keeps of what was deleted from its library: a folder for
/// each day in Removed items (see PlainCopy). Nothing prunes it but the person, in
/// Storage. A mirror of a library that keeps what is deleted from it (see
/// ContentType.keepsRemoved) keeps it the same way, at the top of its image:
///
///    <volume>/<name>                          the copy
///    <volume>/Removed items/<date>/<path>     what the library no longer holds
///
/// Restore copies <volume>/<name> alone; Browse shows both. A 1.6.0 run of the mirror
/// updates <volume>/.cryoframe-staging/<name> and swaps it in, and never touches
/// Removed items (it keeps no new ones meanwhile).
public enum RemovedItems {
    /// Where `rel` (a path in the copy) is kept in Removed items under `day`, its
    /// folders made as needed. Each deletion keeps a name of its own: a name already
    /// taken there (the same name deleted earlier that day) gets " (2)", " (3)" and so
    /// on, and so does a folder on the way whose name a file kept that day holds. A
    /// folder made read-only (kept so on a Mac's drive) is written into all the same.
    static func place(_ rel: String, in day: URL) throws -> URL {
        let parts = rel.split(separator: "/").map(String.init)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        var at = day
        for part in parts.dropLast() {
            var n = 1
            while true {
                let candidate = at.appendingPathComponent(numbered(part, n), isDirectory: true)
                var st = stat()
                if lstat(candidate.path, &st) != 0 {
                    try PlainCopy.withOwnerWrite([at.path]) {
                        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
                    }
                    at = candidate
                    break
                }
                if st.st_mode & S_IFMT == S_IFDIR { at = candidate; break }
                n += 1
            }
        }
        var n = 1
        while true {
            let candidate = at.appendingPathComponent(numbered(parts.last ?? rel, n))
            var st = stat()
            if lstat(candidate.path, &st) != 0 { return candidate }
            n += 1
        }
    }

    /// Whether `item` (in the copy, at `rel`) is already kept under `day`, as a run
    /// stopped after keeping it left it (see place): an item of the same kind there,
    /// a file of the same size and date, a link to the same place, a folder of the
    /// same names.
    static func alreadyKept(_ item: URL, as rel: String, in day: URL) -> Bool {
        let parts = rel.split(separator: "/").map(String.init)
        var at = day
        for part in parts.dropLast() {
            var n = 1, found = false
            while !found {
                let candidate = at.appendingPathComponent(numbered(part, n))
                var st = stat()
                guard lstat(candidate.path, &st) == 0 else { return false }
                if st.st_mode & S_IFMT == S_IFDIR { at = candidate; found = true } else { n += 1 }
            }
        }
        var a = stat()
        guard lstat(item.path, &a) == 0 else { return false }
        var n = 1
        while true {
            let candidate = at.appendingPathComponent(numbered(parts.last ?? rel, n))
            var b = stat()
            guard lstat(candidate.path, &b) == 0 else { return false }
            if a.st_mode & S_IFMT == b.st_mode & S_IFMT {
                switch a.st_mode & S_IFMT {
                case S_IFREG:
                    if a.st_size == b.st_size, a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec { return true }
                case S_IFLNK:
                    let fm = FileManager.default
                    if (try? fm.destinationOfSymbolicLink(atPath: item.path)) == (try? fm.destinationOfSymbolicLink(atPath: candidate.path)) {
                        return true
                    }
                case S_IFDIR:
                    if Set(PlainCopy.list(item.path)) == Set(PlainCopy.list(candidate.path)) { return true }
                default:
                    break
                }
            }
            n += 1
        }
    }

    /// `name`, or for `n` past 1 "name (n)", before any extension ("report (2).txt")
    static func numbered(_ name: String, _ n: Int) -> String {
        guard n > 1 else { return name }
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, !name.hasPrefix(".") || name.dropFirst().contains(".") else { return "\(name) (\(n))" }
        return "\((name as NSString).deletingPathExtension) (\(n)).\(ext)"
    }

    /// What `current` (the previous copy) holds that `next` (the new one, read back)
    /// doesn't, each the topmost such item, in order: what the library no longer
    /// holds. An item of another kind in `next` (a folder where a file was) counts:
    /// the previous one is gone. Names are looked up as the volume does (an image's
    /// APFS ignores case), so a name whose capitals changed isn't one.
    static func missing(from next: URL, in current: URL, control: RunControl?) throws -> [String] {
        var out: [String] = []
        var seen = 0
        control?.begin("Looking for deleted items", stage: .finishing)
        func walk(_ rel: String) throws {
            let dir = rel.isEmpty ? current.path : current.path + "/" + rel
            for name in PlainCopy.list(dir).sorted() {
                seen += 1
                if seen % 512 == 0, control?.isCancelled == true { throw CancelledError() }
                control?.advance()
                let itemRel = rel.isEmpty ? name : rel + "/" + name
                var a = stat(), b = stat()
                guard lstat(dir + "/" + name, &a) == 0 else { continue }
                guard lstat(next.path + "/" + itemRel, &b) == 0, a.st_mode & S_IFMT == b.st_mode & S_IFMT else {
                    out.append(itemRel); continue
                }
                if a.st_mode & S_IFMT == S_IFDIR { try walk(itemRel) }
            }
        }
        if FileManager.default.fileExists(atPath: current.path) { try walk("") }
        return out
    }

    /// A clone of each of `rels` in `copy`, in `folder`'s Removed items under the day
    /// of `now`, each under a name of its own (see place). One a run that stopped after
    /// this already kept (see alreadyKept) isn't kept twice. Says how far it has got,
    /// and Stop ends it. Returns how many are kept.
    @discardableResult
    static func keep(_ rels: [String], from copy: URL, in folder: URL, now: Date, calendar: Calendar = .current,
                     runner: CommandRunner) throws -> Int {
        guard !rels.isEmpty else { return 0 }
        let control = runner.control
        control?.begin("Moving deleted items to Removed items", stage: .finishing, total: UInt64(rels.count))
        let day = PlainCopyLayout.removedDay(folder, now, calendar: calendar)
        var kept = 0
        for rel in rels {
            if control?.isCancelled == true { throw CancelledError() }
            control?.advance()
            let from = copy.appendingPathComponent(rel)
            if alreadyKept(from, as: rel, in: day) { kept += 1; continue }
            let to = try place(rel, in: day)
            try PlainCopy.withOwnerWrite([to.deletingLastPathComponent().path]) {
                try MirrorCopy.clone(from, to: to, runner: runner)
            }
            kept += 1
        }
        return kept
    }

    /// the days held in `removed` (a library folder's Removed items), oldest first
    public static func days(in removed: URL, calendar: Calendar = .current) -> [(day: Date, folder: URL)] {
        PlainCopy.list(removed.path).compactMap { name -> (Date, URL)? in
            let parts = name.split(separator: "-").compactMap { Int($0) }
            guard name.count == 10, parts.count == 3,
                  let day = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
            return (day, removed.appendingPathComponent(name, isDirectory: true))
        }.sorted { $0.0 < $1.0 }
    }

    /// Delete the days in `removed` from before `cutoff` (all of them with nil). What
    /// couldn't be deleted is named; Removed items itself goes once it is empty.
    @discardableResult
    public static func delete(in removed: URL, before cutoff: Date?, calendar: Calendar = .current) -> (deleted: Int, failed: [String]) {
        var deleted = 0, failed: [String] = []
        for (day, folder) in days(in: removed, calendar: calendar) where cutoff.map({ day < $0 }) ?? true {
            do {
                try FileManager.default.removeItem(at: folder)
                deleted += 1
            } catch {
                // a locked item or a read-only folder (a Mac's drive keeps them)
                _ = try? ProcessCommandRunner().run("/usr/bin/chflags", ["-R", "nouchg", folder.path], stdin: nil)
                _ = try? ProcessCommandRunner().run("/bin/chmod", ["-R", "u+w", folder.path], stdin: nil)
                if (try? FileManager.default.removeItem(at: folder)) != nil { deleted += 1 } else { failed.append(folder.lastPathComponent) }
            }
        }
        if PlainCopy.list(removed.path).allSatisfy({ $0.hasPrefix("._") || $0 == ".DS_Store" }) { try? FileManager.default.removeItem(at: removed) }
        return (deleted, failed)
    }
}

/// The plain-files format as an ArchiveEngine, for what asks any engine for a copy.
/// A run goes through PlainCopy itself (see JobExecutor), for what it says.
public struct PlainCopyEngine: ArchiveEngine {
    let target: Target
    let runner: CommandRunner

    public init(target: Target, runner: CommandRunner = ProcessCommandRunner()) {
        self.target = target; self.runner = runner
    }

    public func archive(_ source: ArchiveSource, to destinationDir: URL) throws -> ArchiveResult {
        let profile = FileSystemProfile.of(destinationDir, target: target)
        let out = try PlainCopy(profile: profile, runner: runner).run(source.root, in: destinationDir, excluded: source.excluded)
        return ArchiveResult(artifacts: [out.copy], format: .plainFiles)
    }
}
