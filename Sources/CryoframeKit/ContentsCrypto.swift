//
//  ContentsCrypto.swift
//  CryoframeKit
//
//  The sealed form of an encrypted job's file list (see ContentsListing). Its own
//  format, never the escrow file's: a list is bound to the job, library and version
//  it describes, and is one more place a passphrase could be guessed offline, so it
//  costs a guess at least as much as the disk image beside it does.
//
//  File = header ‖ chunk 0 ‖ chunk 1 ‖ … ‖ final chunk.
//  Header: "CRYOLIST1", KDF id (1 = PBKDF2-HMAC-SHA256), iterations (UInt32),
//  KDF salt (32 bytes, SHA-256 of "cryoframe-contents" + job ID), file salt (32
//  random bytes, fresh for every file written), chunk size (UInt32), then the job
//  ID, library ID and version, each a UInt16 length and UTF-8. All big-endian.
//  Master key: PBKDF2(passphrase, KDF salt, 1,000,000). The salt is the job's, so a
//  search derives one key per job, not one per version. File key: HKDF-SHA256 of
//  the master key over the file salt. Each chunk: up to `chunkSize` bytes sealed
//  with AES-256-GCM, nonce = the chunk's index, and the whole header, the index
//  and a last-chunk flag as its authenticated data. A file cut short, reordered,
//  run on past its last chunk, or moved between versions fails to open.
//

import Foundation
import CryptoKit
import CommonCrypto

public enum ContentsCrypto {
    static let magic = Array("CRYOLIST1".utf8)
    /// the only key derivation a reader accepts: PBKDF2-HMAC-SHA256
    static let kdfID: UInt8 = 1
    /// and its only iteration count. hdiutil's AES-256 images use PBKDF2-HMAC-SHA1
    /// at a time-calibrated count (384,615 and 625,000 measured on 2026-09-30); this
    /// is more, on a costlier hash, so the list is never the cheaper place to guess.
    static let iterations: UInt32 = 1_000_000
    static let chunkSize = 1 << 20
    static let saltLength = 32
    static let tagLength = 16
    /// the longest job ID, library ID and version a header may hold
    static let fieldLimit = 4096

    /// what a list is of: read from its header, authenticated once a chunk opens
    public struct Binding: Sendable, Equatable {
        public var jobID: String
        public var libraryID: String
        public var version: String
        public init(jobID: String, libraryID: String, version: String) {
            self.jobID = jobID; self.libraryID = libraryID; self.version = version
        }
    }

    public enum Failure: Error, Equatable {
        /// not this format, or a KDF, iteration count or chunk size it never writes
        case unsupported
        /// cut short, run on, or otherwise not a whole file of this format
        case damaged
        /// no passphrase given opened it
        case wrongPassphrase
    }

    /// the KDF salt for a job's lists
    static func kdfSalt(jobID: String) -> [UInt8] {
        Array(SHA256.hash(data: Data(("cryoframe-contents" + jobID).utf8)))
    }

