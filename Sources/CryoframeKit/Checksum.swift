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
    public static func digest(of url: URL) throws -> String {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        guard isDir.boolValue else { return try sha256(of: url) }

        var hasher = SHA256()
        let base = url.path
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        var lines: [String] = []
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) {
            for case let u as URL in e {
                guard let v = try? u.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
                let rel = u.path.hasPrefix(base) ? String(u.path.dropFirst(base.count)) : u.lastPathComponent
                lines.append("\(rel)\t\(v.fileSize ?? 0)")
            }
        }
        for line in lines.sorted() { hasher.update(data: Data(line.utf8)); hasher.update(data: Data([0x0a])) }
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
