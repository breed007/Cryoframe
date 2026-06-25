//
//  EscrowCrypto.swift
//  CryoframeKit
//
//  Encrypts a passphrase-escrow bundle with a master password the user chooses, so
//  they can store it offsite and recover their archive passphrases on a new Mac
//  (the only defense against "machine died, encrypted backups now unreadable").
//  PBKDF2-SHA256 (200k rounds) → key → AES-GCM. File = magic ‖ salt ‖ sealed.
//

import Foundation
import CryptoKit
import CommonCrypto

public enum EscrowCrypto {
    private static let magic = Data("CRYOKEYS1".utf8)
    private static let saltLen = 16
    private static let rounds: UInt32 = 600_000     // OWASP guidance for PBKDF2-HMAC-SHA256

    public static func encrypt(_ plaintext: Data, password: String) -> Data? {
        var salt = Data(count: saltLen)
        let made = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, saltLen, $0.baseAddress!) }
        guard made == errSecSuccess, let key = deriveKey(password, salt: salt),
              let sealed = try? AES.GCM.seal(plaintext, using: key).combined else { return nil }
        return magic + salt + sealed
    }

    public static func decrypt(_ data: Data, password: String) -> Data? {
        guard data.count > magic.count + saltLen, data.prefix(magic.count) == magic else { return nil }
        let salt = data.subdata(in: magic.count ..< magic.count + saltLen)
        let ct = data.subdata(in: magic.count + saltLen ..< data.count)
        guard let key = deriveKey(password, salt: salt),
              let box = try? AES.GCM.SealedBox(combined: ct),
              let plaintext = try? AES.GCM.open(box, using: key) else { return nil }
        return plaintext
    }

    private static func deriveKey(_ password: String, salt: Data) -> SymmetricKey? {
        var derived = Data(count: 32)
        let pw = Array(password.utf8)
        let status = derived.withUnsafeMutableBytes { dPtr in
            salt.withUnsafeBytes { sPtr in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw, pw.count,
                                     sPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                                     dPtr.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        return status == kCCSuccess ? SymmetricKey(data: derived) : nil
    }
}