    /// The master key for `jobID`'s lists: one PBKDF2 derivation, about a third of a
    /// second. nil for an empty passphrase, or if the derivation fails.
    public static func masterKey(passphrase: String, jobID: String) -> SymmetricKey? {
        let pw = Array(passphrase.utf8)
        guard !pw.isEmpty else { return nil }
        let salt = kdfSalt(jobID: jobID)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passphrase, pw.count, salt, salt.count,
                                          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations, &derived, derived.count)
        defer { derived.withUnsafeMutableBytes { memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        return status == kCCSuccess ? SymmetricKey(data: derived) : nil
    }

    static func fileKey(master: SymmetricKey, fileSalt: [UInt8]) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: fileSalt,
                               info: Data("cryoframe-contents/1 file key".utf8), outputByteCount: 32)
    }

    static func header(_ b: Binding, fileSalt: [UInt8]) -> [UInt8]? {
        var h = magic
        h.append(kdfID)
        h += be32(iterations)
        h += kdfSalt(jobID: b.jobID)
        h += fileSalt
        h += be32(UInt32(chunkSize))
        for field in [b.jobID, b.libraryID, b.version] {
            let bytes = Array(field.utf8)
            guard bytes.count <= fieldLimit else { return nil }
            h += [UInt8(bytes.count >> 8), UInt8(bytes.count & 0xff)] + bytes
        }
        return h
    }

    struct Header {
        var bytes: [UInt8]
        var fileSalt: [UInt8]
        var binding: Binding
    }

    /// The header at the start of `data`, if it is one this reader accepts. Nothing
    /// in it is trusted until a chunk opens with it as authenticated data.
    static func parseHeader(_ data: Data) throws -> Header {
        var at = data.startIndex
        func take(_ n: Int) throws -> [UInt8] {
            guard n >= 0, data.endIndex - at >= n else { throw Failure.damaged }
            defer { at += n }
            return Array(data[at ..< at + n])
        }
        guard try take(magic.count) == magic else { throw Failure.unsupported }
        guard try take(1) == [kdfID], try take(4) == be32(iterations) else { throw Failure.unsupported }
        let kdfSalt = try take(saltLength)
        let fileSalt = try take(saltLength)
        guard try take(4) == be32(UInt32(chunkSize)) else { throw Failure.unsupported }
        var fields: [String] = []
        for _ in 0..<3 {
            let len = try take(2)
            let n = Int(len[0]) << 8 | Int(len[1])
            guard n <= fieldLimit, let s = String(bytes: try take(n), encoding: .utf8) else { throw Failure.damaged }
            fields.append(s)
        }
        // the KDF salt is the job's, never another: a reader derives it, it isn't told it
        guard kdfSalt == Self.kdfSalt(jobID: fields[0]) else { throw Failure.unsupported }
        return Header(bytes: Array(data[data.startIndex ..< at]), fileSalt: fileSalt,
                      binding: Binding(jobID: fields[0], libraryID: fields[1], version: fields[2]))
    }

    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }

    static func nonce(_ index: UInt64) -> AES.GCM.Nonce {
        var n = [UInt8](repeating: 0, count: 12)
        for i in 0..<8 { n[4 + i] = UInt8(index >> (56 - 8 * UInt64(i)) & 0xff) }
        return try! AES.GCM.Nonce(data: n)      // 12 bytes is always a valid nonce
    }

    static func aad(_ header: [UInt8], _ index: UInt64, final: Bool) -> [UInt8] {
        var a = header
        for i in 0..<8 { a.append(UInt8(index >> (56 - 8 * UInt64(i)) & 0xff)) }
        a.append(final ? 1 : 0)
        return a
    }

    /// Seal `plaintext` into `url`, chunk by chunk, under a fresh file salt. Only
    /// ciphertext is ever written: the file is made at a temporary name beside `url`
    /// and renamed over it once whole.
    public static func seal(_ plaintext: Data, binding: Binding, master: SymmetricKey, to url: URL) throws {
        var fileSalt = [UInt8](repeating: 0, count: saltLength)
        guard SecRandomCopyBytes(kSecRandomDefault, saltLength, &fileSalt) == errSecSuccess,
              let header = header(binding, fileSalt: fileSalt) else { throw Failure.unsupported }
        let key = fileKey(master: master, fileSalt: fileSalt)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        do {
            try writeChunks()
            guard rename(tmp.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        func writeChunks() throws {
            let out = try FileHandle(forWritingTo: tmp)
            defer { try? out.close() }
            try out.write(contentsOf: Data(header))
            var index: UInt64 = 0, offset = plaintext.startIndex
            repeat {
                let end = min(offset + chunkSize, plaintext.endIndex)
                let final = end == plaintext.endIndex
                let box = try AES.GCM.seal(plaintext[offset ..< end], using: key, nonce: nonce(index),
                                           authenticating: aad(header, index, final: final))
                try out.write(contentsOf: box.ciphertext)
                try out.write(contentsOf: box.tag)
                offset = end; index += 1
                if final { break }
            } while true
            try out.synchronize()
        }
    }

    /// Open a sealed list held in memory, handing each chunk's plaintext to `sink` as
    /// it opens; nothing is written anywhere. `master` gives the keys to try for the
    /// job the header names (a saved passphrase's, a typed one's), in order. Returns
    /// the authenticated binding, which the caller checks against where the file sits.
    /// `sink` returning false stops the reading (Stop).
    @discardableResult
    public static func open(_ data: Data, master: (String) -> [SymmetricKey],
                            sink: (Data) throws -> Bool) throws -> Binding {
        let header = try parseHeader(data)
        let body = data[(data.startIndex + header.bytes.count)...]
        let whole = chunkSize + tagLength
        // where each chunk starts: every chunk but the last is whole, and the last
        // holds at least its tag. A body that isn't laid out this way isn't one.
        guard body.count >= tagLength else { throw Failure.damaged }
        let count = (body.count - tagLength) / whole + 1
        guard body.count - (count - 1) * whole <= whole else { throw Failure.damaged }
        func chunk(_ i: Int) -> Data {
            let start = body.startIndex + i * whole
            return body[start ..< min(start + whole, body.endIndex)]
        }
        func openChunk(_ i: Int, _ key: SymmetricKey, final: Bool? = nil) throws -> Data {
            let c = chunk(i)
            let box = try AES.GCM.SealedBox(nonce: nonce(UInt64(i)), ciphertext: c.prefix(c.count - tagLength),
                                            tag: c.suffix(tagLength))
            return try AES.GCM.open(box, using: key, authenticating: aad(header.bytes, UInt64(i), final: final ?? (i == count - 1)))
        }
        // the first chunk tells a key that opens it from one that doesn't
        let keys = master(header.binding.jobID).map { fileKey(master: $0, fileSalt: header.fileSalt) }
        var found: (SymmetricKey, Data)?
        for k in keys {
            if let first = try? openChunk(0, k) { found = (k, first); break }
        }
        guard let (key, first) = found else {
            // one that opens it only as the other kind of chunk: the right key, on a
            // file cut down to its first chunk, or run on past it
            if keys.contains(where: { (try? openChunk(0, $0, final: count != 1)) != nil }) { throw Failure.damaged }
            throw Failure.wrongPassphrase
        }
        guard try sink(first) else { return header.binding }
        for i in 1..<count {
            // a later chunk that fails, with the key the first opened with, was changed
            guard let plain = try? openChunk(i, key) else { throw Failure.damaged }
            guard try sink(plain) else { break }
        }
        return header.binding
    }

    /// the binding in a sealed list's header, unauthenticated: which job's passphrase
    /// to ask for
    public static func claimedBinding(_ data: Data) -> Binding? { try? parseHeader(data).binding }
}

/// Master keys derived during one search, held in memory only and never written: a
/// job's key is derived once, however many of its versions are read.
public final class ContentsKeyring: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [Data: SymmetricKey] = [:]
    public init() {}

    public func master(jobID: String, passphrase: String) -> SymmetricKey? {
        let id = Data(SHA256.hash(data: Data(jobID.utf8) + [0] + Data(passphrase.utf8)))
        lock.lock()
        if let k = keys[id] { lock.unlock(); return k }
        lock.unlock()
        guard let k = ContentsCrypto.masterKey(passphrase: passphrase, jobID: jobID) else { return nil }
        lock.lock(); keys[id] = k; lock.unlock()
        return k
    }
}
