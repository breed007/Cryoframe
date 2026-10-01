//
//  ContentsListing.swift
//  CryoframeKit
//
//  A sealed version's file list, so "which version holds this file" can be answered
//  without opening every version. Made at backup time from the walk the run already
//  does of the frozen library, and written beside the archive before its manifest.
//
//  JSON lines, gzip-compressed: a first line saying which job, library and version
//  the list is of, one line per item, {"p":path,"s":size,"m":modified,"t":"f|d|l"},
//  path from the library's top, and a last line {"end":true,"n":count,"partial":bool}.
//  A plain job's list is `cryoframe-contents.jsonl.gz` (gunzip reads it); an
//  encrypted job's is `cryoframe-contents.cflist`, sealed (see ContentsCrypto).
//  Named pipes, sockets and devices aren't in an archive, so they aren't listed.
//
//  The manifest names the list in its own field (`contents`), never among the
//  artifacts: nothing that checks, counts or restores an archive sees it, and 1.5.6
//  ignores it. A list that is missing, changed, cut short or can't be opened is "no
//  list", never "not in this version": only a whole list that checks out says that.
//

import Foundation
import CryptoKit
import zlib

/// The manifest's record of a version's file list: its file, size and SHA-256,
/// how many items it lists, and whether it stopped short of the whole library.
public struct ContentsDigest: Codable, Sendable, Equatable {
    public var name: String
    public var size: UInt64
    public var sha256: String
    public var entries: Int
    public var partial: Bool

    public init(name: String, size: UInt64, sha256: String, entries: Int, partial: Bool) {
        self.name = name; self.size = size; self.sha256 = sha256; self.entries = entries; self.partial = partial
    }
}

/// a list written in scratch, to be copied beside each copy of its archive
public struct StagedContents: Sendable, Equatable {
    public var url: URL
    public var digest: ContentsDigest
}

/// one item in a list
public struct ContentsEntry: Sendable, Hashable {
    public enum Kind: String, Sendable {
        case file = "f", folder = "d", link = "l"
        var byte: UInt8 { switch self { case .file: 0x66; case .folder: 0x64; case .link: 0x6C } }
        init?(byte: UInt8) {
            switch byte { case 0x66: self = .file; case 0x64: self = .folder; case 0x6C: self = .link; default: return nil }
        }
    }
    /// from the library's top, "/"-separated
    public var path: String
    public var size: UInt64
    /// seconds since 1970
    public var modified: Int64
    public var kind: Kind

    public var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    public var modifiedDate: Date { Date(timeIntervalSince1970: TimeInterval(modified)) }
}

public enum ContentsListing {
    public static let plainName = "cryoframe-contents.jsonl.gz"
    public static let encryptedName = "cryoframe-contents.cflist"
    public static let names: Set<String> = [plainName, encryptedName]
    /// past either, the list stops and says it is partial
    public static let entryLimit = 2_000_000
    public static let byteLimit = 64 << 20
    /// a list file bigger than this isn't read: no list is written this big
    static let readLimit = byteLimit + (8 << 20)

    // MARK: collecting, on the run's walk

    /// Gathers the list as the run walks the library, compressed as it goes so a
    /// big library's list takes its compressed size in memory, not its full one.
    /// Never written anywhere until the list is finished (see write).
    public final class Collector: @unchecked Sendable {
        private let gzip = GzipWriter()
        private var pending: [UInt8] = []
        private let entryLimit: Int, byteLimit: Int
        public private(set) var count = 0
        /// stopped short of the whole library: a cap reached, part of the tree
        /// unreadable, or read live rather than from a snapshot
        public private(set) var partial = false
        private var full = false
        /// what the list is of: its first line
        public let binding: ContentsCrypto.Binding

