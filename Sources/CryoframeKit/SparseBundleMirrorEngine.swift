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
    let passphrase: String?       // AES-256 encryption when set

    public init(sizeGB: Int, bandSectors: Int = 16384,
                runner: CommandRunner = ProcessCommandRunner(), passphrase: String? = nil) {
        self.sizeGB = sizeGB; self.bandSectors = bandSectors; self.runner = runner; self.passphrase = passphrase
    }

    public func archive(_ source: ArchiveSource, to destinationDir: URL) throws -> ArchiveResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.root.path) else {
            throw ArchiveError.sourceMissing(source.root.path)
        }
        try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        // isDirectory: true — otherwise appendingPathComponent stats the disk and
        // adds a trailing slash once the bundle exists, so run 1 and run 2 differ.
        let stdin = passphrase.map { Data($0.utf8) }
        let encrypted = passphrase != nil
        let bundle = destinationDir.appendingPathComponent(source.name + ".sparsebundle", isDirectory: true)

        // attach at a private mountpoint, mirror, detach — no namespace parsing.
        //
        // The mountpoint is where the only copy of the mirror appears, so it is never
        // removed recursively (see MountPoint). A leftover from a crashed or stopped
        // run may still have the image attached there; that is detached, not deleted
        // through. Teardown uses a runner that still works after Stop.
        let mountpoint = destinationDir.appendingPathComponent(".\(source.name).mirror-mnt")
        let teardown = runner.forTeardown
        try MountPoint.clear(mountpoint, runner: teardown)

        if !fm.fileExists(atPath: bundle.path) {
            try execute(ArchivePlan.sparseBundleCreate(output: bundle, name: source.name,
                                                       sizeGB: sizeGB, bandSectors: bandSectors,
                                                       encrypted: encrypted), stdin: stdin)
        }

        try fm.createDirectory(at: mountpoint, withIntermediateDirectories: true)
        defer { MountPoint.detach(mountpoint, runner: teardown) }

        try DiskImageGate.serialized { try execute(ArchivePlan.attach(image: bundle, mountpoint: mountpoint, encrypted: encrypted), stdin: stdin) }
        // hdiutil answers 0 when the image is already attached somewhere else (the
        // restore window browsing it, say), and then nothing is mounted here: rsync
        // would write into the destination disk beside the image instead of into it.
        // Refuse rather than detach someone else's open copy.
        guard MountPoint.isMounted(mountpoint) else {
            throw ArchiveError.toolFailed(tool: "hdiutil", status: 0,
                                          stderr: "the mirror is already open somewhere else (the restore window, or another run of this job), so it did not mount at \(mountpoint.path)")
        }
        let dest = mountpoint.appendingPathComponent(source.root.lastPathComponent)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        try execute(ArchivePlan.rsync(root: source.root, into: dest))
        try execute(ArchivePlan.detach(mountpoint: mountpoint))

        return ArchiveResult(artifacts: [bundle], format: .liveMirror)
    }

    private func execute(_ command: Command, stdin: Data? = nil) throws {
        let r = try runner.runRetryingBusy(command.tool, command.args, stdin: stdin)
        guard r.ok else {
            throw ArchiveError.toolFailed(tool: (command.tool as NSString).lastPathComponent,
                                          status: r.status, stderr: r.stderr)
        }
    }
}
