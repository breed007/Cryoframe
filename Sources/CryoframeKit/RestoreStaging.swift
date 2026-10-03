//
//  RestoreStaging.swift
//  CryoframeKit
//
//  Where a restore is copied before it takes its name. A restore of a large library
//  takes minutes, and can be cut off part way: by a crash, by Force Quit, or by a
//  logout or restart, which gives Cryoframe 15 seconds (see QuitGuard). Copied
//  straight to its name, it left half a library under the library's own name, which
//  looks whole and isn't. Now each restore copies into a hidden folder beside where it
//  goes, and renames the copy into place only once it is whole:
//
//    <folder>/.cryoframe-restore-<uuid>/             the staging folder
//    <folder>/.cryoframe-restore-<uuid>/.lock        held (flock) while the restore runs
//    <folder>/.cryoframe-restore-<uuid>/.ready       a restore in place: the copy is
//                                                    verified, and where it goes
//    <folder>/.cryoframe-restore-<uuid>/<library>    the copy
//
//  A staging folder nobody holds, and that isn't ready, is a restore that was cut
//  off: half a copy of something still in its backup, removed by the next restore
//  into that folder. One that is ready is a restore in place cut off between moving
//  the live library to the Trash and moving the verified copy in, which leaves the
//  library's place empty. Nothing removes that one: at launch the app finishes the
//  move, or, when something has taken the place meanwhile, puts the copy beside it
//  under a name that shows, and says where both are (see recover).
//

import Foundation

public final class RestoreStaging {
    public static let prefix = ".cryoframe-restore-"
    static let lockName = ".lock"
    static let readyName = ".ready"

    /// what a restore in place records once its copy is verified (see markReady)
    struct Ready: Codable, Equatable {
        /// the live library's path, which the copy replaces
        var live: String
        /// the copy's name in the staging folder
        var item: String
        /// where the live library went in the Trash, once it has
        var trashed: String?
        /// the live library has gone to the Trash (the Trash may not say where)
        var inTrash: Bool?
    }

    public let dir: URL
    private var lockFD: Int32

    private init(dir: URL, lockFD: Int32) { self.dir = dir; self.lockFD = lockFD }

    deinit { if lockFD >= 0 { close(lockFD) } }

    /// A new staging folder in `parent`, held until `end`. Staging folders in `parent`
    /// that restores cut off left unfinished are removed first.
    public static func begin(in parent: URL) throws -> RestoreStaging {
        let fm = FileManager.default
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        sweep(parent)
        let dir = parent.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: false)
        let fd = open(dir.appendingPathComponent(lockName).path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else {
            let why = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try? fm.removeItem(at: dir)
            throw why
        }
        // a drive that takes no locks (a share may not) still takes the restore: its
        // staging folder then always looks held, and nothing sweeps it
        _ = flock(fd, LOCK_EX | LOCK_NB)
        return RestoreStaging(dir: dir, lockFD: fd)
    }

