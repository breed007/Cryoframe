//
//  ZipFolderDates.swift
//  CryoframeKit
//
//  Puts back the folder dates a sealed zip holds once `ditto -x` has unpacked it.
//
//  ditto stores every folder's modification date in the zip (the Info-ZIP Unix
//  extra field, to the second), but unpacking dates a folder holding both a folder
//  and a file at the time of the unpack (measured on macOS 27, 2026-10-01). A
//  restore copies what the unpack left, so the folder came back dated the day of
//  the restore. So the dates are read from the zip's own directory and set again,
//  deepest folder first. A zip without them, or one this can't read, is left as
//  ditto unpacked it.
//

import Foundation

enum ZipFolderDates {
    /// the folders in `zip` and the modification date it holds for each, as paths
    /// relative to where it is unpacked; nil if its directory can't be read
    static func read(_ zip: URL) -> [(path: String, seconds: Int64)]? {
        guard let handle = try? FileHandle(forReadingFrom: zip) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), let (offset, length) = directory(handle, size: size),
              offset + length <= size else { return nil }
        var reader = Reader(handle: handle, at: offset, end: offset + length)
        var out: [(path: String, seconds: Int64)] = []
        // read to the directory's end, not for its entry count: ditto writes the count
        // modulo 65,536 (measured: 132,006 entries recorded as 934)
        while !reader.isDone {
            guard let fixed = reader.take(46), fixed.u32(0) == 0x0201_4b50 else { return nil }
            let nameLength = Int(fixed.u16(28)), extraLength = Int(fixed.u16(30)), commentLength = Int(fixed.u16(32))
            let mode = fixed.u32(38) >> 16
            guard let name = reader.take(nameLength), let extra = reader.take(extraLength),
                  reader.take(commentLength) != nil else { return nil }
            guard let path = String(data: name, encoding: .utf8) else { continue }
            let isFolder = path.hasSuffix("/") || (mode & UInt32(S_IFMT)) == UInt32(S_IFDIR)
            guard isFolder, !path.hasPrefix("__MACOSX/"), let seconds = unixModified(extra) else { continue }
            out.append((path: path, seconds: seconds))
        }
        return out
    }

    /// Set the dates `zip` holds on its folders unpacked under `root`, deepest first.
    /// Only real folders inside `root` are touched; a link is never followed.
    static func restore(from zip: URL, into root: URL) {
        guard let folders = read(zip) else { return }
        let depth = { (p: String) in p.split(separator: "/").count }
        for (path, seconds) in folders.sorted(by: { depth($0.path) > depth($1.path) }) {
            let parts = path.split(separator: "/")
            guard !path.hasPrefix("/"), !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." }) else { continue }
            let full = root.appendingPathComponent(parts.joined(separator: "/")).path
            guard ScratchLayout.isRealFolder(URL(fileURLWithPath: full)) else { continue }
            var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), timespec(tv_sec: Int(seconds), tv_nsec: 0)]
            _ = utimensat(AT_FDCWD, full, &times, AT_SYMLINK_NOFOLLOW)
        }
    }

    /// The modification date in an entry's extra fields: the extended timestamp
    /// (0x5455) or the older Info-ZIP Unix field (0x5855, which ditto writes).
    static func unixModified(_ extra: Data) -> Int64? {
        var i = extra.startIndex
        var found: Int64?
        while i + 4 <= extra.endIndex {
            let id = extra.u16(i - extra.startIndex), size = Int(extra.u16(i - extra.startIndex + 2))
            let body = i + 4
            guard body + size <= extra.endIndex else { break }
            let at = body - extra.startIndex
            if id == 0x5455, size >= 5, extra[body] & 1 != 0 { return Int64(Int32(bitPattern: extra.u32(at + 1))) }
            if id == 0x5855, size >= 8 { found = Int64(Int32(bitPattern: extra.u32(at + 4))) }
            i = body + size
        }
        return found
    }

    /// The central directory's offset and length, from its end record, or the Zip64
    /// one when there is one. Without it the directory is taken to end where the end
    /// record starts, which holds however large the zip: its 32-bit offset field
    /// wraps past 4 GB.
    private static func directory(_ handle: FileHandle, size: UInt64) -> (UInt64, UInt64)? {
        let tailLength = min(size, 65_535 + 22 + 20)
        guard (try? handle.seek(toOffset: size - tailLength)) != nil,
              let tail = try? handle.read(upToCount: Int(tailLength)), tail.count >= 22 else { return nil }
        var end = tail.count - 22
        while end >= 0, tail.u32(end) != 0x0605_4b50 { end -= 1 }
        guard end >= 0 else { return nil }
        if end >= 20, tail.u32(end - 20) == 0x0706_4b50 {
            let at = tail.u64(end - 20 + 8)
            guard (try? handle.seek(toOffset: at)) != nil, let record = try? handle.read(upToCount: 56), record.count == 56,
                  record.u32(0) == 0x0606_4b50 else { return nil }
            return (record.u64(48), record.u64(40))
        }
        let length = UInt64(tail.u32(end + 12)), endsAt = size - tailLength + UInt64(end)
        guard length <= endsAt else { return nil }
        return (endsAt - length, length)
    }

    /// reads the central directory a block at a time
    private struct Reader {
        let handle: FileHandle
        var position: UInt64
        let end: UInt64
        var buffer = Data()

        init(handle: FileHandle, at offset: UInt64, end: UInt64) {
            self.handle = handle; self.position = offset; self.end = end
            try? handle.seek(toOffset: offset)
        }

        var isDone: Bool { buffer.isEmpty && position >= end }

        mutating func take(_ n: Int) -> Data? {
            while buffer.count < n {
                let want = min(UInt64(1 << 20), end - position)
                guard want > 0, let more = try? handle.read(upToCount: Int(want)), !more.isEmpty else { return nil }
                position += UInt64(more.count)
                buffer.append(more)
            }
            let out = buffer.prefix(n)
            buffer = buffer.dropFirst(n)
            return Data(out)
        }
    }
}

private extension Data {
    func u16(_ at: Int) -> UInt16 {
        let i = startIndex + at
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }
    func u32(_ at: Int) -> UInt32 { UInt32(u16(at)) | UInt32(u16(at + 2)) << 16 }
    func u64(_ at: Int) -> UInt64 { UInt64(u32(at)) | UInt64(u32(at + 4)) << 32 }
}