        public init(binding: ContentsCrypto.Binding, entryLimit: Int = ContentsListing.entryLimit,
                    byteLimit: Int = ContentsListing.byteLimit) {
            self.binding = binding; self.entryLimit = entryLimit; self.byteLimit = byteLimit
            pending.reserveCapacity(1 << 18)
            pending += Array(#"{"cryoframe":"contents","v":1,"job":"#.utf8)
            JSONLine.appendString(binding.jobID, to: &pending)
            pending += Array(#","library":"#.utf8); JSONLine.appendString(binding.libraryID, to: &pending)
            pending += Array(#","version":"#.utf8); JSONLine.appendString(binding.version, to: &pending)
            pending += Array("}\n".utf8)
        }

        public func markPartial() { partial = true }

        public func add(_ path: String, size: UInt64, modified: Date?, kind: ContentsEntry.Kind) {
            guard !full, let gzip else { return }
            // room is left for what zlib holds back, and the last line
            if count >= entryLimit || gzip.produced + pending.count >= byteLimit - (2 << 20) {
                full = true; partial = true; return
            }
            pending.append(contentsOf: JSONLine.pathKey)
            JSONLine.appendString(path, to: &pending)
            pending.append(contentsOf: JSONLine.sizeKey)
            JSONLine.appendInteger(Int64(clamping: size), to: &pending)
            pending.append(contentsOf: JSONLine.modifiedKey)
            JSONLine.appendInteger(Int64(exactly: (modified?.timeIntervalSince1970 ?? 0).rounded(.down)) ?? 0, to: &pending)
            pending.append(contentsOf: JSONLine.kindKey)
            pending.append(kind.byte)
            pending.append(contentsOf: JSONLine.lineEnd)
            count += 1
            if pending.count >= 1 << 18 { flush() }
        }

        private func flush() {
            gzip?.write(pending)
            pending.removeAll(keepingCapacity: true)
        }

        /// the whole list, compressed, with its last line; nil if compression failed
        func finish() -> (gz: Data, entries: Int, partial: Bool)? {
            pending += Array(#"{"end":true,"n":\#(count),"partial":\#(partial)}"#.utf8) + [0x0A]
            flush()
            guard let data = gzip?.finish() else { return nil }
            return (data, count, partial)
        }
    }

    /// Write `collector`'s list for `binding` into `dir`: sealed when `master` is
    /// given (an encrypted job's), else plain. nil when it couldn't be written,
    /// which leaves the version without a list (never a failed backup).
    public static func write(_ collector: Collector, master: SymmetricKey?, encrypted: Bool, into dir: URL) -> StagedContents? {
        // an encrypted job's list is only ever written sealed
        guard encrypted == (master != nil) else { return nil }
        let binding = collector.binding
        guard let (gz, entries, partial) = collector.finish() else { return nil }
        let url = dir.appendingPathComponent(master == nil ? plainName : encryptedName)
        do {
            if let master {
                try ContentsCrypto.seal(gz, binding: binding, master: master, to: url)
            } else {
                try gz.write(to: url, options: .atomic)
            }
            let size = Checksum.byteSize(of: url)
            let sha = try Checksum.digest(of: url)
            return StagedContents(url: url, digest: ContentsDigest(name: url.lastPathComponent, size: size, sha256: sha,
                                                                   entries: entries, partial: partial))
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    /// Copy a staged list into `dir` beside its archive, before the manifest that
    /// names it. The staged file has to still be the one recorded (a later run may
    /// have made its own at the same scratch path), and the copy has to match it.
    /// Returns the digest to put in the manifest, or nil (and no list file in `dir`).
    public static func place(_ staged: StagedContents, into dir: URL) -> ContentsDigest? {
        let fm = FileManager.default
        let target = dir.appendingPathComponent(staged.digest.name)
        guard names.contains(staged.digest.name), matches(staged.url, staged.digest) else { removeAll(in: dir); return nil }
        let tmp = dir.appendingPathComponent(".\(staged.digest.name).\(UUID().uuidString).tmp")
        do {
            try fm.copyItem(at: staged.url, to: tmp)
            guard matches(tmp, staged.digest), rename(tmp.path, target.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            try? fm.removeItem(at: tmp)
            removeAll(in: dir)
            return nil
        }
        // only one list in a version folder
        for other in names where other != staged.digest.name { try? fm.removeItem(at: dir.appendingPathComponent(other)) }
        return staged.digest
    }

    /// no list in `dir`: the version's manifest won't name one
    public static func removeAll(in dir: URL) {
        for n in names { try? FileManager.default.removeItem(at: dir.appendingPathComponent(n)) }
    }

    static func matches(_ url: URL, _ d: ContentsDigest) -> Bool {
        Checksum.byteSize(of: url) == d.size && (try? Checksum.digest(of: url)) == d.sha256
    }

    // MARK: reading

    /// why a version has no list to search
    public enum Unavailable: Sendable, Equatable {
        /// a mirror: one up-to-date copy, looked into directly
        case mirror
        /// none recorded: made before lists were, or by an older Cryoframe, or the
        /// list couldn't be written or copied
        case notRecorded
        /// the manifest names one that isn't there
        case missing
        /// it isn't the file the manifest recorded
        case changed
        /// it is in a cloud folder and couldn't be brought down
        case notDownloaded(String)
        /// encrypted, and no passphrase to try
        case locked
        /// encrypted, and no passphrase tried opens it
        case wrongPassphrase
        /// it is another version's, library's or job's list
        case elsewhere
        /// not a whole list of a kind this Cryoframe reads
        case damaged

        /// said after "No file list for this version"
        public var reason: String {
            switch self {
            case .mirror: return "a mirror is one up-to-date copy; look inside it instead"
            case .notRecorded: return "it was made before Cryoframe kept file lists, or its list couldn't be saved"
            case .missing: return "its list is missing from the backup folder"
            case .changed: return "its list doesn't match what was recorded when it was made"
            case .notDownloaded(let why): return "its list couldn't be downloaded from the cloud folder (\(why))"
            case .locked: return "it is encrypted; enter its passphrase to search it"
            case .wrongPassphrase: return "its list couldn't be unlocked with the passphrase given"
            case .elsewhere: return "its list belongs to another backup"
            case .damaged: return "its list is damaged or incomplete"
            }
        }
    }

    /// how reading a list ended
    public enum ReadOutcome: Sendable, Equatable {
        /// every line read and checked; `partial`: the list itself says it stops short
        case read(entries: Int, partial: Bool)
        case unavailable(Unavailable)
        /// Stop, part-way
        case stopped
    }

    /// Read `archive`'s list, handing each item to `visit` as it is read. The file is
    /// checked against the manifest's digest before a line of it is parsed; an
    /// encrypted one is opened in memory with the keys `master` gives for the job its
    /// header names, and must say it is of this version, and of this library's job
    /// where the folder says whose it is. Items handed over before an outcome other
    /// than `.read` came from a list that doesn't count: the caller drops them.
    public static func read(_ archive: RestorableArchive, master: (String) -> [SymmetricKey],
                            control: RunControl? = nil, visit: (ContentsEntry) -> Void) -> ReadOutcome {
        guard archive.format != .liveMirror else { return .unavailable(.mirror) }
        guard let digest = archive.contents, names.contains(digest.name) else { return .unavailable(.notRecorded) }
        let url = archive.dir.appendingPathComponent(digest.name)
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return .unavailable(.missing) }
        guard (st.st_mode & S_IFMT) == S_IFREG, UInt64(st.st_size) == digest.size, digest.size <= UInt64(readLimit),
              let data = try? Data(contentsOf: url), UInt64(data.count) == digest.size,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == digest.sha256 else {
            return .unavailable(.changed)
        }
        // an encrypted archive's list is sealed, and a plain one's isn't: anything
        // else wasn't written by Cryoframe
        guard (digest.name == encryptedName) == archive.encrypted else { return .unavailable(.damaged) }
        let version = archive.dir.lastPathComponent
        var parser = LineReader(expectVersion: version, libraryKey: archive.libraryKey,
                                limit: min(digest.entries, entryLimit))
        let inflater = GzipReader()
        func feed(_ chunk: Data) throws -> Bool {
            if control?.isCancelled == true { return false }
            try inflater.write(chunk) { try parser.consume($0, visit: visit) }
            return true
        }
        do {
            if digest.name == encryptedName {
                var stopped = false
                let binding = try ContentsCrypto.open(data, master: master) { chunk in
                    let go = try feed(chunk); stopped = !go; return go
                }
                if stopped { return .stopped }
                guard binding == parser.binding else { return .unavailable(.elsewhere) }
            } else {
                var offset = data.startIndex
                while offset < data.endIndex {
                    let end = min(offset + (1 << 20), data.endIndex)
                    guard try feed(data[offset ..< end]) else { return .stopped }
                    offset = end
                }
            }
            try inflater.finish()
            try parser.finish()
        } catch ContentsCrypto.Failure.wrongPassphrase {
            return .unavailable(master(ContentsCrypto.claimedBinding(data)?.jobID ?? "").isEmpty ? .locked : .wrongPassphrase)
        } catch LineReader.Mismatch.elsewhere {
            return .unavailable(.elsewhere)
        } catch {
            return .unavailable(.damaged)
        }
        guard parser.count == digest.entries, parser.partial == digest.partial else { return .unavailable(.damaged) }
        return .read(entries: parser.count, partial: parser.partial)
    }

    /// Splits inflated bytes into lines and checks them: the first says what the list
    /// is of, every one after is an item until the last, and nothing follows that.
    struct LineReader {
        enum Mismatch: Error { case elsewhere }
        let expectVersion: String
        let libraryKey: String?
        /// the items the manifest says the list holds: no more are read
        let limit: Int
        var carry: [UInt8] = []
        var binding: ContentsCrypto.Binding?
        var count = 0
        var partial = false
        var ended = false

        init(expectVersion: String, libraryKey: String?, limit: Int) {
            self.expectVersion = expectVersion; self.libraryKey = libraryKey; self.limit = limit
        }

        mutating func consume(_ bytes: Data, visit: (ContentsEntry) -> Void) throws {
            try bytes.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                var start = 0
                while let nl = buf[start...].firstIndex(of: 0x0A) {
                    if carry.isEmpty {
                        try line(UnsafeRawBufferPointer(rebasing: buf[start ..< nl]), visit: visit)
                    } else {
                        // a line split between two pieces
                        carry.append(contentsOf: buf[start ..< nl])
                        let l = carry
                        carry = []
                        try l.withUnsafeBytes { try line($0, visit: visit) }
                    }
                    start = nl + 1
                }
                carry.append(contentsOf: buf[start...])
            }
            guard carry.count <= 1 << 20 else { throw GzipReader.Failure.corrupt }   // no line is this long
        }

        mutating func line(_ l: UnsafeRawBufferPointer, visit: (ContentsEntry) -> Void) throws {
            guard !ended else { throw GzipReader.Failure.corrupt }                  // nothing after the last line
            if binding != nil, let e = JSONLine.entry(l) {
                guard !e.path.isEmpty, e.size >= 0, count < limit else { throw GzipReader.Failure.corrupt }
                count += 1
                visit(ContentsEntry(path: e.path, size: UInt64(e.size), modified: e.modified, kind: e.kind))
                return
            }
            let fields = try JSONLine.parse(Array(l))
            if binding == nil {
                guard case .string("contents")? = fields["cryoframe"], case .number(1)? = fields["v"],
                      case .string(let job)? = fields["job"], case .string(let lib)? = fields["library"],
                      case .string(let ver)? = fields["version"] else { throw GzipReader.Failure.corrupt }
                binding = ContentsCrypto.Binding(jobID: job, libraryID: lib, version: ver)
                // of this version, and of this folder's library where the folder says
                guard ver == expectVersion, libraryKey.map({ $0 == LibraryIdentity.key(jobID: job, libraryID: lib) }) ?? true else {
                    throw Mismatch.elsewhere
                }
                return
            }
            if case .bool(true)? = fields["end"] {
                guard case .number(let n)? = fields["n"], case .bool(let p)? = fields["partial"], n == Int64(count) else {
                    throw GzipReader.Failure.corrupt
                }
                partial = p; ended = true
                return
            }
            guard case .string(let path)? = fields["p"], case .number(let size)? = fields["s"], size >= 0,
                  case .number(let m)? = fields["m"], case .string(let t)? = fields["t"], let kind = ContentsEntry.Kind(rawValue: t),
                  !path.isEmpty, count < limit else { throw GzipReader.Failure.corrupt }
            count += 1
            visit(ContentsEntry(path: path, size: UInt64(size), modified: m, kind: kind))
        }

        mutating func finish() throws {
            guard carry.isEmpty, ended, binding != nil else { throw GzipReader.Failure.corrupt }
        }
    }
}

// MARK: - JSON lines

/// The little JSON the list uses: one flat object per line, of strings, whole
/// numbers and true/false. Written and read here, fast, rather than through a
/// general coder 200,000 times; any JSON reader reads what this writes.
enum JSONLine {
    enum Value: Equatable { case string(String), number(Int64), bool(Bool), null }

    // an item's line, piece by piece: {"p":…,"s":…,"m":…,"t":"…"}
    static let pathKey = Array(#"{"p":"#.utf8)
    static let sizeKey = Array(#","s":"#.utf8)
    static let modifiedKey = Array(#","m":"#.utf8)
    static let kindKey = Array(#","t":""#.utf8)
    static let lineEnd = Array("\"}\n".utf8)
    static let hexDigits = Array("0123456789abcdef".utf8)

    static func appendString(_ s: String, to out: inout [UInt8]) {
        out.append(0x22)
        for b in s.utf8 {
            switch b {
            case 0x22: out.append(0x5C); out.append(0x22)
            case 0x5C: out.append(0x5C); out.append(0x5C)
            case 0x0A: out.append(0x5C); out.append(0x6E)
            case 0x0D: out.append(0x5C); out.append(0x72)
            case 0x09: out.append(0x5C); out.append(0x74)
            case 0..<0x20:
                out.append(contentsOf: [0x5C, 0x75, 0x30, 0x30, hexDigits[Int(b >> 4)], hexDigits[Int(b & 0xf)]])
            default: out.append(b)
            }
        }
        out.append(0x22)
    }

    static func appendInteger(_ n: Int64, to out: inout [UInt8]) {
        if n == 0 { out.append(0x30); return }
        if n < 0 { out.append(0x2D) }
        var digits: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                     UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        var v = n.magnitude, count = 0
        withUnsafeMutableBytes(of: &digits) { d in
            while v > 0 { d[count] = 0x30 + UInt8(v % 10); v /= 10; count += 1 }
            for i in stride(from: count - 1, through: 0, by: -1) { out.append(d[i]) }
        }
    }

    /// An item's line exactly as Collector writes it, read without a general parser;
    /// nil for any other line (an escape in the path, another key order), which the
    /// general parser then reads.
    static func entry(_ b: UnsafeRawBufferPointer) -> (path: String, size: Int64, modified: Int64, kind: ContentsEntry.Kind)? {
        var i = 0
        func take(_ word: [UInt8]) -> Bool {
            guard i + word.count <= b.count else { return false }
            for (k, c) in word.enumerated() where b[i + k] != c { return false }
            i += word.count; return true
        }
        func integer() -> Int64? {
            let negative = i < b.count && b[i] == 0x2D
            if negative { i += 1 }
            let start = i
            var v: Int64 = 0
            while i < b.count, b[i] >= 0x30, b[i] <= 0x39 {
                let (m, o1) = v.multipliedReportingOverflow(by: 10)
                let (s, o2) = m.addingReportingOverflow(Int64(b[i] - 0x30))
                guard !o1, !o2 else { return nil }
                v = s; i += 1
            }
            guard i > start, i - start == 1 || b[start] != 0x30 else { return nil }   // no leading zeros, as JSON
            return negative ? -v : v
        }
        guard take(pathKey), i < b.count, b[i] == 0x22 else { return nil }
        i += 1
        let pathStart = i
        while i < b.count, b[i] != 0x22 {
            guard b[i] >= 0x20, b[i] != 0x5C else { return nil }
            i += 1
        }
        guard i < b.count, let path = String(validating: UnsafeRawBufferPointer(rebasing: b[pathStart ..< i]), as: UTF8.self) else { return nil }
        i += 1
        guard take(sizeKey), let size = integer(), take(modifiedKey), let m = integer(), take(kindKey), i < b.count,
              let kind = ContentsEntry.Kind(byte: b[i]) else { return nil }
        i += 1
        guard i + 2 == b.count, b[i] == 0x22, b[i + 1] == 0x7D else { return nil }
        return (path, size, m, kind)
    }

    struct Malformed: Error {}

    static func parse(_ b: [UInt8]) throws -> [String: Value] {
        var i = 0
        func skip() { while i < b.count, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0D { i += 1 } }
        func expect(_ c: UInt8) throws { skip(); guard i < b.count, b[i] == c else { throw Malformed() }; i += 1 }
        func string() throws -> String {
            try expect(0x22)
            var out: [UInt8] = []
            while true {
                guard i < b.count else { throw Malformed() }
                let c = b[i]; i += 1
                if c == 0x22 { break }
                if c < 0x20 { throw Malformed() }
                guard c == 0x5C else { out.append(c); continue }
                guard i < b.count else { throw Malformed() }
                let e = b[i]; i += 1
                switch e {
                case 0x22, 0x5C, 0x2F: out.append(e)
                case 0x62: out.append(0x08)
                case 0x66: out.append(0x0C)
                case 0x6E: out.append(0x0A)
                case 0x72: out.append(0x0D)
                case 0x74: out.append(0x09)
                case 0x75:
                    func hex4() throws -> UInt32 {
                        guard i + 4 <= b.count, let v = UInt32(String(decoding: b[i ..< i + 4], as: UTF8.self), radix: 16) else { throw Malformed() }
                        i += 4; return v
                    }
                    var scalar = try hex4()
                    if (0xD800...0xDBFF).contains(scalar) {
                        guard i + 2 <= b.count, b[i] == 0x5C, b[i + 1] == 0x75 else { throw Malformed() }
                        i += 2
                        let low = try hex4()
                        guard (0xDC00...0xDFFF).contains(low) else { throw Malformed() }
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    }
                    guard let u = Unicode.Scalar(scalar) else { throw Malformed() }
                    out += Array(String(Character(u)).utf8)
                default: throw Malformed()
                }
            }
            guard let s = String(validating: out, as: UTF8.self) else { throw Malformed() }
            return s
        }
        func literal(_ word: String) -> Bool {
            let w = Array(word.utf8)
            guard i + w.count <= b.count, Array(b[i ..< i + w.count]) == w else { return false }
            i += w.count; return true
        }
        var out: [String: Value] = [:]
        try expect(0x7B)
        skip()
        if i < b.count, b[i] == 0x7D { i += 1 } else {
            while true {
                let key = try string()
                try expect(0x3A)
                skip()
                guard i < b.count else { throw Malformed() }
                let value: Value
                switch b[i] {
                case 0x22: value = .string(try string())
                case 0x74 where literal("true"): value = .bool(true)
                case 0x66 where literal("false"): value = .bool(false)
                case 0x6E where literal("null"): value = .null
                case 0x2D, 0x30...0x39:
                    let start = i
                    if b[i] == 0x2D { i += 1 }
                    while i < b.count, (0x30...0x39).contains(b[i]) { i += 1 }
                    guard let n = Int64(String(decoding: b[start ..< i], as: UTF8.self)) else { throw Malformed() }
                    value = .number(n)
                default: throw Malformed()
                }
                guard out.updateValue(value, forKey: key) == nil else { throw Malformed() }   // a key twice
                skip()
                guard i < b.count else { throw Malformed() }
                if b[i] == 0x2C { i += 1; continue }
                if b[i] == 0x7D { i += 1; break }
                throw Malformed()
            }
        }
        skip()
        guard i == b.count else { throw Malformed() }
        return out
    }
}

// MARK: - gzip, in memory

/// gzip compression into memory, fed a piece at a time
final class GzipWriter {
    private var stream = z_stream()
    private var out = Data()
    private var buffer = [UInt8](repeating: 0, count: 1 << 16)

    init?() {
        guard deflateInit2_(&stream, 6, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION,
                            Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
    }

    deinit { deflateEnd(&stream) }

    /// compressed bytes so far
    var produced: Int { out.count }

    func write(_ bytes: [UInt8]) { _ = run(bytes, flush: Z_NO_FLUSH) }

    func finish() -> Data? { run([], flush: Z_FINISH) ? out : nil }

    private func run(_ bytes: [UInt8], flush: Int32) -> Bool {
        var input = bytes
        return input.withUnsafeMutableBufferPointer { inBuf -> Bool in
            stream.next_in = inBuf.baseAddress
            stream.avail_in = uInt(inBuf.count)
            while true {
                var made = 0
                let status = buffer.withUnsafeMutableBufferPointer { o -> Int32 in
                    stream.next_out = o.baseAddress
                    stream.avail_out = uInt(o.count)
                    let s = deflate(&stream, flush)
                    made = o.count - Int(stream.avail_out)
                    out.append(o.baseAddress!, count: made)
                    return s
                }
                if status == Z_STREAM_END { return true }
                guard status == Z_OK || status == Z_BUF_ERROR else { return false }
                if flush != Z_FINISH, stream.avail_in == 0, stream.avail_out != 0 { return true }
                // no progress with a fresh buffer: done taking input, or stuck
                if status == Z_BUF_ERROR, made == 0 { return flush != Z_FINISH && stream.avail_in == 0 }
            }
        }
    }
}

/// gzip decompression from memory, handing out what it inflates a piece at a time;
/// one gzip member, and nothing after it
final class GzipReader {
    enum Failure: Error { case corrupt }
    private var stream = z_stream()
    private var ended = false
    private var ready: Bool
    private var buffer = [UInt8](repeating: 0, count: 1 << 18)

    init() {
        ready = inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
    }

    deinit { inflateEnd(&stream) }

    func write(_ chunk: Data, _ sink: (Data) throws -> Void) throws {
        guard ready else { throw Failure.corrupt }
        guard !chunk.isEmpty else { return }
        guard !ended else { throw Failure.corrupt }                   // bytes after the end
        var input = [UInt8](chunk)
        try input.withUnsafeMutableBufferPointer { inBuf in
            stream.next_in = inBuf.baseAddress
            stream.avail_in = uInt(inBuf.count)
            while stream.avail_in > 0 {
                var produced = Data()
                let status = buffer.withUnsafeMutableBufferPointer { o -> Int32 in
                    stream.next_out = o.baseAddress
                    stream.avail_out = uInt(o.count)
                    let s = inflate(&stream, Z_NO_FLUSH)
                    produced = Data(bytes: o.baseAddress!, count: o.count - Int(stream.avail_out))
                    return s
                }
                if !produced.isEmpty { try sink(produced) }
                if status == Z_STREAM_END {
                    ended = true
                    guard stream.avail_in == 0 else { throw Failure.corrupt }
                    return
                }
                guard status == Z_OK || (status == Z_BUF_ERROR && !produced.isEmpty) else { throw Failure.corrupt }
            }
        }
    }

    func finish() throws { guard ended else { throw Failure.corrupt } }
}
