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

/// How big the mirror's image is made.
///
/// A size used to be chosen when the job was set up (500 GB unless changed, and the
/// setup wizard never showed it), and a library that outgrew it failed with "no space"
/// from inside the image, on a drive with plenty left. A sparse image costs only what
/// is written to it (measured: 30 to 47 MB on disk whether made at 1 TB or 64 TB,
/// created in about a second), so it is now made as big as the drive it lives on and
/// grown to match if the drive turns out bigger than the image.
public enum MirrorSizing: Sendable, Equatable {
    /// the destination volume's capacity, or `unknownCapacityGB` where it doesn't say
    case fromDestination
    /// exactly this many GiB, grown to if smaller. Tests use it to keep images small.
    case fixed(gb: Int)

    /// for a destination that reports no capacity (some network shares). Large, since
    /// the size costs nothing; the free-space check before each run is what protects
    /// a destination that is actually small.
    public static let unknownCapacityGB = 16 * 1024

    /// room kept free on the drive the image lives on: 5% of it, at most 1 GiB
    public static func reserve(capacity: UInt64?) -> UInt64 {
        capacity.map { min($0 / 20, 1 << 30) } ?? (1 << 30)
    }

    /// The size to give an image, in bytes: up to `ceiling` (from `imageGB`), but never
    /// more than it already holds (`held`, its bands on the drive) plus what the drive
    /// can still back (`free` less `reserve`), and never below hdiutil's `minimum`.
    ///
    /// An image that claims more space than its drive can back is not merely at risk
    /// of a failed run. When the drive fills while the image is being written, the
    /// band writes are lost and the file system inside is damaged: measured on a
    /// 380 MB drive, rsync reported success, the swap went ahead, and the library
    /// folder then listed 9 of its 16 files; with a compact after it, the image would
    /// not mount at all. Held to what the drive can back, the image fills first, as an
    /// ordinary full disk, and the run fails cleanly with the previous copy whole.
    public static func targetBytes(ceiling: UInt64, held: UInt64, free: UInt64?, reserve: UInt64,
                                   minimum: UInt64) -> UInt64 {
        var target = ceiling
        if let free { target = min(target, held + (free > reserve ? free - reserve : 0)) }
        return max(target, minimum)
    }

    /// the image size, in GiB, for a destination of `capacity` bytes (nil: unknown)
    public func imageGB(destinationCapacity capacity: UInt64?) -> Int {
        switch self {
        case .fixed(let gb): return max(gb, 1)
        case .fromDestination:
            guard let capacity, capacity > 0 else { return Self.unknownCapacityGB }
            return max(Int(capacity >> 30), 1)
        }
    }
}

public struct SparseBundleMirrorEngine: ArchiveEngine {
    let sizing: MirrorSizing
    let bandSectors: Int          // 16384 sectors * 512 = 8 MiB bands
    let runner: CommandRunner
    let passphrase: String?       // AES-256 encryption when set
    let mountBase: URL            // where the image is attached while a run updates it (see MirrorMounts)

    public init(sizing: MirrorSizing = .fromDestination, bandSectors: Int = 16384,
                runner: CommandRunner = ProcessCommandRunner(), passphrase: String? = nil,
                mountBase: URL = MirrorMounts.defaultBase) {
        self.sizing = sizing; self.bandSectors = bandSectors; self.runner = runner; self.passphrase = passphrase
        self.mountBase = mountBase
    }

