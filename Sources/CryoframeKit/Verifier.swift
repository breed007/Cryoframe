//
//  Verifier.swift
//  CryoframeKit
//
//  Verification, first-class — so the user isn't holding Schrödinger's backup.
//    - ChecksumVerifier: re-hash artifacts against the manifest. The cheap,
//      always-available mode and the periodic-re-verify hook (M6 schedules it).
//    - StrongVerifier: mount/extract the produced archive and confirm the
//      library actually opens — a SQLite integrity check on the liveDB probe,
//      the automatable form of "does it reopen clean".
//

import Foundation

public struct VerificationReport: Sendable, Equatable {
    public enum Level: String, Sendable { case checksum, mountAndOpen }
    public let level: Level
    public let passed: Bool
    public let details: String
    public let failures: [String]
}

private func report(_ level: VerificationReport.Level, _ passed: Bool,
                    _ details: String, _ failures: [String] = []) -> VerificationReport {
    VerificationReport(level: level, passed: passed, details: details, failures: failures)
}

// MARK: - checksum re-verify (periodic hook)

public struct ChecksumVerifier: Sendable {
    public init() {}

    public func verify(_ manifest: VerificationManifest, in dir: URL) throws -> VerificationReport {
        var failures: [String] = []
        for a in manifest.artifacts {
            let url = dir.appendingPathComponent(a.name)
            guard FileManager.default.fileExists(atPath: url.path) else { failures.append("missing: \(a.name)"); continue }
            if try Checksum.digest(of: url) != a.sha256 { failures.append("checksum mismatch: \(a.name)") }
        }
        return report(.checksum, failures.isEmpty,
                      failures.isEmpty ? "\(manifest.artifacts.count) artifact(s) verified" : failures.joined(separator: "; "),
                      failures)
    }

    /// the periodic-re-verify entry point: read the sidecar manifest and re-hash.
    public func reverify(archiveDir dir: URL) throws -> VerificationReport {
        let manifest = try ArchiveManifest.read(dir.appendingPathComponent(ArchiveManifest.sidecarName))
        return try verify(manifest, in: dir)
    }
}

// MARK: - mount-and-open strong verify

public struct StrongVerifier: Sendable {
    let runner: CommandRunner
    public init(runner: CommandRunner = ProcessCommandRunner()) { self.runner = runner }

    public func verify(_ result: ArchiveResult, type: ContentType, passphrase: String? = nil) throws -> VerificationReport {
        let fm = FileManager.default
        let opened = try ArchiveReader(runner: runner).open(result, passphrase: passphrase)
        defer { opened.close() }

        guard let libRoot = locateLibraryRoot(under: opened.root, probe: type.integrityProbe, fm: fm) else {
            return report(.mountAndOpen, false, "library not found inside archive", ["root/probe missing"])
        }

        if type.kind == .liveDB, let probe = type.integrityProbe {
            let db = libRoot.appendingPathComponent(probe)
            let r = try runner.run("/usr/bin/sqlite3", [db.path, "PRAGMA quick_check;"])
            let out = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let ok = r.ok && out == "ok"
            return report(.mountAndOpen, ok,
                          ok ? "\(type.displayName) reopened clean (quick_check ok)"
                             : "quick_check: \(out.isEmpty ? r.stderr.trimmingCharacters(in: .whitespacesAndNewlines) : out)",
                          ok ? [] : ["integrity check failed"])
        } else {
            // ditto has just extracted a sealed zip in full, reading every byte of
            // every entry to do it; opening each extracted file afterwards proves
            // nothing the extraction didn't. The open probe is for the mounted
            // formats, where a mount can hide a file the copy will then trip on.
            return staticReport(libRoot, fm: fm, probeReadability: result.format != .sealedZip)
        }
    }

