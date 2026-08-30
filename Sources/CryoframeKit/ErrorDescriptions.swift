//
//  ErrorDescriptions.swift
//  CryoframeKit
//
//  What a failed run says out loud.
//
//  These are plain Swift enums, and a plain Swift enum rendered through
//  `localizedDescription` comes out as "The operation couldn't be completed.
//  (CryoframeKit.ArchiveError error 3.)" — which is what the job row, the activity
//  log, the run history and the alert on your phone were all showing. It names
//  nothing you can act on, and it appears at exactly the moment you need to know
//  whether your backup is in trouble.
//
//  Conforming to LocalizedError fixes every one of those places at once, because
//  they all go through the same call.
//

import Foundation

extension ArchiveError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .toolFailed(let tool, _, let stderr):
            let line = stderr.split(separator: "\n").last.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            // hdiutil refuses to build a sealed DMG when any file inside carries a
            // deny-delete ACL, and says only "Permission denied" — which reads as a
            // Cryoframe permissions problem. It is not: ditto handles the same file,
            // so the sealed zip format is the way out. Every standard home folder
            // carries that ACL by default and inheriting ones propagate, so this is
            // worth naming rather than leaving as a bare errno.
            if tool == "hdiutil", stderr.localizedCaseInsensitiveContains("permission denied") {
                let which = stderr.split(separator: "\n")
                    .first { $0.localizedCaseInsensitiveContains("could not access") }
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
                return "a file in this library can't be read into a sealed DMG"
                    + (which.map { " — \($0)" } ?? "")
                    + ". A permission or ACL on it blocks hdiutil; the sealed zip format can archive it."
            }
            return line.isEmpty ? "\(tool) failed" : "\(tool) failed — \(line)"
        case .noArtifactProduced:
            return "the archive came out empty"
        case .sourceMissing(let what):
            return "couldn't read \(what)"
        case .passphraseUnavailable:
            // the actionable half matters more than the diagnosis: the backup is
            // encrypted and the key is not here, so nothing will run until it is.
            return "this job is encrypted, but its passphrase isn't on this Mac — open the job and enter it again"
        }
    }
}

extension TargetError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unavailable(let name):        return "\(name) isn't reachable"
        case .incrementalUnsupported(let name): return "\(name) can't hold a live mirror"
        }
    }
}

extension RestoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .verificationFailed(let detail): return "checksums don't match — \(detail)"
        case .libraryNotFound:                return "the archive didn't contain the library"
        case .destinationExists(let path):    return "something is already at \(path)"
        case .noManifest:                     return "no checksum manifest beside the archive"
        }
    }
}

extension SnapshotBackendError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .commandFailed(let tool, _, let stderr):
            let line = stderr.split(separator: "\n").last.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            return line.isEmpty ? "\(tool) failed" : "\(tool) failed — \(line)"
        case .couldNotIdentifyNewSnapshot:
            return "the snapshot was taken but couldn't be identified afterwards"
        case .refusedForeignSnapshot(let name):
            return "refused to delete \(name) — Cryoframe only removes snapshots it made"
        case .malformedSnapshotName(let name):
            return "not a snapshot name Cryoframe recognises: \(name)"
        case .dataVolumeNotFound:
            return "couldn't find the Data volume to snapshot"
        }
    }
}
