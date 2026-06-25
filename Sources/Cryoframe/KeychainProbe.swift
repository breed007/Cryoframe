//
//  KeychainProbe.swift
//  Cryoframe (app)
//
//  Diagnostic: prove the scheduled agent (a separate, headless process of the same
//  signed binary) can read an encrypted job's passphrase from the login keychain
//  without a prompt. Run as two processes to mirror "GUI writes, agent reads":
//    CRYOFRAME_KCPROBE=write ./Cryoframe   # process 1 stores
//    CRYOFRAME_KCPROBE=read  ./Cryoframe   # process 2 reads it back
//

import Foundation

enum KeychainProbe {
    private static let jobID = "__kcprobe__"
    private static let secret = "kcprobe-shared-secret-v1"

    static func run(_ mode: String) {
        let out: String
        switch mode {
        case "write":
            out = "KCPROBE write saved=\(KeychainArchiveKey.save(secret, jobID: jobID))"
        case "read":
            let loaded = KeychainArchiveKey.load(jobID: jobID)
            out = "KCPROBE read found=\(loaded != nil) match=\(loaded == secret)"
        default:
            KeychainArchiveKey.delete(jobID: jobID)
            out = "KCPROBE clean"
        }
        FileHandle.standardError.write((out + "\n").data(using: .utf8)!)
        exit(mode == "read" && KeychainArchiveKey.load(jobID: jobID) != secret ? 2 : 0)
    }
}
