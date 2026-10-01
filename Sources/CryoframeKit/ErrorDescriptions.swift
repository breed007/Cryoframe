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
            let lines = ProcessCommandRunner.meaningful(stderr).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            // hdiutil refuses to BUILD a sealed DMG when any file inside carries a
            // deny-delete ACL, and says only "Permission denied" — which reads as a
            // Cryoframe permissions problem. It is not: ditto handles the same file,
            // so the sealed zip format is the way out. Every standard home folder
            // carries that ACL by default and inheriting ones propagate, so this is
            // worth naming rather than leaving as a bare errno.
            //
            // Keyed on hdiutil failing to READ a source file specifically. The same
            // tool also reports an attach that was refused, at verify or drill time,
            // and a live mirror's first `create` into a folder it may not write; telling
            // either of those people to switch source formats is wrong on both the
            // cause and the remedy.
            if tool == "hdiutil", Self.isCreateRefusedByACL(lines) {
                let which = lines.first { $0.localizedCaseInsensitiveContains("could not access") }
                    .map { l in
                        // hdiutil prints this line with no newline before its own
                        // "hdiutil: create failed", so cut the two apart
                        l.range(of: "hdiutil:").map { String(l[..<$0.lowerBound]) } ?? l
                    }
                return "a file in this library can't be read into a sealed DMG"
                    + (which.map { " — \($0)" } ?? "")
                    + ". A permission or ACL on it blocks hdiutil; the sealed zip format can archive it."
            }
            // macOS 15's hdiutil can't build from a folder holding a locked item, and
            // names it inside the temporary volume it builds on ("could not access
            // /Volumes/<library>/locked.txt - Operation not permitted"), a path that
            // exists nowhere once the run is over. Builds of such folders read an
            // unlocked copy (see SealedReadPlan); this says what to do if one is
            // refused anyway.
            if tool == "hdiutil", let item = Self.itemRefusedAsLocked(lines) {
                return "macOS's disk image tool couldn't copy \(item) into the disk image (Operation not permitted). That is what it does with a locked item (Finder's Get Info, Locked). Unlock it, or switch this job to the sealed zip format, which archives it."
            }
            let line = lines.last ?? ""
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

extension ArchiveError {
    /// hdiutil's stderr for a `create -srcfolder` that hit a file it may not read.
    /// Measured: "could not access <path> - Permission denied", glued to the
    /// "hdiutil: create failed - Permission denied" that follows it. A bare "create
    /// failed - Permission denied" is NOT this: it is also what a live mirror's
    /// sparsebundle create says when the destination folder refuses the write. An
    /// attach refusal says "attach failed" and must not match either.
    /// The item a `create -srcfolder` couldn't copy for "Operation not permitted",
    /// named within the library: hdiutil names it on the volume it builds, at
    /// /Volumes/<volume>/…, which is gone once it fails. nil for any other failure.
    static func itemRefusedAsLocked(_ lines: [String]) -> String? {
        guard let line = lines.first(where: { l in
            let lc = l.lowercased()
            return lc.contains("could not access") && lc.contains("operation not permitted")
        }), let start = line.range(of: "could not access ", options: .caseInsensitive) else { return nil }
        var path = String(line[start.upperBound...])
        // printed with no newline before hdiutil's own "hdiutil: create failed"
        if let glued = path.range(of: "hdiutil:") { path = String(path[..<glued.lowerBound]) }
        if let end = path.range(of: " - ", options: .backwards) { path = String(path[..<end.lowerBound]) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        if path.hasPrefix("/Volumes/"), parts.count > 2 { return parts.dropFirst(2).joined(separator: "/") }
        return parts.last.map(String.init) ?? "a file"
    }

    static func isCreateRefusedByACL(_ lines: [String]) -> Bool {
        lines.contains { l in
            let lc = l.lowercased()
            return lc.contains("could not access") && lc.contains("permission denied")
        }
    }
}

/// What a person reads when a restore's copy fails.
///
/// Foundation reports a failed copy as an NSCocoaError whose description names the
/// path it was reading from — inside /private/var/folders, in a scratch directory
/// that exists only while the archive is mounted — and whose underlying POSIX error
/// renders as "The operation couldn't be completed. Permission denied". Three
/// renderers (the restore sheet, the recovery wizard, the scheduled rehearsal whose
/// text reaches notifications and alerts) all receive that same error from the same
/// RestoreEngine copy, so the sentence is made in one place.
public enum RestoreFailureText {
    /// the file and the plain reason, or nil when this isn't a file-level failure.
    public static func copyFailure(_ e: Error) -> String? {
        let ns = e as NSError
        guard let path = ns.userInfo[NSFilePathErrorKey] as? String else { return nil }
        let file = (path as NSString).lastPathComponent
        let reason: String
        if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError, u.domain == NSPOSIXErrorDomain {
            reason = String(cString: strerror(Int32(u.code)))          // "Permission denied", not the boilerplate around it
        } else if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError, let r = u.localizedFailureReason {
            reason = r
        } else {
            reason = ns.localizedFailureReason ?? "it couldn't be copied"
        }
        let plain = reason.prefix(1).lowercased() + reason.dropFirst()
        return "couldn't restore \(file) — \(plain)"
    }

