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
//  The directory reader (ZipDirectory) also sizes a zip's unpack for ArchiveReader.
//

import Foundation

enum ZipFolderDates {
    /// the folders in `zip` and the modification date it holds for each, as paths
    /// relative to where it is unpacked; nil if its directory can't be read
    static func read(_ zip: URL) -> [(path: String, seconds: Int64)]? {
        var out: [(path: String, seconds: Int64)] = []
        let read = ZipDirectory.forEach(zip) { entry in
            guard let path = String(data: entry.name, encoding: .utf8) else { return }
            let isFolder = path.hasSuffix("/") || (entry.mode & UInt32(S_IFMT)) == UInt32(S_IFDIR)
            guard isFolder, !path.hasPrefix("__MACOSX/"), let seconds = unixModified(entry.extra) else { return }
            out.append((path: path, seconds: seconds))
        }
        return read == nil ? nil : out
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
}

/// A zip's central directory, read entry by entry, for what ditto writes as well as
/// what other tools do.
///
/// ditto writes no Zip64 records at all (measured on macOS 27, 2026-10-01): past
/// 4 GiB, every size and offset it records, and the end record's directory offset,
/// is the true value modulo 2^32. zipinfo and unzip then report "4294967296 extra
/// bytes" and fail. So the directory is found from where its end record sits (see
/// `directory`), and read to its end rather than for its entry count.
enum ZipDirectory {
    /// one entry, as the central directory records it
    struct Entry {
        var name: Data
        var extra: Data
        /// the Unix mode, from the upper half of the external attributes
        var mode: UInt32
        /// sizes as recorded, or from the entry's Zip64 extra field when it has one;
        /// a ditto entry past 4 GiB holds only the low 32 bits
        var compressed: UInt64
        var uncompressed: UInt64
    }

    /// Call `each` for every entry in `zip`'s central directory, in order. Returns
    /// where the directory starts in the file (where the last entry's data ends), or
    /// nil if it can't be read.
    @discardableResult
    static func forEach(_ zip: URL, _ each: (Entry) -> Void) -> UInt64? {
        guard let handle = try? FileHandle(forReadingFrom: zip) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), let (offset, length) = directory(handle, size: size),
              offset + length <= size else { return nil }
        var reader = Reader(handle: handle, at: offset, end: offset + length)
        // read to the directory's end, not for its entry count: ditto writes the count
        // modulo 65,536 (measured: 132,006 entries recorded as 934)
        while !reader.isDone {
            guard let fixed = reader.take(46), fixed.u32(0) == 0x0201_4b50 else { return nil }
            let nameLength = Int(fixed.u16(28)), extraLength = Int(fixed.u16(30)), commentLength = Int(fixed.u16(32))
            guard let name = reader.take(nameLength), let extra = reader.take(extraLength),
                  reader.take(commentLength) != nil else { return nil }
            var entry = Entry(name: name, extra: extra, mode: fixed.u32(38) >> 16,
                              compressed: UInt64(fixed.u32(20)), uncompressed: UInt64(fixed.u32(24)))
            zip64Sizes(extra, into: &entry)
            each(entry)
        }
        return offset
    }

    /// What `zip` takes on disk once unpacked: the bytes its entries hold, and a whole
    /// block for every entry (see ArchiveReader.unpackedSize); nil if its directory
    /// can't be read.
    static func unpackedSize(_ zip: URL, blockSize: UInt64) -> UInt64? {
        unpackEstimate(zip, blockSize: blockSize)?.bytes
    }

    /// What unpacking a zip takes, as far as its directory can say.
    struct UnpackEstimate: Equatable {
        /// the best count: exact when `certain`
        var bytes: UInt64
        /// what it takes at the least, whatever the 32-bit fields lost
        var atLeast: UInt64
        /// false when a file in the zip is over 4 GiB, so how far past 4 GiB it
        /// unpacks isn't recorded anywhere in the directory
        var certain: Bool
    }

