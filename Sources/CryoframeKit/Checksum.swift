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
}