    /// the numbers, and what to do: nothing was written
    static func roomMessage(needed: UInt64, free: UInt64, volume: String, inPlace: Bool) -> String {
        func size(_ b: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: b), countStyle: .file) }
        if inPlace {
            return "not enough room on \(volume) to restore in place: it needs about \(size(needed)) free and has \(size(free)). The verified copy is made beside your library before it is swapped in, and your current library goes to the Trash on the same drive, where it keeps its space until you empty the Trash. Nothing was changed; free up space, or restore beside to another drive."
        }
        return "not enough room on \(volume): this restore needs about \(size(needed)) free and there is \(size(free)). Nothing was written; free up space, or choose a folder on another drive."
    }

    /// a zip unpacked without knowing beforehand what that takes (see ArchiveReader)
    static func unpackedSizeWarning(_ zip: String) -> String {
        "Cryoframe couldn't read the list of what \(zip) holds, so it unpacked it on the startup disk without first checking that there was room. The zip may be damaged; its checksum says whether it is."
    }

    /// why one archive failed to restore, for the Restore window's result list.
    public static func restoreMessage(_ e: Error, encrypted: Bool) -> String {
        switch e as? RestoreError {
        case .verificationFailed(let d): return "verification failed — \(d)"
        case .destinationExists:         return "already exists in the destination — rename or move it, then try again"
        case .libraryNotFound:           return "library not found inside the archive"
        case .noManifest:                return "no checksum manifest beside the archive"
        case .notEnoughRoom(let needed, let free, let volume, let inPlace):
            return roomMessage(needed: needed, free: free, volume: volume, inPlace: inPlace)
        case .none: break
        }
        // an ArchiveError surfaces when the archive itself won't open. Its raw
        // description is Swift internals ("ArchiveError error 0"), so say what
        // actually happened and what to do about it.
        if let a = e as? ArchiveError {
            switch a {
            case .toolFailed(let tool, _, let stderr):
                if encrypted { return "couldn't open the archive — check the passphrase" }
                let detail = ProcessCommandRunner.meaningful(stderr).split(separator: "\n").last.map(String.init) ?? ""
                return detail.isEmpty ? "couldn't open the archive (\(tool) failed)"
                                      : "couldn't open the archive — \(detail)"
            case .noArtifactProduced:   return "the archive is missing its files"
            case .sourceMissing(let s): return "missing part of the archive — \(s)"
            case .passphraseUnavailable: return "this archive is encrypted and no passphrase was found"
            }
        }
        // before the encrypted fallback: a copy that failed on one file happened after
        // the archive opened, so the passphrase was fine
        if let copy = copyFailure(e) { return copy }
        if encrypted { return "couldn't open the archive — check the passphrase" }
        return (e as NSError).localizedDescription
    }

    /// why one library failed to come back, for the recovery wizard. Worded for
    /// someone rebuilding a Mac: it speaks of the recovery key, and never suggests
    /// moving what is already in place.
    public static func recoveryMessage(_ e: Error, encrypted: Bool) -> String {
        if let r = e as? RestoreError {
            switch r {
            case .verificationFailed(let d): return "verification failed — \(d)"
            case .destinationExists(let p):  return "something is already at \((p as NSString).lastPathComponent) — it was left alone"
            case .libraryNotFound:           return "the archive didn't contain the library"
            case .noManifest:                return "no checksum manifest beside the archive"
            case .notEnoughRoom(let needed, let free, let volume, let inPlace):
                return roomMessage(needed: needed, free: free, volume: volume, inPlace: inPlace)
            }
        }
        if let a = e as? ArchiveError {
            switch a {
            case .toolFailed(_, _, let stderr):
                if encrypted { return "couldn't open — check the recovery key" }
                return "couldn't open the archive — \(ProcessCommandRunner.meaningful(stderr).split(separator: "\n").last.map(String.init) ?? "unreadable")"
            case .noArtifactProduced:    return "the archive is missing its files"
            case .sourceMissing(let s):  return "missing part of the archive — \(s)"
            case .passphraseUnavailable: return "encrypted, and no passphrase was recovered"
            }
        }
        if let copy = copyFailure(e) { return copy }
        return (e as NSError).localizedDescription
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
        case .notEnoughRoom(let needed, let free, let volume, let inPlace):
            return RestoreFailureText.roomMessage(needed: needed, free: free, volume: volume, inPlace: inPlace)
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
