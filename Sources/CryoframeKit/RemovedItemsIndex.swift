//
//  RemovedItemsIndex.swift
//  CryoframeKit
//
//  What a plain-files copy's Removed items holds, recorded as items are moved there
//  (see PlainCopy), so Find a File reads one small file instead of walking every
//  day's folders, which is slow on a memory card. It also knows which folders were
//  deleted from the library: a walk can't tell those from the folders made only to
//  keep a deleted file's path ("Removed items/<day>/2024" for "2024/W-2.pdf"), and
//  showed both as matches.
//
//  The index is a hint, never the record: a day it doesn't hold, or one a run was
//  moving items into when it was cut off, is walked as before.
//

import Foundation

struct RemovedItemsIndex: Codable, Equatable {
    static let fileName = ".cryoframe-removed-index.json"

    /// one item kept in Removed items
    struct Item: Codable, Equatable {
        /// where it was in the library
        var path: String
        var size: UInt64
        /// seconds since 1970
        var modified: Int64
        /// ContentsEntry.Kind's raw value
        var kind: String
        /// where it is kept, from its day's folder
        var kept: String
    }

    var version = 1
    /// the day a run was moving items into when the index was last written: until
    /// that run (or a later one) finishes, its list may be short
    var pending: String?
    /// day folder name ("2026-10-02") → what it holds
    var days: [String: [Item]] = [:]

    /// in the library's folder beside Removed items, not in it: Removed items is the
    /// person's to look through, on any computer
    static func url(in removed: URL) -> URL { removed.deletingLastPathComponent().appendingPathComponent(fileName) }

    /// the index of `removed` (a library folder's Removed items); nil when there is none
    /// or it can't be read
    static func read(_ removed: URL) -> RemovedItemsIndex? {
        guard let data = try? Data(contentsOf: url(in: removed)),
              let index = try? JSONDecoder().decode(RemovedItemsIndex.self, from: data), index.version == 1 else { return nil }
        return index
    }

    /// written beside and renamed over the last, so a reader never meets half of one
    func write(_ removed: URL) throws {
        let target = Self.url(in: removed)
        let temp = target.deletingLastPathComponent().appendingPathComponent(Self.fileName + ".tmp")
        try JSONEncoder().encode(self).write(to: temp)
        guard rename(temp.path, target.path) == 0 else {
            let why = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            unlink(temp.path)
            throw why
        }
    }

    /// what `day` holds, as trusted: nil for a day it doesn't hold, or the day a run
    /// was cut off while moving items into
    func items(of day: String) -> [Item]? {
        day == pending ? nil : days[day]
    }

    /// Every item in a day's folder, found by walking it, for a day the index doesn't
    /// hold: each item where it is kept, its own path in the library unknown.
    static func walk(_ dayFolder: URL, control: RunControl? = nil) -> [Item]? {
        guard let walker = FileManager.default.enumerator(atPath: dayFolder.path) else { return [] }
        var out: [Item] = []
        while let rel = walker.nextObject() as? String {
            if out.count % 512 == 511, control?.isCancelled == true { return nil }
            if let item = item(at: dayFolder.appendingPathComponent(rel), path: rel, kept: rel) { out.append(item) }
        }
        return out
    }

    /// the item at `url`, nil when it is gone or isn't a file, folder or link
    static func item(at url: URL, path: String, kept: String) -> Item? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        let kind: ContentsEntry.Kind
        switch st.st_mode & S_IFMT {
        case S_IFDIR: kind = .folder
        case S_IFLNK: kind = .link
        case S_IFREG: kind = .file
        default: return nil
        }
        return Item(path: path, size: kind == .file ? UInt64(max(st.st_size, 0)) : 0, modified: Int64(st.st_mtimespec.tv_sec),
                    kind: kind.rawValue, kept: kept)
    }

    func entry(_ item: Item, day: Date, dayName: String) -> ContentsEntry? {
        guard let kind = ContentsEntry.Kind(rawValue: item.kind) else { return nil }
        return ContentsEntry(path: item.path, size: item.size, modified: item.modified, kind: kind, removedOn: day,
                             keptAt: PlainCopyLayout.removedFolder + "/" + dayName + "/" + item.kept)
    }
}

/// Records what one run moves into Removed items under one day (see RemovedItemsIndex).
/// `begin` before the first item moves, `kept` after each, `finish` after the last.
final class RemovedItemsRecorder {
    let removed: URL
    let day: URL
    private var index = RemovedItemsIndex()
    private var added: [RemovedItemsIndex.Item] = []
    private var started = false

    init(day: URL) {
        self.day = day
        self.removed = day.deletingLastPathComponent()
    }

    /// Mark the day as being written, so a run cut off from here is walked again. A day
    /// on the drive the index doesn't hold (or a day an earlier run was cut off in) is
    /// walked now, once. Without an index that can be written, there is none: a search
    /// then walks every day, as it did before there was one.
    func begin(control: RunControl? = nil) {
        guard !started else { return }
        started = true
        var index = RemovedItemsIndex.read(removed) ?? RemovedItemsIndex()
        let onDrive = RemovedItems.days(in: removed).map { $0.folder.lastPathComponent }
        for name in onDrive where index.items(of: name) == nil {
            guard let walked = RemovedItemsIndex.walk(removed.appendingPathComponent(name, isDirectory: true), control: control) else {
                index.days[name] = nil; continue
            }
            index.days[name] = walked
        }
        let present = Set(onDrive)
        index.days = index.days.filter { present.contains($0.key) || $0.key == day.lastPathComponent }
        index.pending = day.lastPathComponent
        self.index = index
        do {
            try index.write(removed)
        } catch {
            unlink(RemovedItemsIndex.url(in: removed).path)
        }
    }

    /// `rel` (a path in the library) is now kept at `at`; a folder with all it holds
    func kept(_ rel: String, at: URL) {
        let keptRel = String(at.path.dropFirst(day.path.count + 1))
        guard let item = RemovedItemsIndex.item(at: at, path: rel, kept: keptRel) else { return }
        added.append(item)
        guard item.kind == ContentsEntry.Kind.folder.rawValue, let walker = FileManager.default.enumerator(atPath: at.path) else { return }
        while let sub = walker.nextObject() as? String {
            if let inner = RemovedItemsIndex.item(at: at.appendingPathComponent(sub), path: rel + "/" + sub, kept: keptRel + "/" + sub) {
                added.append(inner)
            }
        }
    }

    /// the day's list, with what this run kept, no longer pending
    func finish() {
        guard started else { return }
        let name = day.lastPathComponent
        index.days[name, default: []] += added
        index.pending = nil
        added = []
        do {
            try index.write(removed)
        } catch {
            unlink(RemovedItemsIndex.url(in: removed).path)
        }
        started = false
    }
}
