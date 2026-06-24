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

    public func verify(_ result: ArchiveResult, type: ContentType) throws -> VerificationReport {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("cf-verify-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let opened = try open(result, work: work, fm: fm)
        defer { opened.teardown() }

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

    // MARK: opening the archive

    private struct Opened { let root: URL; let teardown: () -> Void }

    private func open(_ result: ArchiveResult, work: URL, fm: FileManager) throws -> Opened {
        switch result.format {
        case .sealedDMG:
            let dmg = try singleFile(result.artifacts, work: work, name: "reassembled.dmg", fm: fm)
            let mnt = work.appendingPathComponent("mnt"); try fm.createDirectory(at: mnt, withIntermediateDirectories: true)
            try exec(ArchivePlan.attach(image: dmg, mountpoint: mnt, readonly: true))
            return Opened(root: mnt) { _ = try? self.runner.run("/usr/bin/hdiutil", ["detach", mnt.path]) }

        case .liveMirror:
            let mnt = work.appendingPathComponent("mnt"); try fm.createDirectory(at: mnt, withIntermediateDirectories: true)
            try exec(ArchivePlan.attach(image: result.artifacts[0], mountpoint: mnt, readonly: true))
            return Opened(root: mnt) { _ = try? self.runner.run("/usr/bin/hdiutil", ["detach", mnt.path]) }

        case .sealedZip:
            let zip = try singleFile(result.artifacts, work: work, name: "reassembled.zip", fm: fm)
            let ex = work.appendingPathComponent("extract"); try fm.createDirectory(at: ex, withIntermediateDirectories: true)
            try exec(Command("/usr/bin/ditto", ["-x", "-k", zip.path, ex.path]))
            return Opened(root: ex) {}
        }
    }

    /// a single file to operate on — the artifact itself, or split parts reassembled.
    private func singleFile(_ artifacts: [URL], work: URL, name: String, fm: FileManager) throws -> URL {
        if artifacts.count == 1 { return artifacts[0] }
        let out = work.appendingPathComponent(name)
        fm.createFile(atPath: out.path, contents: nil)
        let w = try FileHandle(forWritingTo: out); defer { try? w.close() }
        for part in artifacts.sorted(by: { $0.path < $1.path }) {
            let r = try FileHandle(forReadingFrom: part); defer { try? r.close() }
            while true {
                let chunk = try r.read(upToCount: 1 << 20) ?? Data()
                if chunk.isEmpty { break }
                try w.write(contentsOf: chunk)
            }
        }
        return out
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

    private func exec(_ command: Command) throws {
        let r = try runner.run(command.tool, command.args)
        guard r.ok else {
            throw ArchiveError.toolFailed(tool: (command.tool as NSString).lastPathComponent,
                                          status: r.status, stderr: r.stderr)
        }
    }
}
