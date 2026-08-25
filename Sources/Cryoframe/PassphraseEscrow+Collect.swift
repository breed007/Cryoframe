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
            return Entry(jobName: job.name,
                         libraries: job.libraries.map(\.displayName),
                         passphrase: pass)
        }
    }
}
