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

    /// the file in the work dir naming the process that has the archive open.
    static let ownerFileName = "owner.json"
    /// names every open archive's work dir
    static let workPrefix = "cf-open-"
    /// in the work dir when the volume is mounted on another program's device, which
    /// closing, or sweeping after a crash, unmounts and never detaches
    static let borrowedFileName = "borrowed"

    static func isBorrowed(_ work: URL) -> Bool {
        FileManager.default.fileExists(atPath: work.appendingPathComponent(borrowedFileName).path)
    }

    /// take the volume at `mnt` (a work dir's "mnt") away: detached, or only unmounted
    /// when its device is another program's
    static func release(_ mnt: URL, runner: CommandRunner) {
        if isBorrowed(mnt.deletingLastPathComponent()) {
            MountPoint.unmount(mnt, runner: runner)
        } else {
            _ = try? runner.run("/usr/bin/hdiutil", ["detach", "-force", mnt.path], stdin: nil)
        }
    }

    static func recordOwner(in work: URL) {
        guard let me = ProcessIdentity.current, let data = try? JSONEncoder().encode(me) else { return }
        try? data.write(to: work.appendingPathComponent(ownerFileName), options: .atomic)
    }

    /// An open archive's work dir may be swept once whoever opened it is gone. The
    /// app, the scheduled agent and a second app instance share one temp folder, and
    /// each has archives open for verifies, drills, rehearsals and browsing. One with
    /// no readable owner was opened by an older version, or caught in the instant
    /// before its owner was written; it waits a day, longer than any of those take.
    static func isAbandoned(_ work: URL, now: Date, isAlive: (ProcessIdentity) -> Bool) -> Bool {
        if let data = try? Data(contentsOf: work.appendingPathComponent(ownerFileName)),
           let owner = try? JSONDecoder().decode(ProcessIdentity.self, from: data) {
            return !isAlive(owner)
        }
        guard let made = (try? work.resourceValues(forKeys: [.creationDateKey]))?.creationDate else { return false }
        return now.timeIntervalSince(made) > 24 * 3600
    }

    /// detach the mount (if any) and remove the scratch dir. Always call this.
    public func close() {
        teardownFn()
        Self.removeWork(work)
    }

    /// the scratch dir holds the mount directory. If the volume would not detach,
    /// removing the scratch dir recursively walks into the mounted archive, so it
    /// stays for the launch sweep instead (see MountPoint).
    static func removeWork(_ work: URL) {
        let mnt = work.appendingPathComponent("mnt")
        guard !MountPoint.isMounted(mnt) else { return }
        try? FileManager.default.removeItem(at: work)
    }
}

/// What sits at the top of an opened archive that isn't the library: a mirror's
/// staging copy left by a crashed run, and the file system's own folders. The file
/// browser hid nothing, so a crashed run's staging copy showed beside the library
/// as if it were part of the backup. Only at the top: inside the library, a hidden
/// name is the library's own.
public enum ArchiveBookkeeping {
    public static let rootNames: Set<String> = [MirrorCopy.stagingName, ".fseventsd", ".Spotlight-V100",
                                                ".Trashes", ".TemporaryItems", ".DocumentRevisions-V100"]

    public static func isHidden(_ name: String, atRoot: Bool) -> Bool {
        atRoot && rootNames.contains(name)
    }
}

public struct ArchiveReader: Sendable {
    let runner: CommandRunner
    let workBase: URL
    let transientSettle: TimeInterval
    let cloud: CloudDownload
    /// free bytes on the drive holding a folder (nil: unknown); injectable for tests
    let freeSpace: @Sendable (URL) -> UInt64?
    public init(runner: CommandRunner = ProcessCommandRunner(),
                workBase: URL = FileManager.default.temporaryDirectory,
                transientSettle: TimeInterval = 5, cloud: CloudDownload = .system,
                freeSpace: @escaping @Sendable (URL) -> UInt64? = { JobExecutor.freeSpace(for: $0) }) {
        self.runner = runner; self.workBase = workBase; self.transientSettle = transientSettle; self.cloud = cloud
        self.freeSpace = freeSpace
    }