    /// a fixed-size image, as tests use
    public init(sizeGB: Int, bandSectors: Int = 16384,
                runner: CommandRunner = ProcessCommandRunner(), passphrase: String? = nil,
                mountBase: URL = MirrorMounts.defaultBase) {
        self.init(sizing: .fixed(gb: sizeGB), bandSectors: bandSectors, runner: runner,
                  passphrase: passphrase, mountBase: mountBase)
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
        //
        // A mark already there is someone else's: a run that crashed, or one still
        // writing. It stands until a run seals the image again. A run that fails before
        // it changes anything clears only a mark it made itself; clearing another's
        // put a manifest that no longer matches back in charge, and the intact copy
        // was refused as "checksum mismatch" again.
        let wasSealed = fm.fileExists(atPath: destinationDir.appendingPathComponent(ArchiveManifest.sidecarName).path)
        let markedHere = try MirrorSeal.markOpen(destinationDir)
        var touched = false
        let watch = RunWatch()
        var failure: Error?
        do {
            try update(source, in: destinationDir, bundle: bundle, stdin: stdin, touched: &touched, watch: watch)
        } catch {
            failure = error
        }
        watch.drive?.stop()

        // The drive came close to full while the image was attached: some write may
        // have been lost, which rsync can't see and the file system inside may not
        // show. The run never counts as a success then, whatever else happened.
        if touched, let drive = watch.drive, drive.dipped {
            guard MirrorMounts.mountPoints(of: bundle, runner: runner.forTeardown).isEmpty else {
                throw MirrorCopyError.driveFilledByAnother(swapped: watch.swapped)   // still attached: stays marked
            }
            switch MirrorIntegrity.check(bundle, passphrase: passphrase, runner: runner.forTeardown) {
            case .damaged(let why):
                throw MirrorCopyError.imageDamaged(why)          // stays marked; not compacted, not sealed
            case .unknown:
                throw MirrorCopyError.driveFilledByAnother(swapped: watch.swapped)   // unchecked: stays marked
            case .sound:
                compact(bundle, stdin: stdin)
                if wasSealed || watch.swapped { try? MirrorSeal.seal(result, in: destinationDir, encrypted: encrypted) }
                throw MirrorCopyError.driveFilledByAnother(swapped: watch.swapped)
            }
        }

        if let error = failure {
            if !touched {
                if markedHere { MirrorSeal.clearOpen(destinationDir) }   // never changed: the manifest still holds
            } else if MirrorMounts.mountPoints(of: bundle, runner: runner.forTeardown).isEmpty {
                compact(bundle, stdin: stdin)
                // Stopped or failed, but closed: the copy inside is the previous complete
                // one (MirrorCopy only swaps after rsync succeeds), so the manifest can
                // describe the image as it now is.
                if wasSealed { try? MirrorSeal.seal(result, in: destinationDir, encrypted: encrypted) }
            }
            throw error
        }
        compact(bundle, stdin: stdin)
        try MirrorSeal.seal(result, in: destinationDir, encrypted: encrypted)
        return result
    }

    /// Give the drive back the bands the image no longer uses.
    ///
    /// A sparse image never returns a band by itself (measured: 30 bands after writing
    /// and deleting 200 MB, 30 before). Updating beside the previous copy frees that
    /// copy's changed blocks inside the image on every run, so without this the image
    /// only ever grew, and on a nearly full drive it held the space the next run
    /// needed: after one run filled the drive, every later one failed "No space left
    /// on device" even once the library had shrunk. Measured on that drive: 197 MB
    /// reclaimed in half a second. Best effort; a run doesn't fail over it.
    ///
    /// Compacting removes bands the last seal recorded, so the band list is withdrawn
    /// from the manifest first (the mirror is marked open by then, so nothing else in
    /// the manifest is being relied on). A run that dies between the compact and the
    /// seal then leaves a mark over a manifest with no band list, which checks as
    /// "not compared", rather than a list naming bands compact rightly removed, which
    /// read as damage and refused the restore of a healthy mirror.
    private func compact(_ bundle: URL, stdin: Data?) {
        MirrorSeal.withdrawBands(in: bundle.deletingLastPathComponent())
        var args = ["compact", bundle.path]
        if passphrase != nil { args.append("-stdinpass") }
        _ = try? runner.forTeardown.run("/usr/bin/hdiutil", args, stdin: stdin)
    }

