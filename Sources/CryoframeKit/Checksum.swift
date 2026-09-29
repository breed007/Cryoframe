//
//  Checksum.swift
//  CryoframeKit
//
//  Streaming SHA-256 of an artifact (CryptoKit, no shell). Used to seal a
//  manifest after writing and to re-verify cold archives later.
//

import Foundation
import CryptoKit

public enum Checksum {
    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// digest an artifact: a content hash for a file, or a structural hash (the
    /// sorted list of inner file paths + sizes) for a directory like a sparsebundle.
    /// Full content-hashing a mirror's bands every run would defeat its incremental
    /// nature, so the structural digest catches dropped/added/resized bands cheaply.
    ///
    /// Paths are taken relative to the directory as the enumerator hands them out,
    /// whatever spelling `url` has. They used to be cut from full paths, and when the
    /// enumerator's spelling differed from the caller's (/var vs /private/var, a
    /// destination reached through a symlink) every line fell back to a bare file
    /// name: the same bundle hashed two ways, and a mirror written through a symlink
    /// failed its checksum everywhere a scan found it.
    public static func digest(of url: URL) throws -> String {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        guard isDir.boolValue else { return try sha256(of: url) }
        return hash(lines(in: url) { "/" + $0 })
    }

    /// what `digest` gave a directory reached through a spelling the enumerator
    /// didn't share: bare file names. Manifests written that way still verify.
    static func nameOnlyDigest(of url: URL) -> String {
        hash(lines(in: url) { ($0 as NSString).lastPathComponent })
    }

    /// "<path>\t<size>" for every regular file under `url`, sorted.
    private static func lines(in url: URL, path: (String) -> String) -> [String] {
        var lines: [String] = []
        guard let e = FileManager.default.enumerator(atPath: url.path) else { return lines }
        while let rel = e.nextObject() as? String {
            guard let attrs = e.fileAttributes, attrs[.type] as? FileAttributeType == .typeRegular else { continue }
            lines.append("\(path(rel))\t\((attrs[.size] as? NSNumber)?.uint64Value ?? 0)")
        }
        return lines.sorted()
    }

    private static func hash(_ lines: [String]) -> String {
        var hasher = SHA256()
        for line in lines { hasher.update(data: Data(line.utf8)); hasher.update(data: Data([0x0a])) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// byte size of an artifact — the file size, or the recursive content size for a directory.
    public static func byteSize(of url: URL) -> UInt64 {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if !isDir.boolValue { return ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64) ?? 0 }
        var total: UInt64 = 0
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) {
            for case let u as URL in e {
                guard let v = try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
                total += UInt64(v.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }
}