    /// open `result` into a fresh temp work dir. A non-nil `passphrase` mounts an
    /// AES-256 encrypted dmg/sparsebundle (via `hdiutil -stdinpass`). The caller
    /// MUST `close()` the returned handle to detach the mount and clean up.
    ///
    /// A disk-image system that stays busy through every retry of the attach gets one
    /// more attempt, from scratch. The retries all run with whatever the first failed
    /// attach left behind still in place, and a leftover device is exactly what makes
    /// the next attach fail; the failed open has cleared those by the time it throws.
    /// Without this a drill, a rehearsal or a run's verification reported a good
    /// archive as unopenable whenever Time Machine or another job held the disk-image
    /// system for a few seconds too long, and a scheduled check turned that into an
    /// alert. A second failure is reported as before: busy, not broken.
    ///
    /// An archive evicted to a cloud placeholder is downloaded first (see
    /// CloudDownload), before any tool reads it.
    public func open(_ result: ArchiveResult, passphrase: String? = nil) throws -> OpenedArchive {
        let quiet = (runner as? ProcessCommandRunner)?.quietLimit ?? runner.control?.quietLimit ?? ToolWatchdog.defaultQuietLimit
        try cloud.bringDown(result.artifacts, quietLimit: quiet, control: runner.control)
        do {
            return try openOnce(result, passphrase: passphrase)
        } catch let error as ArchiveError where Self.isTransient(error) {
            if runner.control?.isCancelled == true { throw CancelledError() }
            Thread.sleep(forTimeInterval: transientSettle)
            return try openOnce(result, passphrase: passphrase)
        }
    }

    /// a tool failure the disk-image system reports while it is saturated (EAGAIN), as
    /// opposed to one that says something about the archive. Not "Resource busy": an
    /// attach says that when the image is open elsewhere, which a fresh try won't change.
    static func isTransient(_ error: ArchiveError) -> Bool {
        guard case .toolFailed(_, _, let stderr) = error else { return false }
        return ProcessCommandRunner.isTransient(stderr) && ProcessCommandRunner.isWaitable(stderr)
    }