    /// Done with it. Removed with whatever it holds (an unfinished or unneeded copy),
    /// unless it holds a verified copy that never reached its place: that one is left
    /// for `recover`.
    public func end() {
        defer { release() }
        if let ready = Self.ready(in: dir) {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(ready.item).path) { return }
        } else if Self.isRecorded(dir) {
            return
        }
        Self.remove(dir)
    }

    /// let go of it as a crash would, leaving it as it is (for tests)
    func release() {
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 }
    }

    /// The copy at `item`, verified, is to replace the library at `live`. Written to
    /// the drive before the library is touched.
    func markReady(item: URL, live: URL, trashed: URL? = nil, inTrash: Bool = false) throws {
        let ready = Ready(live: live.path, item: item.lastPathComponent, trashed: trashed?.path, inTrash: inTrash ? true : nil)
        let url = dir.appendingPathComponent(Self.readyName)
        try JSONEncoder().encode(ready).write(to: url, options: .atomic)
        let fd = open(url.path, O_RDONLY)
        if fd >= 0 { _ = fcntl(fd, F_FULLFSYNC); close(fd) }
    }

    /// not ready after all: the library was never touched
    func unmarkReady() {
        unlink(dir.appendingPathComponent(Self.readyName).path)
    }

    /// whether `dir` has a record at all, read or not: a verified copy is in it
    static func isRecorded(_ dir: URL) -> Bool {
        var st = stat()
        return lstat(dir.appendingPathComponent(readyName).path, &st) == 0
    }

    static func ready(in dir: URL) -> Ready? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(readyName)) else { return nil }
        return try? JSONDecoder().decode(Ready.self, from: data)
    }

    /// whether a restore still holds the staging folder `dir`
    static func isHeld(_ dir: URL) -> Bool {
        let fd = open(dir.appendingPathComponent(lockName).path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }
        return true
    }

    /// the staging folders in `parent`
    static func folders(in parent: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? [])
            .filter { $0.hasPrefix(prefix) }.sorted()
            .map { parent.appendingPathComponent($0, isDirectory: true) }
    }

    /// remove the staging folders in `parent` restores cut off left unfinished: this
    /// Cryoframe's (they have a lock), not held, and with no record (one that can't be
    /// read still says the copy was verified). 1.6 made staging folders of its own
    /// without a lock; those are left for `recover`.
    static func sweep(_ parent: URL) {
        for dir in folders(in: parent) {
            var st = stat()
            guard lstat(dir.appendingPathComponent(lockName).path, &st) == 0, !isHeld(dir), !isRecorded(dir) else { continue }
            remove(dir)
        }
    }

    static func remove(_ dir: URL) {
        if (try? FileManager.default.removeItem(at: dir)) != nil { return }
        // a library's read-only folders or locked files (a restore keeps them so)
        _ = try? ProcessCommandRunner().run("/usr/bin/chflags", ["-R", "nouchg", dir.path], stdin: nil)
        _ = try? ProcessCommandRunner().run("/bin/chmod", ["-R", "u+w", dir.path], stdin: nil)
        try? FileManager.default.removeItem(at: dir)
    }

    /// Rename `staged` to `target`, never over anything there (RENAME_EXCL)
    static func moveIn(_ staged: URL, to target: URL) throws {
        guard renamex_np(staged.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw RestoreError.destinationExists(target.path) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    // MARK: - what a cut-off restore left

    /// What a restore cut off before it finished left beside a live library, and what
    /// was done with it (see recover). Nothing is ever deleted.
    public struct Leftover: Sendable, Equatable {
        public enum What: Sendable, Equatable {
            /// a restore in place had verified its copy and moved the library to the
            /// Trash; the copy is now in the library's place
            case finished
            /// a verified copy whose place something else has taken meanwhile: put
            /// beside it under a name that shows
            case verifiedBeside
            /// a copy made by an earlier Cryoframe, which didn't record whether it was
            /// whole: put beside the library under a name that shows, to be checked
            case unverifiedBeside
            /// a verified copy whose record can't be read (damaged, or written by a
            /// later Cryoframe), so where it goes and whether the library went to the
            /// Trash are unknown: put beside under a name that shows
            case unrecordedBeside
        }
        public var what: What
        /// the library's place
        public var live: URL
        /// where the restored copy is now
        public var copy: URL
        /// where the library it replaced went in the Trash, when that is known
        public var trashed: URL?
        /// the restore was cut off before the library went to the Trash: the library
        /// at `live` is the person's own, as it was (.verifiedBeside)
        public var libraryStayed = false
    }

    /// Deal with what restores cut off left beside the libraries at `lives` (the
    /// libraries Cryoframe can restore in place). A verified copy goes into its
    /// library's place when that is empty; anything else that holds a copy is moved
    /// beside the library under a name that shows ("Photos Library (2).photoslibrary"),
    /// as a hidden folder is one nobody finds. Unfinished copies made by this
    /// Cryoframe (never verified, the library never touched) are removed. Staging
    /// folders a restore still holds are left alone.
    public static func recover(lives: [URL]) -> [Leftover] {
        let fm = FileManager.default
        var out: [Leftover] = []
        let parents = Dictionary(grouping: lives, by: { $0.deletingLastPathComponent().path })
        for (parentPath, livesHere) in parents.sorted(by: { $0.key < $1.key }) {
            let parent = URL(fileURLWithPath: parentPath, isDirectory: true)
            for dir in folders(in: parent) where !isHeld(dir) {
                if let ready = ready(in: dir) {
                    let live = URL(fileURLWithPath: ready.live)
                    let item = dir.appendingPathComponent(ready.item)
                    let trashed = ready.trashed.map { URL(fileURLWithPath: $0) }
                    guard fm.fileExists(atPath: item.path) else { remove(dir); continue }     // moved in, not tidied
                    var st = stat()
                    if lstat(live.path, &st) != 0, (try? moveIn(item, to: live)) != nil {
                        out.append(Leftover(what: .finished, live: live, copy: live, trashed: trashed))
                        remove(dir)
                    } else if let beside = putBeside(item, live: live) {
                        out.append(Leftover(what: .verifiedBeside, live: live, copy: beside, trashed: trashed,
                                            libraryStayed: trashed == nil && ready.inTrash != true))
                        remove(dir)
                    }
                    continue
                }
                let recorded = isRecorded(dir)
                var st = stat()
                if !recorded, lstat(dir.appendingPathComponent(lockName).path, &st) == 0 { remove(dir); continue }   // unfinished
                // a verified copy whose record can't be read, or 1.6's (no lock, no
                // record): the copy, under the name of the library it was restored
                // from, which names it beside too when no library here has that name
                let items = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }
                for name in items {
                    let live = livesHere.first { $0.lastPathComponent == name } ?? parent.appendingPathComponent(name)
                    if let beside = putBeside(dir.appendingPathComponent(name), live: live) {
                        out.append(Leftover(what: recorded ? .unrecordedBeside : .unverifiedBeside, live: live, copy: beside, trashed: nil))
                    }
                }
                if ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).allSatisfy({ $0.hasPrefix(".") }) { remove(dir) }
            }
        }
        return out
    }

    /// `item` moved beside `live` under the first free "Name (2)", "Name (3)", …
    private static func putBeside(_ item: URL, live: URL) -> URL? {
        for _ in 0..<8 {
            let beside = RestoreNames.alongside(live.lastPathComponent, in: live.deletingLastPathComponent())
            do {
                try moveIn(item, to: beside)
                return beside
            } catch RestoreError.destinationExists {
                continue
            } catch {
                return nil
            }
        }
        return nil
    }
}

