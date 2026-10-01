//
//  SealedArchiveEngine.swift
//  CryoframeKit
//
//  Sealed cold-storage archive: read-only UDZO dmg or ditto zip, optionally
//  split into sub-ceiling volumes. dmg splits natively via hdiutil -segmentSize;
//  zip is split post-hoc with split(1).
//

import Foundation

public struct SealedArchiveEngine: ArchiveEngine {
    public enum Sealed: Sendable { case dmg, zip }

    let sealed: Sealed
    let split: SplitPolicy
    let runner: CommandRunner
    let passphrase: String?          // AES-256 encryption for dmg when set (zip is never encrypted)

    public init(_ sealed: Sealed, split: SplitPolicy = .none,
                runner: CommandRunner = ProcessCommandRunner(), passphrase: String? = nil) {
        self.sealed = sealed; self.split = split; self.runner = runner; self.passphrase = passphrase
    }

    public func archive(_ source: ArchiveSource, to destinationDir: URL) throws -> ArchiveResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.root.path) else {
            throw ArchiveError.sourceMissing(source.root.path)
        }
        let dir = destinationDir
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let output: URL
        let format: ArchiveFormat
        switch sealed {
        case .dmg:
            output = dir.appendingPathComponent(source.name + ".dmg"); format = .sealedDMG
            try? fm.removeItem(at: output)
            let encrypted = passphrase != nil
            try execute(ArchivePlan.dmg(root: source.root, output: output, encrypted: encrypted,
                                        sizeMB: DMGSizing.sizeMB(for: source.root)),
                        stdin: passphrase.map { Data($0.utf8) })
        case .zip:
            output = dir.appendingPathComponent(source.name + ".zip"); format = .sealedZip
            try? fm.removeItem(at: output)
            try execute(ArchivePlan.zip(root: source.root, output: output))
        }
        guard fm.fileExists(atPath: output.path) else { throw ArchiveError.noArtifactProduced(output) }

        return ArchiveResult(artifacts: try maybeSplit(output, in: dir, fm: fm), format: format)
    }

    /// place an already-built artifact into a destination, applying this engine's split
    /// policy and writing the checksum manifest. Lets a sealed archive be built once and
    /// copied to several destinations (each with its own split cap) without recompressing.
    public func distribute(builtFile: URL, into destDir: URL, encrypted: Bool) throws -> ArchiveResult {
        let fm = FileManager.default
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        let copied = destDir.appendingPathComponent(builtFile.lastPathComponent)
        try? fm.removeItem(at: copied)
        try fm.copyItem(at: builtFile, to: copied)
        let format: ArchiveFormat = sealed == .dmg ? .sealedDMG : .sealedZip
        let result = ArchiveResult(artifacts: try maybeSplit(copied, in: destDir, fm: fm), format: format)
        try ArchiveManifest.write(try ArchiveManifest.build(for: result, encrypted: encrypted), toDir: destDir)
        return result
    }

    // MARK: helpers

    /// split the finished artifact into <cap>-byte parts (reassemble with `cat`).
    /// applies to both dmg and zip — `split(1)` is byte-exact and format-agnostic.
    private func maybeSplit(_ output: URL, in dir: URL, fm: FileManager) throws -> [URL] {
        guard case .maxBytes(let cap) = split,
              let size = (try? fm.attributesOfItem(atPath: output.path)[.size]) as? UInt64,
              size > cap else {
            return [output]                                   // under cap: single file
        }
        let prefix = output.path + ".part."
        try execute(ArchivePlan.split(file: output, cap: cap, prefix: prefix))
        try? fm.removeItem(at: output)                        // keep only the parts
        return try partArtifacts(prefix: prefix, in: dir, fm: fm)
    }

    private func execute(_ command: Command, stdin: Data? = nil) throws {
        let r = try runner.runRetryingBusy(command.tool, command.args, stdin: stdin)
        guard r.ok else {
            throw ArchiveError.toolFailed(tool: (command.tool as NSString).lastPathComponent,
                                          status: r.status, stderr: Self.failureText(r))
        }
    }

    /// What a failed tool said. hdiutil names the file it couldn't copy on standard
    /// output ("could not access <file> - Permission denied", measured on macOS 27),
    /// and only "create failed" on standard error, so the lines of its output that
    /// name a file go first: without them the explanation that names the file and
    /// points at the sealed zip (see ArchiveError) never fired.
    static func failureText(_ r: CommandResult) -> String {
        let named = r.stdout.split(whereSeparator: \.isNewline).map(String.init).filter {
            $0.localizedCaseInsensitiveContains("could not access") || $0.localizedCaseInsensitiveContains("Permission denied")
                || $0.localizedCaseInsensitiveContains("Operation not permitted")
        }
        guard !named.isEmpty else { return r.stderr }
        return named.joined(separator: "\n") + "\n" + r.stderr
    }

    private func partArtifacts(prefix: String, in dir: URL, fm: FileManager) throws -> [URL] {
        let base = (prefix as NSString).lastPathComponent
        let entries = try fm.contentsOfDirectory(atPath: dir.path)
        return entries
            .filter { $0.hasPrefix(base) }
            .sorted()
            .map { dir.appendingPathComponent($0) }
    }
}