    /// Where ditto's 32-bit fields wrapped, the bytes are worked out from where the
    /// entries sit. The directory starts where the last entry's data ends, a position
    /// known exactly, so the gap between it and what the recorded sizes and headers
    /// add up to is the 4 GiB multiples the compressed sizes lost (the local headers'
    /// own extra fields and data descriptors are far smaller). An entry that lost
    /// 4 GiB of compressed bytes holds at least that many more uncompressed, since
    /// deflate never grows data by more than a fraction of a percent.
    ///
    /// An entry whose recorded unpacked size is below its compressed size must have
    /// wrapped: nothing unpacks smaller than it compressed. It is counted at the
    /// least size above its compressed size its recorded value allows. Neither rule
    /// says how many more times past that it wrapped: a 9 GiB database compressed
    /// 2:1 to 4.5 GiB reads as 5 GiB. So a zip with either sign of a file over
    /// 4 GiB is uncertain, and the reader checks room for what it needs at the least
    /// and says it couldn't tell the rest. Left over: a file that compresses well
    /// and unpacks past 4 GiB with its recorded size above its compressed one shows
    /// no sign at all, and is counted low by a multiple of 4 GiB; an unpack that
    /// runs out of room fails and is cleaned up.
    static func unpackEstimate(_ zip: URL, blockSize: UInt64) -> UnpackEstimate? {
        let wrap: UInt64 = 1 << 32
        var recorded: UInt64 = 0, compressed: UInt64 = 0, entries: UInt64 = 0, laidOut: UInt64 = 0
        var provenWraps: UInt64 = 0
        guard let start = forEach(zip, { entry in
            recorded &+= entry.uncompressed
            compressed &+= entry.compressed
            entries += 1
            laidOut &+= 30 + UInt64(entry.name.count) + entry.compressed
            if entry.compressed < wrap, entry.uncompressed < wrap,
               entry.uncompressed < entry.compressed - min(entry.compressed, Self.expansion(entry.compressed)) {
                provenWraps += 1
            }
        }), start >= laidOut else { return nil }
        let lost = (start - laidOut) / wrap
        let blocks = entries * blockSize
        guard lost > 0 || provenWraps > 0 else {
            return UnpackEstimate(bytes: recorded &+ blocks, atLeast: recorded &+ blocks, certain: true)
        }
        // Which entries lost compressed multiples isn't recorded, so the proven wraps
        // are counted only where no compressed size wrapped (each is then exact).
        let bytes = recorded &+ (lost > 0 ? lost : provenWraps) &* wrap &+ blocks
        // the least, whichever entries wrapped: the recorded sizes (each at most its
        // true size), or everything the zip holds less the most deflate could add
        let allCompressed = compressed &+ lost &* wrap
        let floor = lost > 0 ? max(recorded, allCompressed - min(allCompressed, Self.expansion(allCompressed))) : recorded &+ provenWraps &* wrap
        return UnpackEstimate(bytes: bytes, atLeast: floor &+ blocks, certain: false)
    }

    /// more than any zip method grows `n` bytes by (deflate's stored blocks add 5
    /// bytes in 65,535; bzip2 and LZMA a little more)
    private static func expansion(_ n: UInt64) -> UInt64 { n / 128 + 1024 }

    /// The 64-bit sizes in an entry's Zip64 extra field (0x0001), which holds, in
    /// order, only the fields recorded as 0xFFFFFFFF.
    private static func zip64Sizes(_ extra: Data, into entry: inout Entry) {
        let full: UInt64 = 0xFFFF_FFFF
        guard entry.uncompressed == full || entry.compressed == full else { return }
        var i = 0
        while i + 4 <= extra.count {
            let id = extra.u16(i), size = Int(extra.u16(i + 2))
            guard i + 4 + size <= extra.count else { return }
            if id == 0x0001 {
                var at = i + 4
                if entry.uncompressed == full, at + 8 <= i + 4 + size { entry.uncompressed = extra.u64(at); at += 8 }
                if entry.compressed == full, at + 8 <= i + 4 + size { entry.compressed = extra.u64(at) }
                return
            }
            i += 4 + size
        }
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
