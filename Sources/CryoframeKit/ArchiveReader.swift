//
//  ArchiveReader.swift
//  CryoframeKit
//
//  Opens a produced archive for reading — mount a dmg/sparsebundle read-only, or
//  extract a zip — reassembling split parts first. Shared by StrongVerifier
//  (mount-and-open check) and RestoreEngine (copy the library back out).
//

import Foundation

public struct OpenedArchive: Sendable {
    public let root: URL                 // the mounted/extracted tree to read from
    let work: URL                        // temp scratch to delete on close
    let teardownFn: @Sendable () -> Void

    /// detach the mount (if any) and remove the scratch dir. Always call this.
    public func close() {
        teardownFn()
        try? FileManager.default.removeItem(at: work)
    }
}

public struct ArchiveReader: Sendable {
    let runner: CommandRunner
    public init(runner: CommandRunner = ProcessCommandRunner()) { self.runner = runner }

    /// open `result` into a fresh temp work dir. A non-nil `passphrase` mounts an
    /// AES-256 encrypted dmg/sparsebundle (via `hdiutil -stdinpass`). The caller
    /// MUST `close()` the returned handle to detach the mount and clean up.
    public func open(_ result: ArchiveResult, passphrase: String? = nil) throws -> OpenedArchive {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("cf-open-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let runner = self.runner
        let enc = passphrase != nil
        let stdin = passphrase.map { Data($0.utf8) }

        switch result.format {
        case .sealedDMG:
            let dmg = try singleFile(result.artifacts, work: work, name: "reassembled.dmg", fm: fm)
            let mnt = work.appendingPathComponent("mnt"); try fm.createDirectory(at: mnt, withIntermediateDirectories: true)
            try exec(ArchivePlan.attach(image: dmg, mountpoint: mnt, readonly: true, encrypted: enc), stdin: stdin)
            return OpenedArchive(root: mnt, work: work) { Self.detach(mnt, runner: runner) }

        case .liveMirror:
            let mnt = work.appendingPathComponent("mnt"); try fm.createDirectory(at: mnt, withIntermediateDirectories: true)
            try exec(ArchivePlan.attach(image: result.artifacts[0], mountpoint: mnt, readonly: true, encrypted: enc), stdin: stdin)
            return OpenedArchive(root: mnt, work: work) { Self.detach(mnt, runner: runner) }

        case .sealedZip:
            let zip = try singleFile(result.artifacts, work: work, name: "reassembled.zip", fm: fm)
            let ex = work.appendingPathComponent("extract"); try fm.createDirectory(at: ex, withIntermediateDirectories: true)
            try exec(Command("/usr/bin/ditto", ["-x", "-k", zip.path, ex.path]))
            return OpenedArchive(root: ex, work: work) {}
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

    private func exec(_ command: Command, stdin: Data? = nil) throws {
        let r = try runner.runRetryingBusy(command.tool, command.args, stdin: stdin)
        guard r.ok else {
            throw ArchiveError.toolFailed(tool: (command.tool as NSString).lastPathComponent,
                                          status: r.status, stderr: r.stderr)
        }
    }

    /// detach a browse mount, retrying then forcing — Finder holding the mount open
    /// otherwise leaves it (and the temp dir) attached after "Done browsing".
    @Sendable static func detach(_ mnt: URL, runner: CommandRunner) {
        for i in 0..<5 {
            if let r = try? runner.run("/usr/bin/hdiutil", ["detach", mnt.path]), r.ok { return }
            Thread.sleep(forTimeInterval: 0.4 * Double(i + 1))
        }
        _ = try? runner.run("/usr/bin/hdiutil", ["detach", "-force", mnt.path])
    }

    /// on launch, force-detach and remove any browse mounts left attached by a crash.
    public static func sweepStaleOpens() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil) else { return }
        let runner = ProcessCommandRunner()
        for e in entries where e.lastPathComponent.hasPrefix("cf-open-") {
            let mnt = e.appendingPathComponent("mnt")
            if fm.fileExists(atPath: mnt.path) { _ = try? runner.run("/usr/bin/hdiutil", ["detach", "-force", mnt.path]) }
            try? fm.removeItem(at: e)
        }
    }
}
