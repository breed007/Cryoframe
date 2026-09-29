//
//  SparseBundleMirrorEngine.swift
//  CryoframeKit
//
//  Live mirror: an APFS sparsebundle with ~8MB bands. First run creates it;
//  subsequent runs rsync --delete into the attached volume, so only the bands
//  that changed are rewritten. Same incremental mechanism Time Machine uses for
//  network targets. The rsync goes into a clone that replaces the library copy
//  only once it is complete (see MirrorCopy).
//

import Foundation

public struct SparseBundleMirrorEngine: ArchiveEngine {
    let sizeGB: Int
    let bandSectors: Int          // 16384 sectors * 512 = 8 MiB bands
    let runner: CommandRunner
    let passphrase: String?       // AES-256 encryption when set
    let mountBase: URL            // where the image is attached while a run updates it (see MirrorMounts)

    public init(sizeGB: Int, bandSectors: Int = 16384,
                runner: CommandRunner = ProcessCommandRunner(), passphrase: String? = nil,
                mountBase: URL = MirrorMounts.defaultBase) {
        self.sizeGB = sizeGB; self.bandSectors = bandSectors; self.runner = runner; self.passphrase = passphrase
        self.mountBase = mountBase
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

        let result = ArchiveResult(artifacts: [bundle], format: .liveMirror)

        // The manifest describes the image at rest, and a run changes the image from
        // the moment it attaches. Mark it open first, so a run that dies anywhere
        // after this leaves a mirror whose checksum is known not to apply (see
        // MirrorSeal), rather than one that looks corrupt.
        let wasSealed = fm.fileExists(atPath: destinationDir.appendingPathComponent(ArchiveManifest.sidecarName).path)
        try MirrorSeal.markOpen(destinationDir)
        var touched = false
        do {
            try update(source, in: destinationDir, bundle: bundle, stdin: stdin, touched: &touched)
        } catch {
            if !touched {
                MirrorSeal.clearOpen(destinationDir)       // never changed: the manifest still holds
            } else if wasSealed, MirrorMounts.mountPoints(of: bundle, runner: runner.forTeardown).isEmpty {
                // Stopped or failed, but closed: the copy inside is the previous complete
                // one (MirrorCopy only swaps after rsync succeeds), so the manifest can
                // describe the image as it now is.
                try? MirrorSeal.seal(result, in: destinationDir, encrypted: encrypted)
            }
            throw error
        }
        try MirrorSeal.seal(result, in: destinationDir, encrypted: encrypted)
        return result
    }

    /// create or grow the image, attach it, bring the library copy up to date, detach.
    private func update(_ source: ArchiveSource, in destinationDir: URL, bundle: URL, stdin: Data?,
                        touched: inout Bool) throws {
        let fm = FileManager.default
        let encrypted = passphrase != nil
        // The image is attached at a directory of this run's own on the boot volume,
        // never inside the destination: macOS won't mount on a volume that ignores
        // ownership, which external drives do by default (see MirrorMounts).
        //
        // That mountpoint is where the only copy of the mirror appears, so it is never
        // removed recursively (see MountPoint). A crashed or stopped run may have left
        // the image attached; that is detached, not deleted through. Teardown uses a
        // runner that still works after Stop.
        let teardown = runner.forTeardown
        // before 1.6 a run attached inside the destination; a crash there left it so
        let legacy = destinationDir.appendingPathComponent(".\(source.name).mirror-mnt")
        if fm.fileExists(atPath: legacy.path) { try MountPoint.clear(legacy, runner: teardown) }
        MirrorMounts.releaseAbandoned(bundle, runner: teardown)

        // `touched`: from here on the image may differ from its manifest
        if !fm.fileExists(atPath: bundle.path) {
            touched = true
            try execute(ArchivePlan.sparseBundleCreate(output: bundle, name: source.name,
                                                       sizeGB: sizeGB, bandSectors: bandSectors,
                                                       encrypted: encrypted), stdin: stdin)
        } else {
            try growIfSmallerThanRequested(bundle, stdin: stdin, touched: &touched)
        }

        let work = try MirrorMounts.makeWork(in: mountBase)
        let mountpoint = work.appendingPathComponent("mnt", isDirectory: true)
        defer {
            MountPoint.detach(mountpoint, runner: teardown)
            OpenedArchive.removeWork(work)          // only once nothing is mounted there
        }
        try fm.createDirectory(at: mountpoint, withIntermediateDirectories: true)

        try DiskImageGate.serialized { try execute(ArchivePlan.attach(image: bundle, mountpoint: mountpoint, encrypted: encrypted), stdin: stdin) }
        // hdiutil answers 0 when the image is already attached somewhere else (the
        // restore window browsing it, say), and then nothing is mounted here: rsync
        // would write onto the startup disk instead of into the image.
        // Refuse rather than detach someone else's open copy.
        guard MountPoint.isMounted(mountpoint) else {
            throw ArchiveError.toolFailed(tool: "hdiutil", status: 0,
                                          stderr: "the mirror is already open somewhere else (the restore window, or another run of this job), so it did not mount at \(mountpoint.path)")
        }
        touched = true          // attached read-write: the image changes from here
        // rsync into a clone and swap, so the copy restore reads is never half-updated
        try MirrorCopy.update(volume: mountpoint, name: source.root.lastPathComponent, source: source.root,
                              runner: runner, execute: { try execute($0) })
        try execute(ArchivePlan.detach(mountpoint: mountpoint))
    }

