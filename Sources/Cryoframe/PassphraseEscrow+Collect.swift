//
//  PassphraseEscrow+Collect.swift
//  Cryoframe (app)
//
//  Gathering the passphrases to escrow means reading this Mac's Keychain, which is
//  the one part of the flow that can't live in the engine.
//

import Foundation
import CryoframeKit

extension PassphraseEscrow {
    /// every encrypted job that has a stored passphrase, read straight from the keychain.
    static func collect() -> [Entry] {
        JobStore.standard().load().jobs.filter(\.encrypted).compactMap { job in
            guard let pass = KeychainArchiveKey.load(jobID: job.id) else { return nil }
            return Entry(jobID: job.id, jobName: job.name,
                         libraries: job.libraries.map(\.displayName),
                         passphrase: pass)
        }
    }
}

extension EscrowFreshness {
    /// the recovery file's standing on this Mac: every encrypted job with a saved
    /// passphrase, against what the last export covered
    static func current() -> Status {
        let jobs = JobStore.standard().load().jobs.filter(\.encrypted).compactMap { job -> Job? in
            guard KeychainArchiveKey.exists(jobID: job.id) else { return nil }
            return Job(id: job.id, name: job.name, libraries: job.libraries.map(\.displayName),
                       keySavedAt: KeychainArchiveKey.savedAt(jobID: job.id))
        }
        return status(export: lastExport(), jobs: jobs)
    }

    static func lastExport() -> Export? {
        guard let data = UserDefaults.standard.data(forKey: Prefs.escrowExport) else { return nil }
        return try? JSONDecoder().decode(Export.self, from: data)
    }

    /// remember what an export covered (never the passphrases), and tell whoever shows it
    static func remember(_ entries: [PassphraseEscrow.Entry], at date: Date = Date()) {
        guard let data = try? JSONEncoder().encode(record(entries, at: date)) else { return }
        UserDefaults.standard.set(data, forKey: Prefs.escrowExport)
        NotificationCenter.default.post(name: .escrowExported, object: nil)
    }
}

extension Notification.Name {
    static let escrowExported = Notification.Name("app.cryoframe.escrowExported")
}
