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
    /// `shared`: the mirror has history, whose clones share the image's blocks. Then
    /// writing over a block takes new room on the drive too, so what the drive must back
    /// is what the image holds inside (`minimum`, which follows it: measured, 72 MB in
    /// use, 204 MB of bands), not its bands, which can be far more after a run freed
    /// space inside. Capped by the bands, the image could take more than the drive had.
    ///
    /// An image that claims more space than its drive can back is not merely at risk
    /// of a failed run. When the drive fills while the image is being written, the
    /// band writes are lost and the file system inside is damaged: measured on a
    /// 380 MB drive, rsync reported success, the swap went ahead, and the library
    /// folder then listed 9 of its 16 files; with a compact after it, the image would
    /// not mount at all. Held to what the drive can back, the image fills first, as an
    /// ordinary full disk, and the run fails cleanly with the previous copy whole.
    public static func targetBytes(ceiling: UInt64, held: UInt64, free: UInt64?, reserve: UInt64,
                                   minimum: UInt64, shared: Bool = false) -> UInt64 {
        var target = ceiling
        let backed = shared ? min(held, minimum) : held
        if let free { target = min(target, backed + (free > reserve ? free - reserve : 0)) }
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
    /// the check for decay made once the image is sealed (see BandCheck); nil: none
    let bandCheck: BandCheck.Settings?
    /// the nights of history to keep, saved once the image is sealed (see
    /// MirrorHistory); nil: none saved, and none removed but to make room
    let history: Int?

    public init(sizing: MirrorSizing = .fromDestination, bandSectors: Int = 16384,
                runner: CommandRunner = ProcessCommandRunner(), passphrase: String? = nil,
                mountBase: URL = MirrorMounts.defaultBase, bandCheck: BandCheck.Settings? = nil,
                history: Int? = nil) {
        self.sizing = sizing; self.bandSectors = bandSectors; self.runner = runner; self.passphrase = passphrase
        self.mountBase = mountBase; self.bandCheck = bandCheck; self.history = history
    }

    /// a fixed-size image, as tests use
    public init(sizeGB: Int, bandSectors: Int = 16384,
                runner: CommandRunner = ProcessCommandRunner(), passphrase: String? = nil,
                mountBase: URL = MirrorMounts.defaultBase, bandCheck: BandCheck.Settings? = nil,
                history: Int? = nil) {
        self.init(sizing: .fixed(gb: sizeGB), bandSectors: bandSectors, runner: runner,
                  passphrase: passphrase, mountBase: mountBase, bandCheck: bandCheck, history: history)
    }

    public func archive(_ source: ArchiveSource, to destinationDir: URL) throws -> ArchiveResult {
        let watch = RunWatch()
        do {
            return try archive(source, to: destinationDir, watch: watch)
        } catch {
            // History removed to make room is gone whatever the run came to, so a run
            // that then failed says so too, on its record (see JobExecutor.direct)
            if let note = MirrorHistory.roomNote(watch.historyRemoved) { runner.control?.record(note: note) }
            throw error
        }
    }

    private func archive(_ source: ArchiveSource, to destinationDir: URL, watch: RunWatch) throws -> ArchiveResult {
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
        // each step after the copy says how far it has got (see RunStep); none outlives the run
        runner.control?.endStep()
        defer { runner.control?.endStep() }

        // "Start this mirror over", asked for a damaged mirror: its image is put aside
        // and this run makes a new one (see MirrorSeal.startOverIfAsked)
        try MirrorSeal.startOverIfAsked(bundle, in: destinationDir, runner: runner.forTeardown)
        // an entry of the mirror's history a run died making (see MirrorHistory.save)
        MirrorHistory.sweepPartials(in: destinationDir)

        // An image found damaged after an earlier run may not even mount. Unless a
        // check now finds it sound (someone repaired it), say so plainly rather than
        // fail on whatever hdiutil makes of it. Decay is never cleared that way: the
        // file system inside can check out with a band's data changed under it.
        if let why = MirrorSeal.damage(in: destinationDir), fm.fileExists(atPath: bundle.path) {
            if MirrorSeal.isDecayed(destinationDir) {
                throw MirrorCopyError.imageDecayed(image: bundle.path, why: why)
            }
            // (damage(in:) reads decay too, so a damaged marker 1.7 cleared doesn't let one by)
            if MirrorMounts.mountPoints(of: bundle, runner: runner.forTeardown).isEmpty,
               MirrorIntegrity.check(bundle, passphrase: passphrase, runner: runner.forTeardown, control: runner.control) == .sound {
                MirrorSeal.clearDamaged(destinationDir)
            } else {
                if runner.control?.isCancelled == true { throw CancelledError() }
                throw MirrorCopyError.imageRecordedDamaged(image: bundle.path, why: why)
            }
        }

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
        var failure: Error?
        do {
            try update(source, in: destinationDir, bundle: bundle, stdin: stdin, touched: &touched, watch: watch)
        } catch {
            failure = error
        }
        watch.drive?.stop()
        // with history sharing the image's blocks, the run's own writes take room too:
        // another writer isn't the only way the drive fills, so the run doesn't say it is
        let shared = fm.fileExists(atPath: bundle.path) && !MirrorHistory.entries(in: destinationDir).isEmpty
        func dipped(_ swapped: Bool) -> MirrorCopyError {
            shared ? .driveFilledBesideHistory(swapped: swapped) : .driveFilledByAnother(swapped: swapped)
        }

        // The drive came close to full while the image was attached: some write may
        // have been lost, which rsync can't see and the file system inside may not
        // show. The run never counts as a success then, whatever else happened.
        if touched, let drive = watch.drive, drive.dipped {
            guard MirrorMounts.mountPoints(of: bundle, runner: runner.forTeardown).isEmpty else {
                throw dipped(watch.swapped)   // still attached: stays marked
            }
            switch MirrorIntegrity.check(bundle, passphrase: passphrase, runner: runner.forTeardown, control: runner.control) {
            case .damaged(let why):
                MirrorSeal.markDamaged(destinationDir, why: why)  // so restore, health and the next run say so
                throw MirrorCopyError.imageDamaged(why)          // stays marked; not compacted, not sealed
            case .unknown:
                throw dipped(watch.swapped)   // unchecked: stays marked
            case .sound:
                compact(bundle, stdin: stdin)
                if wasSealed || watch.swapped { try? MirrorSeal.seal(result, in: destinationDir, encrypted: encrypted) }
                throw dipped(watch.swapped)
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
            if shared, case MirrorCopyError.driveFilled = error { throw MirrorCopyError.imageFilledBesideHistory }
            throw error
        }
        compact(bundle, stdin: stdin)
        do {
            try confirm(bundle, name: source.root.lastPathComponent, against: source.root, in: destinationDir, stdin: stdin,
                        excluded: Set(source.excluded))
        } catch MirrorCopyError.updateNotConfirmed(let count, let examples) {
            // sound, and holding a complete copy that isn't the new one
            try? MirrorSeal.seal(result, in: destinationDir, encrypted: encrypted)
            throw MirrorCopyError.updateNotConfirmed(count: count, examples: examples)
        } catch MirrorCopyError.topFolderNotRestored(let why) {
            // sound, and holding the new copy, bar its top folder's attributes
            try? MirrorSeal.seal(result, in: destinationDir, encrypted: encrypted)
            throw MirrorCopyError.topFolderNotRestored(why)
        }
        try MirrorSeal.seal(result, in: destinationDir, encrypted: encrypted)
        MirrorSeal.removeReplaced(bundle)       // a mirror started over is complete again
        var sealed = result
        sealed.notes = watch.historyRemoved.isEmpty ? [] : [MirrorHistory.roomNote(watch.historyRemoved)].compactMap { $0 }
        if let bandCheck {
            sealed.bandCheck = checkBands(bundle, in: destinationDir, name: source.name, settings: bandCheck)
        }
        // decay found isn't kept as history: the mirror can't be trusted
        if let nights = history, (sealed.bandCheck?.mismatches ?? 0) == 0 {
            sealed.notes += saveHistory(bundle, in: destinationDir, written: watch.written, library: source.sizeHint, nights: nights)
        }
        return sealed
    }

    /// Keep the sealed image as the newest entry of its history, then remove what the
    /// job no longer keeps (see MirrorHistory). Holding the image's lock, with nothing
    /// of it attached, so no attach changes it while it is cloned. A run whose history
    /// couldn't be saved still backed up: it says so, and doesn't fail.
    /// `library`: its size, which the entry keeps (see MirrorHistory.writeEstimate).
    private func saveHistory(_ bundle: URL, in dir: URL, written: UInt64, library: UInt64?, nights: Int) -> [String] {
        runner.control?.begin("Saving the mirror's history", stage: .finishing)
        guard let lock = ImageLock.acquire(bundle, wait: ImageLock.patience, control: runner.control) else {
            return ["the mirror's history wasn't saved this run: its disk image was in use"]
        }
        defer { lock.release() }
        let attached = MirrorMounts.attachedImagesIfKnown(runner: runner.forTeardown)
        let target = bundle.resolvingSymlinksInPath().path
        guard let attached, !attached.contains(where: { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == target }) else {
            return ["the mirror's history wasn't saved this run: its disk image was open elsewhere on this Mac, or that couldn't be told"]
        }
        do {
            try MirrorHistory.save(bundle: bundle, in: dir, written: written, library: library, at: Date())
        } catch {
            return ["the mirror's history wasn't saved this run (\(error.localizedDescription))"]
        }
        return MirrorHistory.prune(in: dir, nights: nights)
    }

    /// Check the sealed image's bands for decay (see BandCheck). Decay found marks the
    /// mirror damaged, so the health check, Restore and the next run all say so.
    private func checkBands(_ bundle: URL, in dir: URL, name: String, settings: BandCheck.Settings) -> BandCheckReport {
        var report = BandCheck.run(bundle: bundle, in: dir, library: name, settings: settings, control: runner.control)
        if report.mismatches > 0 {
            MirrorSeal.markDamaged(dir, why: MirrorSeal.decayReason(report.damaged))
            MirrorSeal.markDecayed(dir, bands: report.damaged)
            let entries = MirrorHistory.entries(in: dir).count
            if entries > 0 { report.history = entries }     // they share the decayed blocks
        }
        return report
    }

    /// After the swap, prove what reached the drive: the image's file system is sound
    /// (fsck_apfs, 0.26 s for 30,000 files) and its library copy is the new one (by
    /// structure, read-only; the data was read back before the swap). The swap, the
    /// removal of the previous copy and the final flush are written after that
    /// read-back, and a drive that runs out of room for an instant while they are would
    /// otherwise go unseen: a damaged directory, or a swap that never landed, with the
    /// run reported a success.
    private func confirm(_ bundle: URL, name: String, against source: URL, in destinationDir: URL, stdin: Data?,
                         excluded: Set<String> = []) throws {
        let teardown = runner.forTeardown
        runner.control?.begin("Checking the disk image", stage: .verifying)
        // Stop ends a wait for the image (see ImageLock.attaching), which the teardown
        // runner, with no control of its own, can't
        switch MirrorIntegrity.check(bundle, passphrase: passphrase, runner: teardown, control: runner.control,
                                     settle: ImageLock.settling) {
        case .damaged(let why):
            MirrorSeal.markDamaged(destinationDir, why: why)
            throw MirrorCopyError.imageDamaged(why)             // stays marked; not sealed
        case .unknown(let why):
            if runner.control?.isCancelled == true { throw CancelledError() }
            throw MirrorCopyError.couldNotConfirm(why)          // stays marked; not sealed
        case .sound:
            break
        }
        let work = try MirrorMounts.makeWork(in: mountBase)
        let mnt = work.appendingPathComponent("mnt", isDirectory: true)
        defer {
            MountPoint.detach(mnt, runner: teardown)        // a failed attach's devices went as it failed
            OpenedArchive.removeWork(work)
        }
        try FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)
        try ImageLock.attaching(bundle, runner: teardown, control: runner.control, settle: ImageLock.settling) { before in
            // attached elsewhere: an attach would hand back that disk, not read the drive
            guard before.isEmpty else { throw MirrorCopyError.couldNotConfirm("it is attached elsewhere on this Mac") }
            let attached = try? AttachRecords.recording(bundle, sparing: before, mountedAt: mnt, runner: teardown) {
                try DiskImageGate.serialized {
                    try runner.runRetryingBusy(DiskImageTool.attach(image: bundle, mountpoint: mnt, readonly: true,
                                                                    encrypted: passphrase != nil),
                                               stdin: stdin)
                }
            }
            guard attached?.ok == true, MountPoint.isMounted(mnt) else {
                if runner.control?.isCancelled == true { throw CancelledError() }      // detached below
                throw MirrorCopyError.couldNotConfirm(attached.map { ProcessCommandRunner.meaningful($0.stderr) } ?? "it wouldn't attach")
            }
        }
        let found = try MirrorCopy.structure(of: mnt.appendingPathComponent(name), against: source, previous: nil,
                                             control: runner.control, title: "Confirming the update", excluded: excluded)
        guard found.count == 0 else { throw MirrorCopyError.updateNotConfirmed(count: found.count, examples: found.examples) }
        // The swap lifts and restores the top folder's access list after the read-back
        // (see MirrorCopy.putInPlace), so it is the one thing written unverified.
        if let why = MirrorCopy.differentAttributes(source.path, mnt.appendingPathComponent(name).path) {
            throw MirrorCopyError.topFolderNotRestored(why)
        }
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
        runner.control?.begin("Compacting the disk image", stage: .finishing)
        MirrorSeal.withdrawBands(in: bundle.deletingLastPathComponent())
        _ = try? runner.forTeardown.run(DiskImageTool.compact(image: bundle, encrypted: passphrase != nil), stdin: stdin)
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
            // attached with nothing mounted by another program, and no attach of
            // Cryoframe's under way: refused now, before growing it (see attach below)
            if let lock = ImageLock.acquire(bundle) {
                defer { lock.release() }
                // one a crashed run or check of Cryoframe's left goes first (see AttachRecords)
                AttachRecords.releaseLeftovers(of: bundle, runner: teardown, holding: lock)
                // one that ends by itself is waited out, never detached (see ImageLock.settled)
                let held = try ImageLock.settled(bundle, runner: teardown, within: ImageLock.settling,
                                                 control: runner.control, holding: lock) ?? []
                if !held.isEmpty { throw DiskImageInUse(image: bundle.path, mountedAt: [], attachedWithoutMount: true) }
            }
        }

        // `touched` is set at each step that changes the image, so a run that fails
        // before any of them leaves the manifest standing
        // one mirror run per drive at a time (see MirrorWriteGuard); after the in-use
        // check, so a second run of this same image fails at once rather than waits
        let volumeLock = try VolumeLock.acquire(for: destinationDir, in: mountBase, control: runner.control)
        defer { volumeLock?.release() }

        let capacity = StorageReporter.volume(of: destinationDir).total
        let ceiling = Self.sectors(gb: sizing.imageGB(destinationCapacity: capacity)) * 512
        let reserve = MirrorSizing.reserve(capacity: capacity)
        // before making, growing or shrinking anything; the mirror's history goes,
        // oldest first, before the mirror is refused room
        if let needs = source.sizeHint {
            try makingRoom(in: destinationDir, bundle: bundle, library: needs, watch: watch) { writes, freed in
                try Self.checkRoom(for: needs, image: bundle, imageBytes: .max, destination: destinationDir, reserve: reserve,
                                   writes: writes, freed: freed)
            }
        }
        // what is free now, not what could be purged later (see JobExecutor.freeNow)
        let free = JobExecutor.freeNow(for: destinationDir)
        var imageBytes: UInt64
        if !fm.fileExists(atPath: bundle.path) {
            imageBytes = MirrorSizing.targetBytes(ceiling: ceiling, held: 0, free: free, reserve: reserve, minimum: 0)
            try DiskImageTool.refuseExisting(bundle)        // a link to nothing isn't "no image"
            touched = true
            try execute(DiskImageTool.sparseBundle(output: bundle, name: source.name, sizeGB: 0,
                                                   bandSectors: bandSectors, encrypted: encrypted,
                                                   sectors: max(imageBytes / 512, 1)), stdin: stdin)
        } else {
            let shared = !MirrorHistory.entries(in: destinationDir).isEmpty
            imageBytes = try fit(bundle, ceiling: ceiling, free: free, reserve: reserve, shared: shared, stdin: stdin,
                                 touched: &touched) ?? ceiling
        }
        if let needs = source.sizeHint {
            try makingRoom(in: destinationDir, bundle: bundle, library: needs, watch: watch) { writes, freed in
                try Self.checkRoom(for: needs, image: bundle, imageBytes: imageBytes, destination: destinationDir, reserve: reserve,
                                   writes: writes, freed: freed)
            }
        }

        // watch the drive for as long as the image is attached (see MirrorWriteGuard)
        let drive = DriveWatch(watching: destinationDir, floor: reserve / 4 * 3)
        drive.start()
        watch.drive = drive

        let work = try MirrorMounts.makeWork(in: mountBase)
        let mountpoint = work.appendingPathComponent("mnt", isDirectory: true)
        defer {
            MountPoint.detach(mountpoint, runner: teardown)     // a failed attach's devices went as it failed
            OpenedArchive.removeWork(work)          // only once nothing is mounted there
        }
        // attach read-write at `mountpoint`; also used to attach it again for the read-back
        func attach() throws {
            try fm.createDirectory(at: mountpoint, withIntermediateDirectories: true)
            try ImageLock.attaching(bundle, runner: runner, settle: ImageLock.settling) { before in
                // Attached with nothing mounted (Disk Utility's First Aid, a command in
                // Terminal, a volume unmounted without ejecting the image): the attach
                // reused that device, read-only if it was, and failed "volume is read
                // only" every run, or failed busy. It was detached before this attach,
                // which pulled the disk out from under whoever held it; now the run is
                // refused, and says how to let it go. (One a crashed process of
                // Cryoframe's left was detached as the lock was taken: see AttachRecords.)
                guard before.isEmpty else {
                    let open = MirrorMounts.mountPoints(of: bundle, runner: teardown)
                    throw DiskImageInUse(image: bundle.path, mountedAt: open, attachedWithoutMount: open.isEmpty)
                }
                do {
                    try AttachRecords.recording(bundle, sparing: before, mountedAt: mountpoint, runner: teardown) {
                        try DiskImageGate.serialized { try execute(DiskImageTool.attach(image: bundle, mountpoint: mountpoint, encrypted: encrypted), stdin: stdin) }
                    }
                } catch let stop as CancelledError {
                    // Stop let the attach finish (see ProcessCommandRunner.letsFinish);
                    // mounted read-write, the image has changed, and is detached below
                    if MountPoint.isMounted(mountpoint) { touched = true }
                    throw stop
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
        }
        try attach()
        touched = true          // attached read-write: the image changes from here

        // rsync into a clone of the previous copy, so the copy restore reads is never
        // half-updated; then prove the new copy reached the drive before swapping it in
        let staged = try MirrorCopy.stage(volume: mountpoint, name: source.root.lastPathComponent, source: source.root,
                                          runner: runner, excluded: source.excluded, execute: { try execute($0) })
        do {
            // on the drive, and the drive never came close to full while it was written
            runner.control?.begin("Writing the copy to the drive", stage: .finishing)
            MirrorCopy.flush(volume: mountpoint)
            drive.sample()
            if drive.dipped { throw MirrorCopyError.driveFilledByAnother(swapped: false) }
            // read it back from the drive, not from memory: detach and attach again
            MountPoint.detach(mountpoint, runner: teardown)
            guard !MountPoint.isMounted(mountpoint) else { throw MountPointError.stillMounted(mountpoint.path) }
            try attach()
            watch.written = try MirrorCopy.verify(staged, against: source.root, control: runner.control, excluded: Set(source.excluded))
            drive.sample()
            if drive.dipped { throw MirrorCopyError.driveFilledByAnother(swapped: false) }
            // what the library no longer holds is kept in the image before the previous
            // copy goes (see RemovedItems.keep): a clone of each, which costs no room
            if source.keepsRemoved {
                try RemovedItems.keep(RemovedItems.missing(from: staged.next, in: staged.current, control: runner.control),
                                      from: staged.current, in: mountpoint, now: Date(), runner: runner)
            }
        } catch let stop as CancelledError {
            // Stopped: the unfinished copy stays in staging, where the next run removes
            // it before it starts. Removing it now is as many deletes as the library has
            // items, and kept a stopped run going long after Stop (measured: 33 s for
            // 120,000 items on an exFAT drive; a slow card takes longer).
            throw stop
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
        runner.control?.begin("Writing the copy to the drive", stage: .finishing)
        MirrorCopy.flush(volume: mountpoint)
        MountPoint.detach(mountpoint, runner: teardown)
        guard !MountPoint.isMounted(mountpoint) else { throw MountPointError.stillMounted(mountpoint.path) }
    }

    /// `check`, a room check, run again after each entry of the mirror's history is
    /// removed, oldest first, while it finds the drive short of room (see
    /// MirrorHistory.makeRoom). The mirror always comes before its history, but none
    /// goes unless the run would fit with all of it gone; what went is recorded in
    /// `watch` for the run to say. Out of history, the refusal stands.
    ///
    /// `check` is given about what the run will write into the image, of a library of
    /// `library` bytes, when history shares its blocks (nil: nothing shares the image of
    /// `bundle`), and room to count as already freed.
    private func makingRoom(in dir: URL, bundle: URL, library: UInt64, watch: RunWatch,
                            _ check: (_ writes: UInt64?, _ freed: UInt64) throws -> Void) throws {
        func writes() -> UInt64? {
            guard FileManager.default.fileExists(atPath: bundle.path) else { return nil }
            return MirrorHistory.writeEstimate(MirrorHistory.entries(in: dir), library: library)
        }
        func fits(_ writes: UInt64?, _ freed: UInt64) -> Bool {
            do { try check(writes, freed); return true }
            catch let e as MirrorSpaceError where e.isShortOfRoom { return false }
            catch { return true }       // not a lack of room: the check below says what
        }
        let entries = MirrorHistory.entries(in: dir)
        let gone = MirrorHistory.makeRoom(entries, fits: { fits(writes(), 0) },
                                          fitsWithAllGone: { fits(nil, MirrorHistory.roomFreed(byRemoving: entries)) },
                                          remove: { e in (try? MirrorHistory.remove(e, in: dir)) != nil })
        watch.historyRemoved += gone
        try check(writes(), 0)          // the verdict, after whatever went
    }

    /// Size the image to `MirrorSizing.targetBytes`: grow one made at an older fixed
    /// size or on a drive since replaced by a bigger one, and shrink one that claims
    /// more than its drive can now back. Returns the size afterwards, or nil if hdiutil
    /// wouldn't say.
    private func fit(_ bundle: URL, ceiling: UInt64, free: UInt64?, reserve: UInt64, shared: Bool, stdin: Data?,
                     touched: inout Bool) throws -> UInt64? {
        let encrypted = passphrase != nil
        guard let limits = DiskImageTool.limits(of: bundle, encrypted: encrypted, stdin: stdin,
                                                runner: runner) else { return nil }   // unknown: leave it as it is
        let minimum = limits.minimum
        let target = MirrorSizing.targetBytes(ceiling: ceiling, held: Checksum.byteSize(of: bundle),
                                              free: free, reserve: reserve, minimum: minimum, shared: shared)
        let now = limits.current
        // within 1% (partition overhead, the drive's free space moving a little): leave it
        guard now > target + target / 100 || now + now / 100 < target else { return now }
        touched = true
        do {
            try execute(DiskImageTool.resize(image: bundle, sectors: target / 512, encrypted: encrypted), stdin: stdin)
        } catch ArchiveError.toolFailed(_, _, let stderr) {
            throw MirrorSpaceError.couldNotResize(ProcessCommandRunner.meaningful(stderr).split(separator: "\n").last.map(String.init) ?? "")
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
    ///
    /// The image is capped to leave `reserve` free on the drive (see MirrorSizing), so
    /// the drive must hold that as well. Without it a first run on a drive short of the
    /// reserve made an image, found it too small, and blamed the image's size.
    ///
    /// `free` stands in for the destination's measured free space (now, and counting
    /// purgeable), so a test can fix the figures instead of depending on the machine.
    /// `writes`: see roomVerdict. `freed`: room counted as free on top, to ask whether
    /// the run would fit once that much is given back.
    static func checkRoom(for needs: UInt64, image: URL, imageBytes: UInt64, destination: URL,
                          reserve: UInt64 = 0, writes: UInt64? = nil, freed: UInt64 = 0,
                          free: (now: UInt64?, eventually: UInt64?)? = nil) throws {
        let now = free.map(\.now) ?? JobExecutor.freeNow(for: destination)
        let eventually = free.map(\.eventually) ?? JobExecutor.freeSpace(for: destination)
        if let refusal = roomVerdict(needs: needs, held: Checksum.byteSize(of: image), imageBytes: imageBytes,
                                     freeNow: now.map { $0 + freed }, freeEventually: eventually.map { $0 + freed },
                                     reserve: reserve, writes: writes) {
            throw refusal
        }
    }

    /// The decision in `checkRoom`, from its figures. It refuses exactly what the cap on
    /// the image would leave no room for: anything over what is free now. On the
    /// startup disk macOS also holds purgeable space (local snapshots, caches) that it
    /// frees only when something needs it, and the check used to count that while the
    /// cap didn't: a library between the two passed the check and then ran out of room
    /// inside the image on every run, since nothing ever made macOS purge. A run in
    /// that gap is now refused up front and told why.
    ///
    /// `writes`: about what the run will write into the image, when history's clones
    /// share its blocks (see MirrorHistory.writeEstimate). All of it takes new room on
    /// the drive then, files written over as well as what the library grew by. Left
    /// out, a mirror with history lost room on every run without the check seeing it,
    /// until a run filled the drive.
    static func roomVerdict(needs: UInt64, held: UInt64, imageBytes: UInt64,
                            freeNow: UInt64?, freeEventually: UInt64?, reserve: UInt64 = 0,
                            writes: UInt64? = nil) -> MirrorSpaceError? {
        let margin = min(needs / 20, 1 << 30)
        let fromDrive = max(needs > held ? needs - held : 0, writes ?? 0) + margin
        if let eventually = freeEventually, eventually < fromDrive {
            return .notEnoughRoom(needed: fromDrive, free: eventually)
        }
        if let now = freeNow, now < fromDrive {
            return .notEnoughRoomUntilPurged(needed: fromDrive, free: now,
                                             purgeable: (freeEventually ?? now) > now ? (freeEventually ?? now) - now : 0)
        }
        if let now = freeNow, now < fromDrive + reserve {
            return .notEnoughRoomBesideReserve(needed: fromDrive, free: now, reserve: reserve)
        }
        // a fixed-size image too small to hold the library at all
        if imageBytes < needs + margin {
            return .imageTooSmall(size: imageBytes, needed: needs + margin)
        }
        return nil
    }

    /// `hdiutil resize -limits` prints "min current max" in 512-byte sectors.
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
    /// enough room only if macOS gave up the purgeable space it is holding
    case notEnoughRoomUntilPurged(needed: UInt64, free: UInt64, purgeable: UInt64)
    case imageTooSmall(size: UInt64, needed: UInt64)
    /// the room is there, but only by eating into what is kept free on the drive
    case notEnoughRoomBesideReserve(needed: UInt64, free: UInt64, reserve: UInt64)
    case couldNotResize(String)

    /// the drive hasn't the room, as opposed to the image (see makingRoom)
    var isShortOfRoom: Bool {
        switch self {
        case .notEnoughRoom, .notEnoughRoomUntilPurged, .notEnoughRoomBesideReserve: return true
        case .imageTooSmall, .couldNotResize: return false
        }
    }
}

extension MirrorSpaceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notEnoughRoom(let needed, let free):
            return "not enough space for the mirror: this run needs about \(JobExecutor.human(needed)) more and only \(JobExecutor.human(free)) is free. Nothing was changed; free up space or choose a bigger destination."
        case .notEnoughRoomUntilPurged(let needed, let free, let purgeable):
            return "not enough space for the mirror: this run needs about \(JobExecutor.human(needed)) more and \(JobExecutor.human(free)) is free now. macOS is holding another \(JobExecutor.human(purgeable)) as purgeable space (local snapshots and caches), which Finder counts as available, but it releases that only when something else needs it, and a mirror can't make it. Nothing was changed; free up space on the drive and run again."
        case .imageTooSmall(let size, let needed):
            return "the mirror's disk image holds \(JobExecutor.human(size)) and the library needs about \(JobExecutor.human(needed)). Nothing was changed."
        case .notEnoughRoomBesideReserve(let needed, let free, let reserve):
            return "not enough space for the mirror on its drive: this run needs about \(JobExecutor.human(needed)) more and \(JobExecutor.human(free)) is free, but a mirror always leaves \(JobExecutor.human(reserve)) of its drive free, because a disk image whose drive fills up loses data. Nothing was changed; free up space on the drive or choose a bigger one."
        case .couldNotResize(let why):
            return "couldn't resize the mirror's disk image to fit the room on its drive (\(why.isEmpty ? "the disk-image tool gave no reason" : why)). The mirror is unchanged; run again."
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
        clearDamaged(dir)           // only a run whose image checked out gets this far
        clearDecayed(dir)           // and a decayed image never runs (see startOverIfAsked)
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

    // MARK: an image found damaged
    //
    // After a run whose drive filled, fsck can find the image's file system damaged.
    // The open mark alone then read as "not compared", the restore window gave no
    // warning, and the next run failed on raw hdiutil text ("no mountable file
    // systems"). The damage is recorded beside the manifest instead, with fsck's reason.

    static let damagedMarkerName = ".cryoframe-mirror-damaged"

    /// why the image in `dir` was found damaged, or nil if it wasn't. Decay counts
    /// even without the damaged marker beside it, which 1.7 clears when fsck passes.
    public static func damage(in dir: URL) -> String? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(damagedMarkerName)) else {
            guard let bands = try? Data(contentsOf: dir.appendingPathComponent(decayedMarkerName)) else { return nil }
            return decayReason(String(decoding: bands, as: UTF8.self).split(separator: "\n").map(String.init))
        }
        let why = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return why.isEmpty ? "reason not recorded" : why
    }

    static func markDamaged(_ dir: URL, why: String) {
        try? Data(why.utf8).write(to: dir.appendingPathComponent(damagedMarkerName), options: .atomic)
    }

    static func clearDamaged(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(damagedMarkerName))
    }

    /// what a check says about a mirror recorded as damaged
    public static func damagedDetail(_ why: String) -> String {
        "the mirror's disk image was found damaged after a run whose drive filled (\(why)); the backup in it can't be trusted and may not open. The job's next run says how to start the mirror afresh."
    }

    /// what a check says about the mirror in `dir`, recorded as damaged for `why`
    public static func damagedDetail(_ why: String, in dir: URL) -> String {
        isDecayed(dir) ? decayedDetail(why, history: !MirrorHistory.entries(in: dir).isEmpty) : damagedDetail(why)
    }

    /// what a check says about a mirror whose bands decayed. `history`: the mirror
    /// has history, which shares its blocks (see MirrorHistory).
    public static func decayedDetail(_ why: String, history: Bool = false) -> String {
        "part of the mirror's disk image changed on its drive after it was written (\(why)), which is what a failing drive does; the backup in it can't be trusted. Start this mirror over from Storage."
            + (history ? historyShares : "")
    }

    /// what is said wherever decay is reported of a mirror that has history
    static let historyShares = " The mirror's history shares the same parts of the drive, so its earlier copies may hold the same damage."

    // MARK: decay (see BandCheck)
    //
    // Decay is recorded with the damaged marker, which 1.7 also reads, and with a mark
    // of its own that says which kind of damage it is: fsck can pass an image whose
    // band data changed under it, so a decayed mirror is never cleared by a check.

    static let decayedMarkerName = ".cryoframe-mirror-decayed"

    /// the bands found decayed, "1a, 2f" (at most a few named)
    static func decayReason(_ bands: [String]) -> String {
        let named = bands.prefix(5).joined(separator: ", ") + (bands.count > 5 ? " and \(bands.count - 5) more" : "")
        return bands.count == 1 ? "data band \(named) no longer reads back as it was written"
                                : "\(bands.count) data bands (\(named)) no longer read back as they were written"
    }

    public static func isDecayed(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(decayedMarkerName).path)
    }

    static func markDecayed(_ dir: URL, bands: [String]) {
        try? Data((bands.joined(separator: "\n") + "\n").utf8).write(to: dir.appendingPathComponent(decayedMarkerName), options: .atomic)
    }

    static func clearDecayed(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(decayedMarkerName))
    }

    // MARK: start this mirror over
    //
    // A damaged mirror can't be repaired in place, and its job's runs are refused. The
    // way out is a new image. The damaged one isn't deleted: it is put aside, hidden in
    // the mirror's folder, and removed only once the new one is sealed, so a first run
    // that fails part way leaves the old copy, damaged as it is, where it can be found.
    //
    // That needs room for both, and on a drive the mirror fills more than half of, the
    // new one filled the drive behind the old one, every time. So the room is checked
    // before a start over begins (JobExecutor.startOverRefusal), and when there isn't
    // enough the user can choose to have the damaged image removed first instead.

    static let startOverName = ".cryoframe-mirror-start-over"
    /// what the request says when the damaged image is to be removed, not kept
    static let removeFirstWord = "remove"

    /// where a mirror started over keeps its old image until the new one is complete
    public static func replaced(_ bundle: URL) -> URL {
        bundle.deletingLastPathComponent().appendingPathComponent("." + bundle.lastPathComponent.replacingOccurrences(
            of: ".sparsebundle", with: ".replaced.sparsebundle"), isDirectory: true)
    }

    /// Ask for the damaged mirror in `dir` to be started over at its job's next run:
    /// its image kept aside until the new one is complete, or removed first, when the
    /// drive hasn't room for both. Removing it is also how a start over under way gets
    /// the room to finish.
    public static func requestStartOver(_ dir: URL, removingDamagedFirst: Bool = false) throws {
        try Data((removingDamagedFirst ? removeFirstWord : "").utf8).write(to: dir.appendingPathComponent(startOverName), options: .atomic)
    }

    static func startOverRemovesFirst(_ dir: URL) -> Bool {
        (try? Data(contentsOf: dir.appendingPathComponent(startOverName))).map {
            String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == removeFirstWord
        } ?? false
    }

    /// What starting the mirror whose image is `bundle` over has besides the drive's
    /// free space; nil when it's neither damaged nor being started over.
    public struct StartOverRoom: Sendable, Equatable {
        /// the damaged image is aside, and the new one isn't complete
        public var underWay: Bool
        public var removingDamagedFirst: Bool
        /// room the new mirror has on top of what's free: what a half-built new image
        /// already holds (or gives back, when it's replaced), and the damaged image when
        /// it's removed first
        public var credit: UInt64
        /// the damaged image's size, about what a new one needs
        public var oldBytes: UInt64
    }

    /// `removingDamagedFirst`: what is to be done with the damaged image; nil: what was asked
    public static func startOverRoom(_ bundle: URL, in dir: URL, removingDamagedFirst: Bool? = nil) -> StartOverRoom? {
        let fm = FileManager.default
        let aside = replaced(bundle)
        // an old image left aside after the new one sealed isn't a start over under way
        let underWay = fm.fileExists(atPath: aside.path) && !fm.fileExists(atPath: dir.appendingPathComponent(ArchiveManifest.sidecarName).path)
        guard underWay || (damage(in: dir) != nil && fm.fileExists(atPath: bundle.path)) else { return nil }
        let removing = removingDamagedFirst ?? (startOverRequested(dir) && startOverRemovesFirst(dir))
        let current = fm.fileExists(atPath: bundle.path) ? JobExecutor.directorySize(bundle) : 0
        let old = underWay ? JobExecutor.directorySize(aside) : current
        return StartOverRoom(underWay: underWay, removingDamagedFirst: removing,
                             credit: (underWay ? current : 0) + (removing ? old : 0), oldBytes: old)
    }

    public static func startOverRequested(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(startOverName).path)
    }

    /// Put a damaged image aside, or remove it if that was asked, and forget what was
    /// recorded of it, so the run makes a new mirror from scratch. Only a damaged
    /// mirror, or one being started over, is started over: a request for any other is
    /// dropped. Refused while the image is attached anywhere.
    ///
    /// While a start over is under way (the old image aside), asking again removes the
    /// unfinished new image, since it never sealed; asking to remove the damaged one
    /// removes the old image, and the new one, unless it is damaged too, carries on.
    static func startOverIfAsked(_ bundle: URL, in dir: URL, runner: CommandRunner) throws {
        guard startOverRequested(dir) else { return }
        let fm = FileManager.default
        let aside = replaced(bundle)
        let manifest = dir.appendingPathComponent(ArchiveManifest.sidecarName)
        // an old image still aside after the new one sealed (removing it failed) is
        // the one to go, not the newer image
        if fm.fileExists(atPath: aside.path), fm.fileExists(atPath: manifest.path) { try fm.removeItem(at: aside) }
        let underWay = fm.fileExists(atPath: aside.path)
        let damaged = damage(in: dir) != nil
        guard damaged || underWay else {
            try? fm.removeItem(at: dir.appendingPathComponent(startOverName))
            return
        }
        let removeFirst = startOverRemovesFirst(dir)
        let replacing = fm.fileExists(atPath: bundle.path) && (damaged || !removeFirst)
        if replacing {
            try MirrorMounts.refuseIfOpen(bundle, runner: runner)
            // what was recorded of it first: a crash after this leaves the request and the
            // damage marked, and the next run starts over again
            try? fm.removeItem(at: manifest)
            BandTable.remove(in: dir)
        }
        if removeFirst, underWay { try fm.removeItem(at: aside) }
        if replacing {
            if removeFirst || underWay { try fm.removeItem(at: bundle) } else { try fm.moveItem(at: bundle, to: aside) }
            clearOpen(dir)
            clearDamaged(dir)
            clearDecayed(dir)
        }
        try? fm.removeItem(at: dir.appendingPathComponent(startOverName))
    }

    /// a mirror of a job's found damaged, as Storage offers to start it over
    public struct Damaged: Sendable, Equatable, Identifiable {
        public var id: String { dir.path }
        public var library: String
        /// the mirror's folder, where Start This Mirror Over is asked for
        public var dir: URL
        /// what a check says about it
        public var detail: String
        /// the image in the mirror's place is recorded damaged
        public var imageDamaged: Bool
        /// it is being started over: the damaged image is aside, and the new one isn't complete
        public var underWay: Bool
        /// the damaged image's size, about what a new mirror needs
        public var oldBytes: UInt64
        /// what a half-built new image already holds
        public var newBytes: UInt64
        /// free on its drive; nil when the drive doesn't say
        public var free: UInt64?

        /// what a new mirror needs that the drive doesn't yet give it, the damaged one kept
        public var neededBeside: UInt64 {
            let need = oldBytes + oldBytes / 20
            return need > newBytes ? need - newBytes : 0
        }
        /// a new mirror fits beside the damaged one, as far as can be told
        public var roomBeside: Bool { free.map { $0 >= neededBeside } ?? true }
    }

    /// the mirrors of `job` at `target` recorded as damaged, or being started over
    public static func damaged(job: BackupJob, target: Target, freeSpace: (URL) -> UInt64? = { JobExecutor.freeSpace(for: $0) }) -> [Damaged] {
        guard case .liveMirror = job.format else { return [] }
        return job.libraries.compactMap { lib in
            // a start over under way has no manifest, so no archive, until the new one seals
            guard let dir = LibraryFolders.archives(job: job, library: lib, in: target.destinationDir).first?.dir
                    ?? LibraryFolders.holdings(job: job, library: lib, in: target.destinationDir).first?.folder,
                  let bundle = image(in: dir), let room = startOverRoom(bundle, in: dir, removingDamagedFirst: false) else { return nil }
            let detail = damage(in: dir).map { damagedDetail($0, in: dir) }
                ?? "it is being started over, and the new mirror isn't complete yet. The damaged one is kept, hidden beside it, until it is."
            return Damaged(library: lib.displayName, dir: dir, detail: detail, imageDamaged: damage(in: dir) != nil,
                           underWay: room.underWay, oldBytes: room.oldBytes, newBytes: room.credit, free: freeSpace(dir))
        }
    }

    /// the mirror's image in `dir`, as named there or by the old image a start over put aside
    static func image(in dir: URL) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let suffix = ".replaced.sparsebundle"
        if let shown = names.sorted().first(where: { !$0.hasPrefix(".") && $0.hasSuffix(".sparsebundle") }) {
            return dir.appendingPathComponent(shown, isDirectory: true)
        }
        guard let aside = names.first(where: { $0.hasPrefix(".") && $0.hasSuffix(suffix) }) else { return nil }
        return dir.appendingPathComponent(String(aside.dropFirst().dropLast(suffix.count)) + ".sparsebundle", isDirectory: true)
    }

    /// the old image of a mirror started over, once the new one is sealed
    static func removeReplaced(_ bundle: URL) {
        let aside = replaced(bundle)
        if FileManager.default.fileExists(atPath: aside.path) { try? FileManager.default.removeItem(at: aside) }
    }

    static func clearOpen(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(openMarkerName))
    }
}