/// A restore over the live library: the version is restored and verified beside it
/// first, the library goes to the Trash, and the copy takes its place. The library is
/// never touched until a whole, verified copy is in hand; a restore cut off after
/// the library went to the Trash is finished at the next launch (see
/// RestoreStaging.recover).
public enum RestoreInPlace {
    public enum Outcome: Sendable, Equatable {
        /// the copy is in the library's place; the library it replaced is in the
        /// Trash (at `trashed`, when the Trash said where)
        case replaced(trashed: URL?)
        /// restored and verified, but it couldn't be moved into place: it is at `copy`
        case notMoved(copy: URL)
    }

    /// Replace the library at `live` with `archive`'s. Throws, with the library left
    /// as it was, when the restore or the move to the Trash fails. `trash` moves an
    /// item to the Trash and says where it went; `afterTrash` is for tests.
    public static func run(_ archive: RestorableArchive, live: URL, passphrase: String?,
                           engine: RestoreEngine = RestoreEngine(),
                           trash: (URL) throws -> URL? = RestoreInPlace.trash,
                           afterTrash: (() throws -> Void)? = nil,
                           onStage: @escaping @Sendable (RestoreStage) -> Void = { _ in }) throws -> Outcome {
        let fm = FileManager.default
        let parent = live.deletingLastPathComponent()
        // 1. restored and verified beside the library, under a hidden name
        let (staging, restored) = try engine.stage(archive, in: parent, verify: true, passphrase: passphrase, clash: nil,
                                                   inPlace: true, onStage: onStage)
        defer { staging.end() }
        // 2. recorded before the library is touched: from here a restore cut off is
        //    finished at the next launch
        try staging.markReady(item: restored, live: live)
        var trashed: URL?
        var st = stat()
        if lstat(live.path, &st) == 0 {
            do {
                trashed = try trash(live)
            } catch {
                staging.unmarkReady()
                throw error
            }
            try? staging.markReady(item: restored, live: live, trashed: trashed, inTrash: true)
        }
        try afterTrash?()
        // 3. the verified copy into the library's own place (which also puts right a
        //    name the archive has that the library doesn't)
        do {
            try RestoreStaging.moveIn(restored, to: live)
        } catch {
            // out of the hidden folder, where it can be found; failing that it stays
            // there, and the next launch deals with it
            var rescued = parent.appendingPathComponent("\(live.lastPathComponent) (recovered)")
            if fm.fileExists(atPath: rescued.path) {
                rescued = parent.appendingPathComponent("\(live.lastPathComponent) (recovered \(UUID().uuidString.prefix(8)))")
            }
            if (try? RestoreStaging.moveIn(restored, to: rescued)) != nil { return .notMoved(copy: rescued) }
            return .notMoved(copy: restored)
        }
        onStage(.completed)
        return .replaced(trashed: trashed)
    }

    /// the item moved to the Trash, and where it went there
    public static func trash(_ url: URL) throws -> URL? {
        var out: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &out)
        return out as URL?
    }
}