    /// A folder library has no database to reopen, so the drill used to count the
    /// entries at its root and stop there. That is a mount test wearing a restore
    /// test's badge: an archive holding a file nobody can read passed it ("static
    /// root has 1 entries") and then failed the actual restore. The restore copies
    /// every file, so the drill opens every file — the cheapest check that fails
    /// wherever the restore would. It reads no data; open and close is what proves
    /// readability, and the checksum manifest already covers the bytes.
    /// how many unreadable files get named before the sentence stops listing them.
    static let namedUnreadableLimit = 5

    func staticReport(_ libRoot: URL, fm: FileManager, probeReadability: Bool = true) -> VerificationReport {
        var files = 0, dirs = 0
        var unreadableCount = 0
        var named: [String] = []
        // A directory the walk cannot enter is exactly as fatal to a restore as a file
        // it cannot open — the copy fails on it the same way — so it is recorded as an
        // unreadable entry rather than silently skipped, which is what an enumerator
        // does by default.
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let walker = fm.enumerator(at: libRoot, includingPropertiesForKeys: Array(keys), options: [],
                                         errorHandler: { url, error in
            unreadableCount += 1
            if named.count < Self.namedUnreadableLimit {
                let why = ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError)
                    .map { $0.domain == NSPOSIXErrorDomain ? String(cString: strerror(Int32($0.code))) : $0.localizedDescription }
                    ?? error.localizedDescription
                named.append("\(url.lastPathComponent)/ (\(why))")
            }
            return true          // keep walking; the verdict is already fixed, the count is still useful
        }) else {
            return report(.mountAndOpen, false, "couldn't read the library inside the archive", ["unreadable root"])
        }
        for case let url as URL in walker {
            let v = try? url.resourceValues(forKeys: keys)
            if v?.isDirectory == true { dirs += 1; continue }
            if v?.isSymbolicLink == true { continue }        // the target is checked on its own
            guard v?.isRegularFile == true else { continue }
            files += 1
            // once enough failures are recorded the verdict cannot change; keep counting
            // files from the prefetched attributes but stop paying for the syscall.
            guard probeReadability, unreadableCount < Self.namedUnreadableLimit else { continue }
            // O_RDONLY and straight back out. This is exactly what a restore's copy
            // needs and exactly what it fails on.
            let fd = open(url.path, O_RDONLY)
            if fd < 0 {
                unreadableCount += 1
                named.append("\(url.lastPathComponent) (\(String(cString: strerror(errno))))")
            } else {
                close(fd)
            }
        }
        // "empty" means what JobExecutor.isEmptyTree means: no files. Folders alone are
        // not a backup, and a folder-only archive is one the executor now refuses to
        // make — so the drill must not bless the ones that predate that.
        if files == 0 {
            return report(.mountAndOpen, false, "the library inside the archive has no files in it", ["empty root"])
        }
        guard unreadableCount == 0 else {
            let more = unreadableCount > named.count ? " and \(unreadableCount - named.count) more" : ""
            let checked = unreadableCount >= Self.namedUnreadableLimit ? "stopped checking after" : "\(files) file(s) checked,"
            return report(.mountAndOpen, false,
                          "\(checked) \(unreadableCount) could not be opened: \(named.joined(separator: ", "))\(more)",
                          ["unreadable files"])
        }
        let how = probeReadability ? "opened all" : "found"
        return report(.mountAndOpen, true, "\(how) \(files) file(s) in \(dirs) folder(s)", [])
    }

    /// the library may be at the archive root (dmg) or one level down (zip
    /// --keepParent, sparsebundle subdir). nil probe ⇒ static, root is fine.
    private func locateLibraryRoot(under root: URL, probe: String?, fm: FileManager) -> URL? {
        guard let probe else { return root }
        if fm.fileExists(atPath: root.appendingPathComponent(probe).path) { return root }
        if let entries = try? fm.contentsOfDirectory(atPath: root.path) {
            for e in entries {
                let candidate = root.appendingPathComponent(e)
                if fm.fileExists(atPath: candidate.appendingPathComponent(probe).path) { return candidate }
            }
        }
        return nil
    }
}
