//
//  PassphraseEscrow.swift
//  Cryoframe (app)
//
//  Bulk export/import of archive passphrases, encrypted with a master password, so
//  a user can recover them on a new Mac. The per-job "Copy passphrase" handles one;
//  this is the offsite-everything escrow.
//

import Foundation
import CryoframeKit

enum PassphraseEscrow {
    struct Entry: Codable, Identifiable {
        var id = UUID()
        var jobName: String
        var library: String
        var passphrase: String
        enum CodingKeys: String, CodingKey { case jobName, library, passphrase }
    }

    /// every encrypted job that has a stored passphrase, read straight from the keychain.
    static func collect() -> [Entry] {
        JobStore.standard().load().jobs.filter(\.encrypted).compactMap { job in
            guard let pass = KeychainArchiveKey.load(jobID: job.id) else { return nil }
            return Entry(jobName: job.name,
                         library: job.libraries.map(\.displayName).joined(separator: ", "),
                         passphrase: pass)
        }
    }

    static func exportData(_ entries: [Entry], password: String) -> Data? {
        guard let json = try? JSONEncoder().encode(entries) else { return nil }
        return EscrowCrypto.encrypt(json, password: password)
    }

    static func importEntries(_ data: Data, password: String) -> [Entry]? {
        guard let json = EscrowCrypto.decrypt(data, password: password) else { return nil }
        return try? JSONDecoder().decode([Entry].self, from: json)
    }
}
