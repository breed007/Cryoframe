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
        } else {
            try growIfSmallerThanRequested(bundle, stdin: stdin)
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

    /// The mirror's size used to be fixed at creation: editing it did nothing, which
    /// left a library that outgrew its 500 GB default failing with "no space" from
    /// inside the image. A larger size is now applied here, detached, before the run.
    /// Never shrinks: a smaller request is refused in the job editor.
    private func growIfSmallerThanRequested(_ bundle: URL, stdin: Data?) throws {
        let encrypted = passphrase != nil
        let limits = ArchivePlan.resizeLimits(image: bundle, encrypted: encrypted)
        guard let r = try? runner.run(limits.tool, limits.args, stdin: stdin), r.ok,
              let current = Self.currentSectors(r.stdout) else { return }   // unknown: leave it as it is
        guard current < Self.sectors(gb: sizeGB) * 99 / 100 else { return }   // within partition overhead
        try execute(ArchivePlan.resize(image: bundle, sizeGB: sizeGB, encrypted: encrypted), stdin: stdin)
    }

    /// `hdiutil resize -limits` prints "min current max" in 512-byte sectors.
    static func currentSectors(_ limits: String) -> UInt64? {
        let f = limits.split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" })
        return f.count >= 3 ? UInt64(f[1]) : nil
    }

    /// hdiutil's "g" is GiB
    static func sectors(gb: Int) -> UInt64 { UInt64(max(gb, 0)) * (1 << 30) / 512 }

    private func execute(_ command: Command, stdin: Data? = nil) throws {
        let r = try runner.runRetryingBusy(command.tool, command.args, stdin: stdin)
        guard r.ok else {
            throw ArchiveError.toolFailed(tool: (command.tool as NSString).lastPathComponent,
                                          status: r.status, stderr: r.stderr)
        }
    }
}