    /// create or grow the image, attach it, bring the library copy up to date, detach.
    private func update(_ source: ArchiveSource, in destinationDir: URL, bundle: URL, stdin: Data?,
                        touched: inout Bool, watch: RunWatch) throws {
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
        // open elsewhere (a restore, a check, another run): say so now, before growing
        // it or attaching it, rather than fail on hdiutil's "Resource busy" later
        if fm.fileExists(atPath: bundle.path) {
            try MirrorMounts.refuseIfOpen(bundle, runner: teardown)
            // Attached with nothing mounted (a failed attach, or a volume unmounted
            // without ejecting the image): nobody has it open, but the attach below
            // reused that device, read-only if it was, and failed "volume is read
            // only" every run. Nothing mounted on it means nobody is using it.
            ArchiveReader.detachOrphans(ofImage: bundle, runner: teardown)
        }

        // `touched` is set at each step that changes the image, so a run that fails
        // before any of them leaves the manifest standing
        // one mirror run per drive at a time (see MirrorWriteGuard); after the in-use
        // check, so a second run of this same image fails at once rather than waits
        let volumeLock = try VolumeLock.acquire(for: destinationDir, in: mountBase, control: runner.control)
        defer { volumeLock?.release() }

        let capacity = StorageReporter.volume(of: destinationDir).total
        let ceiling = Self.sectors(gb: sizing.imageGB(destinationCapacity: capacity)) * 512
        // what is free now, not what could be purged later (see JobExecutor.freeNow)
        let free = JobExecutor.freeNow(for: destinationDir)
        let reserve = MirrorSizing.reserve(capacity: capacity)
        var imageBytes: UInt64
        if !fm.fileExists(atPath: bundle.path) {
            if let needs = source.sizeHint {     // before making anything
                try Self.checkRoom(for: needs, image: bundle, imageBytes: .max, destination: destinationDir)
            }
            imageBytes = MirrorSizing.targetBytes(ceiling: ceiling, held: 0, free: free, reserve: reserve, minimum: 0)
            touched = true
            try execute(ArchivePlan.sparseBundleCreate(output: bundle, name: source.name, sizeGB: 0,
                                                       bandSectors: bandSectors, encrypted: encrypted,
                                                       sectors: max(imageBytes / 512, 1)), stdin: stdin)
        } else {
            imageBytes = try fit(bundle, ceiling: ceiling, free: free, reserve: reserve, stdin: stdin,
                                 touched: &touched) ?? ceiling
        }
        if let needs = source.sizeHint {
            try Self.checkRoom(for: needs, image: bundle, imageBytes: imageBytes, destination: destinationDir)
        }

        // watch the drive for as long as the image is attached (see MirrorWriteGuard)
        let drive = DriveWatch(watching: destinationDir, floor: reserve / 4 * 3)
        drive.start()
        watch.drive = drive

        let work = try MirrorMounts.makeWork(in: mountBase)
        let mountpoint = work.appendingPathComponent("mnt", isDirectory: true)
        defer {
            MountPoint.detach(mountpoint, runner: teardown)
            OpenedArchive.removeWork(work)          // only once nothing is mounted there
        }
        // attach read-write at `mountpoint`; also used to attach it again for the read-back
        func attach() throws {
            try fm.createDirectory(at: mountpoint, withIntermediateDirectories: true)
            do {
                try DiskImageGate.serialized { try execute(ArchivePlan.attach(image: bundle, mountpoint: mountpoint, encrypted: encrypted), stdin: stdin) }
            } catch {
                try MirrorMounts.refuseIfOpen(bundle, except: mountpoint, runner: teardown)   // opened elsewhere meanwhile
                throw error
            }
            // An image already attached elsewhere fails to attach again ("Resource busy")
            // on current macOS; older versions have answered 0 and mounted nothing, and
            // then rsync would write onto the startup disk instead of into the image.
            // Refuse rather than detach someone else's open copy.
            guard MountPoint.isMounted(mountpoint) else {
                throw DiskImageInUse(image: bundle.path, mountedAt: MirrorMounts.mountPoints(of: bundle, runner: teardown))
            }
        }
        try attach()
        touched = true          // attached read-write: the image changes from here

        // rsync into a clone of the previous copy, so the copy restore reads is never
        // half-updated; then prove the new copy reached the drive before swapping it in
        let staged = try MirrorCopy.stage(volume: mountpoint, name: source.root.lastPathComponent, source: source.root,
                                          runner: runner, execute: { try execute($0) })
        do {
            // on the drive, and the drive never came close to full while it was written
            MirrorCopy.flush(volume: mountpoint)
            drive.sample()
            if drive.dipped { throw MirrorCopyError.driveFilledByAnother(swapped: false) }
            // read it back from the drive, not from memory: detach and attach again
            MountPoint.detach(mountpoint, runner: teardown)
            guard !MountPoint.isMounted(mountpoint) else { throw MountPointError.stillMounted(mountpoint.path) }
            try attach()
            try MirrorCopy.verify(staged, against: source.root, control: runner.control)
            drive.sample()
            if drive.dipped { throw MirrorCopyError.driveFilledByAnother(swapped: false) }
        } catch {
            MirrorCopy.abandon(staged, runner: runner)
            throw error
        }
        try MirrorCopy.commit(staged, runner: runner)
        watch.swapped = true
        // The new copy is in place. A detach that comes back busy (Spotlight or
        // fseventsd still looking) used to fail the run here while the mirror already
        // held the new library, so the history and the restore disagreed. Flush, then
        // detach patiently and by force if need be; only a volume that still won't go
        // fails the run.
        MirrorCopy.flush(volume: mountpoint)
        MountPoint.detach(mountpoint, runner: teardown)
        guard !MountPoint.isMounted(mountpoint) else { throw MountPointError.stillMounted(mountpoint.path) }
    }

