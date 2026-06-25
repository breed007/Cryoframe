//
//  KeychainArchiveKey.swift
//  Cryoframe (app)
//
//  Stores a job's archive passphrase in the login keychain, keyed by job id, so it
//  never lives in the job JSON and unattended (scheduled) runs can encrypt without a
//  prompt. The app and the scheduled agent are the same signed binary, so they share
//  access to the item with no dialog. The login keychain (not the data-protection
//  keychain, which needs an app-identifier entitlement we don't ship) is what works
//  for a Developer ID app. Lose the passphrase and the backup is unrecoverable.
//

import Foundation
import Security

enum KeychainArchiveKey {
    private static let service = "app.cryoframe.archive"

    private static func base(_ jobID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: jobID]
    }

    @discardableResult
    static func save(_ passphrase: String, jobID: String) -> Bool {
        SecItemDelete(base(jobID) as CFDictionary)
        var add = base(jobID)
        add[kSecValueData as String] = Data(passphrase.utf8)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func load(jobID: String) -> String? {
        var query = base(jobID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(jobID: String) {
        SecItemDelete(base(jobID) as CFDictionary)
    }

    static func exists(jobID: String) -> Bool { load(jobID: jobID) != nil }
}