    private func openOnce(_ result: ArchiveResult, passphrase: String?) throws -> OpenedArchive {
        let fm = FileManager.default
        let work = workBase.appendingPathComponent(OpenedArchive.workPrefix + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        OpenedArchive.recordOwner(in: work)       // so another process's launch sweep leaves it be
        let runner = self.runner
        let teardown = runner.forTeardown      // still works after Stop, when cleanup matters most
        let enc = passphrase != nil
        let stdin = passphrase.map { Data($0.utf8) }

        // Anything that throws below has already created `work`, and may have got as
        // far as attaching a device. Left alone that debris compounds: a failed attach
        // makes the NEXT attach likelier to fail, until nothing will mount at all.
        var mountPoint: URL?
        do {
            switch result.format {
            case .sealedDMG:
                let dmg = try singleFile(result.artifacts, work: work, name: "reassembled.dmg", fm: fm)
                let mnt = work.appendingPathComponent("mnt"); try fm.createDirectory(at: mnt, withIntermediateDirectories: true)
                mountPoint = mnt
                let borrowed = try attach(dmg, at: mnt, work: work, encrypted: enc, stdin: stdin)
                return OpenedArchive(root: mnt, work: work) { Self.close(mnt, borrowed: borrowed, runner: teardown) }

            case .liveMirror:
                let mnt = work.appendingPathComponent("mnt"); try fm.createDirectory(at: mnt, withIntermediateDirectories: true)
                mountPoint = mnt
                let borrowed = try attach(result.artifacts[0], at: mnt, work: work, encrypted: enc, stdin: stdin)
                return OpenedArchive(root: mnt, work: work) { Self.close(mnt, borrowed: borrowed, runner: teardown) }

            case .sealedZip:
                let zip = try singleFile(result.artifacts, work: work, name: "reassembled.zip", fm: fm)
                // a zip is unpacked whole into the work folder (on the startup disk)
                // before anything is copied out of it
                guard let unpacked = Self.unpackedSize(of: zip, runner: runner.forTeardown) else {
                    throw RestoreError.unpackedSizeUnknown(zip.lastPathComponent)
                }
                try checkRoom(unpacked, in: work, doing: "unpacked")
                let ex = work.appendingPathComponent("extract"); try fm.createDirectory(at: ex, withIntermediateDirectories: true)
                try exec(Command("/usr/bin/ditto", ["-x", "-k", zip.path, ex.path]))
                return OpenedArchive(root: ex, work: work) {}
            }
        } catch {
            // may be a no-op; cheap either way. A failed attach's own devices were
            // detached as it failed (see ImageLock.attaching).
            if let mnt = mountPoint { Self.detach(mnt, runner: teardown) }
            OpenedArchive.removeWork(work)
            throw error
        }
    }

    /// attach `image` read-only at `mnt`, or say plainly that it is already open. True
    /// when the volume is mounted on another program's device (see below), which
    /// closing leaves attached.
    ///
    /// A second attach of an image that is already attached fails "Resource busy" in
    /// most cases (measured on macOS 26), which the busy retries then repeated for 13
    /// seconds before the failure's cleanup detached every device of the image:
    /// another reader's mount, or a mirror run's read-write attach in the middle of
    /// its rsync. Not in all: a read-only attach of an image already held read-only
    /// succeeds, with any passphrase, and hands back the holder's disk (macOS 26.7).
    /// Older macOS has been seen answering 0 without mounting anything. So the image
    /// is looked for in hdiutil info first, and an attach that mounted nothing here
    /// is caught too.
    ///
    /// Held with nothing mounted (Disk Utility's First Aid, `hdiutil attach -nomount`,
    /// a volume unmounted without ejecting its image), the image is someone else's
    /// too: closing it used to detach the holder's disk, or a failed attach's cleanup
    /// did. Read-only, its volume is mounted here and only unmounted on close; that
    /// proves nothing about a passphrase, so an encrypted image held that way is
    /// refused instead. Held read-write, the attach fails and is refused.
    private func attach(_ image: URL, at mnt: URL, work: URL, encrypted: Bool, stdin: Data?) throws -> Bool {
        let look = runner.forTeardown
        MirrorMounts.releaseAbandoned(image, runner: look)       // a crashed process's attach
        try MirrorMounts.refuseIfOpen(image, runner: look)
        return try ImageLock.attaching(image, runner: runner) { before in
            let held = DiskImageInUse(image: image.path, mountedAt: [], attachedWithoutMount: true)
            if encrypted, !before.isEmpty { throw held }
            // Held by someone else, the attach may hand back the holder's disk, so the
            // work dir is marked borrowed before it is made: a crash from here on leaves
            // a sweep that only unmounts. If the disk turns out to be this attach's own,
            // the crash leaves it attached but recorded, and the next attach takes it
            // (see AttachRecords); detaching the holder's disk can't be undone.
            let mark = work.appendingPathComponent(OpenedArchive.borrowedFileName)
            if !before.isEmpty { FileManager.default.createFile(atPath: mark.path, contents: nil) }
            do {
                try AttachRecords.recording(image, sparing: before, mountedAt: mnt, runner: look) {
                    try DiskImageGate.serialized {
                        try exec(ArchivePlan.attach(image: image, mountpoint: mnt, readonly: true, encrypted: encrypted), stdin: stdin)
                    }
                }
            } catch {
                try MirrorMounts.refuseIfOpen(image, except: mnt, runner: look)   // opened by someone else meanwhile
                // a system process scanning a fresh image holds it for a while and
                // answers EAGAIN, which open waits out once more (see open)
                if !before.isEmpty, !((error as? ArchiveError).map(Self.isTransient) ?? false) { throw held }
                throw error
            }
            guard MountPoint.isMounted(mnt) else {
                throw DiskImageInUse(image: image.path, mountedAt: MirrorMounts.mountPoints(of: image, runner: look))
            }
            // the holder's disk, mounted here, stays marked, so a sweep unmounts it rather
            // than detach it; this attach's own disk is detached on close
            guard let device = MountPoint.device(at: mnt), before.contains(device) else {
                try? FileManager.default.removeItem(at: mark)
                return false
            }
            return true
        }
    }

    /// close what attach mounted at `mnt`
    @Sendable static func close(_ mnt: URL, borrowed: Bool, runner: CommandRunner) {
        if borrowed { MountPoint.unmount(mnt, runner: runner) } else { detach(mnt, runner: runner) }
    }

    /// a single file to operate on — the artifact itself, or split parts reassembled.
    /// Refuse, before writing there, what the work folder's drive hasn't room for. A
    /// zip is unpacked and split parts are joined in the work folder, on the startup
    /// disk, whatever drive the archive or the restore is on; a large one filled the
    /// startup disk, unchecked, before any check of the restore's own looked.
    private func checkRoom(_ bytes: UInt64, in work: URL, doing what: String) throws {
        let volume = RestoreRoom.volumeName(for: work)
        if let refusal = RestoreRoom.refusal(bytes: bytes, free: freeSpace(work),
                                             volume: "\(volume), where the archive is \(what) first", inPlace: false) {
            throw refusal
        }
    }

    /// What a zip takes on disk once unpacked, from its own directory (zipinfo): its
    /// bytes, and a whole block for every entry. A file takes at least one 4 KB block
    /// however few bytes it holds, so a zip of many small files takes many times its
    /// byte count: 72,000 files of 16 bytes are 12.9 MB in the zip's total and took
    /// 295 MB unpacked. Rounding every entry up to a block is at most a block too many
    /// each. nil if the listing can't be read: a zip can unpack to any size, and its
    /// own size says nothing about that.
    static func unpackedSize(of zip: URL, runner: CommandRunner) -> UInt64? {
        guard let r = try? runner.run("/usr/bin/zipinfo", ["-t", zip.path], stdin: nil), r.ok,
              let b = r.stdout.range(of: #"[0-9]+ bytes uncompressed"#, options: .regularExpression),
              let bytes = UInt64(r.stdout[b].split(separator: " ").first ?? ""),
              let n = r.stdout.range(of: #"^[0-9]+ files?"#, options: .regularExpression),
              let entries = UInt64(r.stdout[n].split(separator: " ").first ?? "") else { return nil }
        return bytes + entries * blockSize
    }

    /// the file system block every unpacked file takes at least one of (APFS)
    static let blockSize: UInt64 = 4096

    /// Parts in the order they were split: by the number after ".part." ("…part.1000"
    /// comes after "…part.999", which sorting the names put before "…part.101"), or
    /// for split(1)'s letters, shorter suffixes first, then alphabetically.
    static func partOrder(_ a: String, _ b: String) -> Bool {
        func suffix(_ n: String) -> Substring { n.range(of: ".part.", options: .backwards).map { n[$0.upperBound...] } ?? Substring(n) }
        let x = suffix(a), y = suffix(b)
        if let i = Int(x), let j = Int(y) { return i < j }
        return x.count != y.count ? x.count < y.count : x < y
    }

    private func singleFile(_ artifacts: [URL], work: URL, name: String, fm: FileManager) throws -> URL {
        if artifacts.count == 1 { return artifacts[0] }
        try checkRoom(artifacts.reduce(0) { $0 + Checksum.byteSize(of: $1) }, in: work, doing: "joined")
        let out = work.appendingPathComponent(name)
        fm.createFile(atPath: out.path, contents: nil)
        let w = try FileHandle(forWritingTo: out); defer { try? w.close() }
        for part in artifacts.sorted(by: { Self.partOrder($0.lastPathComponent, $1.lastPathComponent) }) {
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

    /// Force-detach the devices a failed attach of `image` left behind with nothing
    /// mounted on them.
    ///
    /// A failed attach can leave a device behind with NO mount point. Detaching by
    /// path cannot find those, so they accumulate, and each orphan makes the next
    /// attach likelier to fail with EAGAIN until nothing on the Mac will mount. Only
    /// a reboot or a manual detach clears them, which is not a thing to ask of someone
    /// whose backup just failed.
    ///
    /// Only those: this used to detach every device of the image, and the image being
    /// open elsewhere is the commonest reason an attach fails, so it unmounted a
    /// restore in the middle of its copy, or a mirror run in the middle of its rsync.
    /// And only while no attach of the image is under way (see ImageLock): one caught
    /// between attaching and mounting, or a check that attaches without mounting, has
    /// a device with nothing mounted on it too.
    ///
    /// This one detaches every such device, whoever attached it, so Cryoframe itself
    /// never calls it: an image attached by another program with nothing mounted (Disk
    /// Utility, a command in Terminal) looks the same. Cryoframe's attaches clean up
    /// through ImageLock.attaching, which spares every device there before it began.
    @Sendable static func detachOrphans(ofImage image: URL, runner: CommandRunner) {
        guard let lock = ImageLock.acquire(image) else { return }
        defer { lock.release() }
        detachOrphans(ofImage: image, runner: runner, holding: lock)
    }

    /// detachOrphans, by one holding the image's lock, leaving `sparing` (the devices
    /// attached before its own attach began) alone
    static func detachOrphans(ofImage image: URL, runner: CommandRunner, holding lock: ImageLock,
                              sparing: Set<String> = []) {
        guard let r = try? runner.run("/usr/bin/hdiutil", ["info", "-plist"]), r.ok,
              let data = r.stdout.data(using: .utf8),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = root["images"] as? [[String: Any]] else { return }
        let target = image.resolvingSymlinksInPath().path
        for img in images {
            guard let path = img["image-path"] as? String,
                  URL(fileURLWithPath: path).resolvingSymlinksInPath().path == target,
                  let entities = img["system-entities"] as? [[String: Any]],
                  !entities.contains(where: { $0["mount-point"] != nil }) else { continue }
            // whole-disk entries first: detaching one takes its partitions with it.
            let devices = entities.compactMap { $0["dev-entry"] as? String }
                .sorted { $0.count < $1.count }
            // one attach's devices: any of them there before makes them all someone else's
            guard !devices.contains(where: sparing.contains) else { continue }
            // A detach issued during the contention that caused the failed attach is
            // itself likely to come back EAGAIN. Firing it once and discarding the
            // result leaves the orphan exactly where it was.
            for dev in devices { _ = try? runner.runRetryingBusy("/usr/bin/hdiutil", ["detach", dev, "-force"]) }
        }
    }

    /// Returns at once when nothing is mounted there: a failed open cleaned up by
    /// retrying a detach that could only fail, five times with backoff, 6 s in all.
    @Sendable static func detach(_ mnt: URL, runner: CommandRunner) {
        for i in 0..<5 {
            if !MountPoint.isMounted(mnt) { return }
            if let r = try? runner.run("/usr/bin/hdiutil", ["detach", mnt.path]), r.ok { return }
            Thread.sleep(forTimeInterval: 0.4 * Double(i + 1))
        }
        if MountPoint.isMounted(mnt) { _ = try? runner.runRetryingBusy("/usr/bin/hdiutil", ["detach", "-force", mnt.path]) }
    }

    /// on launch, force-detach and remove any archive a crashed process left open,
    /// and any mirror a crashed run left attached. Only those: an archive a live
    /// process has open (the agent verifying a run, a drill, a rehearsal, another
    /// window browsing, a mirror run) is still in use.
    public static func sweepStaleOpens(in directory: URL = FileManager.default.temporaryDirectory,
                                       runner: CommandRunner = ProcessCommandRunner(), now: Date = Date(),
                                       isAlive: (ProcessIdentity) -> Bool = { $0.isAlive }) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        // a mirror run's attach (MirrorMounts) follows the same rules as an open archive
        for e in entries where e.lastPathComponent.hasPrefix(OpenedArchive.workPrefix) || e.lastPathComponent.hasPrefix(MirrorMounts.prefix) {
            guard OpenedArchive.isAbandoned(e, now: now, isAlive: isAlive) else { continue }
            let mnt = e.appendingPathComponent("mnt")
            if MountPoint.isMounted(mnt) { OpenedArchive.release(mnt, runner: runner) }
            OpenedArchive.removeWork(e)
        }
    }
}
