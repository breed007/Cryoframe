//
//  SparseBundleMirrorEngine.swift
//  CryoframeKit
//
//  Live mirror: an APFS sparsebundle with ~8MB bands. First run creates it;
//  subsequent runs rsync --delete into the attached volume, so only the bands
//  that changed are rewritten. Same incremental mechanism Time Machine uses for
//  network targets.
//

import Foundation

public struct SparseBundleMirrorEngine: ArchiveEngine {
    let sizeGB: Int
    let bandSectors: Int          // 16384 sectors * 512 = 8 MiB bands
    let runner: CommandRunner

    public init(sizeGB: Int, bandSectors: Int = 16384, runner: CommandRunner = ProcessCommandRunner()) {
        self.sizeGB = sizeGB; self.bandSectors = bandSectors; self.runner = runner
    }

    public func archive(_ source: ArchiveSource, to destinationDir: URL) throws -> ArchiveResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.root.path) else {
            throw ArchiveError.sourceMissing(source.root.path)
        }
        try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        // isDirectory: true — otherwise appendingPathComponent stats the disk and
        // adds a trailing slash once the bundle exists, so run 1 and run 2 differ.
        let bundle = destinationDir.appendingPathComponent(source.name + ".sparsebundle", isDirectory: true)
        if !fm.fileExists(atPath: bundle.path) {
            try execute(ArchivePlan.sparseBundleCreate(output: bundle, name: source.name,
                                                       sizeGB: sizeGB, bandSectors: bandSectors))
        }

        // attach at a private mountpoint, mirror, detach — no namespace parsing.
        let mountpoint = destinationDir.appendingPathComponent(".\(source.name).mirror-mnt")
        try? fm.removeItem(at: mountpoint)
        try fm.createDirectory(at: mountpoint, withIntermediateDirectories: true)
        defer {
            _ = try? runner.run(ArchivePlan.detach(mountpoint: mountpoint).tool,
                                ArchivePlan.detach(mountpoint: mountpoint).args)
            try? fm.removeItem(at: mountpoint)
        }

        try execute(ArchivePlan.attach(image: bundle, mountpoint: mountpoint))
        let dest = mountpoint.appendingPathComponent(source.root.lastPathComponent)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        try execute(ArchivePlan.rsync(root: source.root, into: dest))
        try execute(ArchivePlan.detach(mountpoint: mountpoint))

        return ArchiveResult(artifacts: [bundle], format: .liveMirror)
    }

    private func execute(_ command: Command) throws {
        let r = try runner.run(command.tool, command.args)
        guard r.ok else {
            throw ArchiveError.toolFailed(tool: (command.tool as NSString).lastPathComponent,
                                          status: r.status, stderr: r.stderr)
        }
    }
}