    /// Size the image to `MirrorSizing.targetBytes`: grow one made at an older fixed
    /// size or on a drive since replaced by a bigger one, and shrink one that claims
    /// more than its drive can now back. Returns the size afterwards, or nil if hdiutil
    /// wouldn't say.
    private func fit(_ bundle: URL, ceiling: UInt64, free: UInt64?, reserve: UInt64, stdin: Data?,
                     touched: inout Bool) throws -> UInt64? {
        let encrypted = passphrase != nil
        let limits = ArchivePlan.resizeLimits(image: bundle, encrypted: encrypted)
        guard let r = try? runner.run(limits.tool, limits.args, stdin: stdin), r.ok,
              let current = Self.currentSectors(r.stdout) else { return nil }   // unknown: leave it as it is
        let minimum = (Self.minimumSectors(r.stdout) ?? 0) * 512
        let target = MirrorSizing.targetBytes(ceiling: ceiling, held: Checksum.byteSize(of: bundle),
                                              free: free, reserve: reserve, minimum: minimum)
        let now = current * 512
        // within 1% (partition overhead, the drive's free space moving a little): leave it
        guard now > target + target / 100 || now + now / 100 < target else { return now }
        touched = true
        do {
            try execute(ArchivePlan.resize(image: bundle, sizeGB: 0, encrypted: encrypted, sectors: target / 512), stdin: stdin)
        } catch ArchiveError.toolFailed(_, _, let stderr) {
            throw MirrorSpaceError.couldNotResize(stderr.split(separator: "\n").last.map(String.init) ?? "")
        }
        return target
    }

    /// Refuse a run that can't fit, before the image is even attached, rather than let
    /// the drive fill part-way through rsync.
    ///
    /// What the drive has to supply is the library less what the image's bands already
    /// hold, plus a small margin (5%, at most 1 GiB: a percentage of a 2 TB library
    /// would refuse runs on a nearly full drive that has room for them). The bands are
    /// measured on the drive, not inside the image: inside a sparse image the kernel
    /// caps both free and total figures by the drive's free space, so "used" read from
    /// there is meaningless (measured: 543 MB "used" in a mirror holding 20 KB).
    /// Files changed in place need room too and can't be known ahead; running out for
    /// those fails the run with the previous copy intact. An unknown free-space figure
    /// (some network shares) is not read as "full".
    static func checkRoom(for needs: UInt64, image: URL, imageBytes: UInt64, destination: URL) throws {
        let margin = min(needs / 20, 1 << 30)
        let held = Checksum.byteSize(of: image)
        let fromDrive = (needs > held ? needs - held : 0) + margin
        if let free = JobExecutor.freeSpace(for: destination), free < fromDrive {
            throw MirrorSpaceError.notEnoughRoom(needed: fromDrive, free: free)
        }
        // a fixed-size image too small to hold the library at all
        if imageBytes < needs + margin {
            throw MirrorSpaceError.imageTooSmall(size: imageBytes, needed: needs + margin)
        }
    }

    /// `hdiutil resize -limits` prints "min current max" in 512-byte sectors.
    static func currentSectors(_ limits: String) -> UInt64? {
        let f = limits.split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" })
        return f.count >= 3 ? UInt64(f[1]) : nil
    }

