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
            if try Checksum.sha256(of: url) != a.sha256 { failures.append("checksum mismatch: \(a.name)") }
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
            let entries = (try? fm.contentsOfDirectory(atPath: libRoot.path))?.count ?? 0
            return report(.mountAndOpen, entries > 0, "static root has \(entries) entries",
                          entries > 0 ? [] : ["empty root"])
        }
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
