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
            try execute(ArchivePlan.dmg(root: source.root, output: output, encrypted: encrypted),
                        stdin: passphrase.map { Data($0.utf8) })
        case .zip:
            output = dir.appendingPathComponent(source.name + ".zip"); format = .sealedZip
            try? fm.removeItem(at: output)
            try execute(ArchivePlan.zip(root: source.root, output: output))
        }
        guard fm.fileExists(atPath: output.path) else { throw ArchiveError.noArtifactProduced(output) }

        return ArchiveResult(artifacts: try maybeSplit(output, in: dir, fm: fm), format: format)
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
        let r = try runner.run(command.tool, command.args, stdin: stdin)
        guard r.ok else {
            throw ArchiveError.toolFailed(tool: (command.tool as NSString).lastPathComponent,
                                          status: r.status, stderr: r.stderr)
        }
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