    static func minimumSectors(_ limits: String) -> UInt64? {
        let f = limits.split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" })
        return f.count >= 3 ? UInt64(f[0]) : nil
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

public enum MirrorSpaceError: Error, Equatable {
    case notEnoughRoom(needed: UInt64, free: UInt64)
    case imageTooSmall(size: UInt64, needed: UInt64)
    case couldNotResize(String)
}

extension MirrorSpaceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notEnoughRoom(let needed, let free):
            return "not enough space for the mirror: this run needs about \(JobExecutor.human(needed)) more and only \(JobExecutor.human(free)) is free. Nothing was changed; free up space or choose a bigger destination."
        case .imageTooSmall(let size, let needed):
            return "the mirror's disk image holds \(JobExecutor.human(size)) and the library needs about \(JobExecutor.human(needed)). Nothing was changed."
        case .couldNotResize(let why):
            return "couldn't resize the mirror's disk image to fit the room on its drive (\(why.isEmpty ? "hdiutil gave no reason" : why)). The mirror is unchanged; run again."
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

    /// mark the mirror open. Returns false when it already was: another run's mark,
    /// which this run must leave in place unless it seals the image itself.
    @discardableResult
    static func markOpen(_ dir: URL) throws -> Bool {
        let path = dir.appendingPathComponent(openMarkerName).path
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        if fd < 0 {
            if errno == EEXIST { return false }
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path,
                                                          NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)])
        }
        defer { close(fd) }
        if let owner = ProcessIdentity.current.flatMap({ try? JSONEncoder().encode($0) }) {
            _ = owner.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        }
        return true
    }

    static func seal(_ result: ArchiveResult, in dir: URL, encrypted: Bool) throws {
        var manifest = try ArchiveManifest.build(for: result, encrypted: encrypted)
        manifest.sealedBands = result.artifacts.first.map { bandRanges(bands(of: $0)) }
        try ArchiveManifest.write(manifest, toDir: dir)
        clearOpen(dir)
    }

    // MARK: the bands a sealed mirror had
    //
    // While a mark stands the structural checksum can't be compared: the image has
    // changed since. The previous copy is still inside it, but with nothing compared
    // at all, a mirror that had lost a band (a failing drive) restored "successfully"
    // with zeros where the band's data had been. A sparse image never deletes a band
    // by itself (measured: freeing 200 MB inside left all 30 bands), and a run only
    // adds them, so every band the image had when it was sealed must still be there.
    // Content isn't compared; a missing band is caught.

    /// the band numbers present in a sparsebundle
    static func bands(of bundle: URL) -> [Int] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: bundle.appendingPathComponent("bands").path)) ?? []
        return names.compactMap { Int($0, radix: 16) }.sorted()
    }

    /// sorted band numbers as hex ranges: [0, 1, 2, 5] → "0-2,5"
    static func bandRanges(_ bands: [Int]) -> String {
        var parts: [String] = []
        var i = 0
        while i < bands.count {
            var j = i
            while j + 1 < bands.count, bands[j + 1] == bands[j] + 1 { j += 1 }
            let a = String(bands[i], radix: 16), b = String(bands[j], radix: 16)
            parts.append(i == j ? a : "\(a)-\(b)")
            i = j + 1
        }
        return parts.joined(separator: ",")
    }

    /// bands recorded in `ranges` that `bundle` no longer has
    static func missingBands(_ ranges: String, in bundle: URL) -> [Int] {
        let present = Set(bands(of: bundle))
        var missing: [Int] = []
        for part in ranges.split(separator: ",") {
            let ends = part.split(separator: "-").compactMap { Int($0, radix: 16) }
            guard let lo = ends.first, let hi = ends.last, lo <= hi else { continue }
            for n in lo...hi where !present.contains(n) { missing.append(n) }
        }
        return missing
    }

    /// drop the band list from the manifest in `dir`, if there is one to drop
    static func withdrawBands(in dir: URL) {
        let url = dir.appendingPathComponent(ArchiveManifest.sidecarName)
        guard var manifest = try? ArchiveManifest.read(url), manifest.sealedBands != nil else { return }
        manifest.sealedBands = nil
        _ = try? ArchiveManifest.write(manifest, toDir: dir)
    }

    static func clearOpen(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(openMarkerName))
    }
}