    /// The mirror's size used to be fixed at creation: editing it did nothing, which
    /// left a library that outgrew its 500 GB default failing with "no space" from
    /// inside the image. A larger size is now applied here, detached, before the run.
    /// Never shrinks: a smaller request is refused in the job editor.
    private func growIfSmallerThanRequested(_ bundle: URL, stdin: Data?, touched: inout Bool) throws {
        let encrypted = passphrase != nil
        let limits = ArchivePlan.resizeLimits(image: bundle, encrypted: encrypted)
        guard let r = try? runner.run(limits.tool, limits.args, stdin: stdin), r.ok,
              let current = Self.currentSectors(r.stdout) else { return }   // unknown: leave it as it is
        guard current < Self.sectors(gb: sizeGB) * 99 / 100 else { return }   // within partition overhead
        touched = true
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

/// Whether a mirror's manifest still describes its image.
///
/// A sealed archive never changes after its manifest is written. A mirror changes on
/// every run, and a run that is stopped, fails or crashes has changed it (new bands,
/// a staging copy) without finishing. The library copy inside is still the previous
/// complete one, but its structural checksum no longer matched, so restore, drills
/// and rehearsals refused it until the job next ran to completion.
///
/// So a run marks the mirror open before it touches the image, and seals it (writes
/// the manifest, clears the mark) when the image is closed again: on success, and
/// after a stop or failure that detached cleanly. A mark that remains means a run is
/// in progress or one died with the image attached. Checksum checks then say they
/// didn't check, rather than calling the mirror corrupt, and restores go on to open
/// it, which is the real test.
public enum MirrorSeal {
    static let openMarkerName = ".cryoframe-mirror-open"

    /// what a checksum check says about a mirror it couldn't compare.
    public static let uncheckedDetail =
        "the mirror is being updated, or its last update was interrupted, so its checksum wasn't compared; it is checked again after its next run"

    public static func isOpen(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(openMarkerName).path)
    }

    static func markOpen(_ dir: URL) throws {
        let owner = (ProcessIdentity.current).flatMap { try? JSONEncoder().encode($0) } ?? Data()
        try owner.write(to: dir.appendingPathComponent(openMarkerName), options: .atomic)
    }

    static func seal(_ result: ArchiveResult, in dir: URL, encrypted: Bool) throws {
        try ArchiveManifest.write(try ArchiveManifest.build(for: result, encrypted: encrypted), toDir: dir)
        clearOpen(dir)
    }

    static func clearOpen(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(openMarkerName))
    }
}
