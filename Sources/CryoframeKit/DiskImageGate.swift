//
//  DiskImageGate.swift
//  CryoframeKit
//
//  `hdiutil attach` is not safely concurrent. Ask two of them to run at the same
//  moment and one comes back EAGAIN — "Resource temporarily unavailable" — which
//  reads to everything upstream as "this archive won't open."
//
//  That matters because Cryoframe runs jobs concurrently (two by default). Two jobs
//  each finishing with a mount-and-open verification, or a live-mirror job attaching
//  its sparsebundle while a health check attaches an archive, is an ordinary Tuesday
//  — and the loser gets told a perfectly good archive is broken. Retrying alone does
//  not fix it: under sustained contention the whole retry budget can expire.
//
//  So attaches queue. Only the attach call is held, not the mounted lifetime, so
//  verification and restore still overlap freely once each image is up.
//

import Foundation
import CryptoKit

public enum DiskImageGate {
    private static let semaphore = DispatchSemaphore(value: 1)

    /// run one `hdiutil attach` at a time, process-wide.
    public static func serialized<T>(_ body: () throws -> T) rethrows -> T {
        semaphore.wait()
        defer { semaphore.signal() }
        return try body()
    }
}

/// One attach of a disk image at a time across the app and the agent. An attach holds
/// its image's lock from before `hdiutil attach` until the image is mounted or, when
/// it is attached without mounting (a file system check, a key check), until it is
/// detached again. So a device of the image with nothing mounted on it that appears
/// while the lock is held belongs to no other attach of Cryoframe's: this attach's own
/// failure left it, and it is detached (see attaching). One that was there before may
/// be another program's, and stays. Without the lock, such a device may be another
/// attach's, caught between attaching and mounting.
///
/// The lock files sit in the temporary folder beside the volume locks and are never
/// removed (an flock lives on its inode, so removing a held one would let a second
/// holder in).
struct ImageLock {
    let fd: Int32

    /// how long an attach waits for another to finish with the image: a check of a
    /// large mirror's file system holds it for a minute or so
    static let patience: TimeInterval = 120

    /// how long a mirror run waits for an attach of its image with nothing mounted to
    /// end by itself before it is refused (see settled)
    static let settling: TimeInterval = 20

    static func url(for image: URL, in base: URL = MirrorMounts.defaultBase) -> URL {
        let path = TMUtilSnapshotBackend.canonicalPath(image.resolvingSymlinksInPath().path)
        let id = SHA256.hash(data: Data(path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return base.appendingPathComponent("cf-image-lock-\(id)")
    }

    /// The lock of `image`, waiting up to `wait` seconds for its holder; nil when it
    /// isn't had in that time, or Stop ends the wait, or its file can't be made.
    static func acquire(_ image: URL, wait: TimeInterval = 0, control: RunControl? = nil,
                        in base: URL = MirrorMounts.defaultBase) -> ImageLock? {
        let fd = open(url(for: image, in: base).path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        let until = Date().addingTimeInterval(wait)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if Date() >= until || control?.isCancelled == true { close(fd); return nil }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return ImageLock(fd: fd)
    }

    func release() { flock(fd, LOCK_UN); close(fd) }

    /// `body`, an attach of `image` and the look at whether it mounted, run holding the
    /// image's lock and handed the image's devices attached before it began. Then,
    /// still holding the lock, any device of the image that wasn't there before and has
    /// nothing mounted on it is detached (an attach that fails, or is retried, can
    /// leave one).
    ///
    /// A device there before is never this attach's, mounted or not, and is never
    /// detached: every attach of Cryoframe's holds the lock, so it is someone else's.
    /// An image attached outside Cryoframe with nothing mounted (Disk Utility's First
    /// Aid, `hdiutil attach -nomount` in Terminal) takes no lock, and the cleanup that
    /// went by the lock alone took it for debris: a restore opening that image detached
    /// the holder's disk. Each caller decides what such a device means for its attach.
    /// The one exception goes first: an attach Cryoframe recorded as its own, left by a
    /// process that has since died (see AttachRecords).
    ///
    /// Nothing is attached without the lock: an attach made after giving up on the
    /// holder could be taken for the holder's debris and detached under it. After
    /// `wait` seconds that is `DiskImageInUse`, and Stop ends the wait early; the run's
    /// control is `control`, or else the runner's (a teardown runner has none).
    ///
    /// With `settle`, an attach of the image with nothing mounted is first given that
    /// many seconds to end by itself (see settled).
    static func attaching<T>(_ image: URL, runner: CommandRunner, control: RunControl? = nil,
                             wait: TimeInterval = patience, settle: TimeInterval = 0,
                             _ body: (_ before: Set<String>) throws -> T) throws -> T {
        let control = control ?? runner.control
        let look = runner.forTeardown
        guard let lock = acquire(image, wait: wait, control: control) else {
            if control?.isCancelled == true { throw CancelledError() }
            throw DiskImageInUse(image: image.path, mountedAt: MirrorMounts.mountPoints(of: image, runner: look))
        }
        defer { lock.release() }
        AttachRecords.releaseLeftovers(of: image, runner: look, holding: lock)
        // can't tell what is attached: nothing here could be told apart from this attach's
        guard let before = try settled(image, runner: look, within: settle, control: control, holding: lock) else {
            throw ArchiveError.toolFailed(tool: "hdiutil", status: 1, stderr: "couldn't list the disk images attached on this Mac")
        }
        defer { ArchiveReader.detachOrphans(ofImage: image, runner: look, holding: lock, sparing: before) }
        return try body(before)
    }

    /// The image's devices once every attach of it with nothing mounted has ended, or
    /// `within` seconds have passed; nil when hdiutil can't say what is attached. Stop
    /// ends the wait (CancelledError).
    ///
    /// Such an attach isn't always someone holding the image. macOS can attach a new
    /// disk image by itself for a moment to scan it, and a detach can still be finishing as the next
    /// run of the same mirror starts. A nightly mirror was refused as "attached
    /// elsewhere" over one of those, which had gone a moment later. Nothing is ever
    /// detached here: waited out, one that stays is the caller's to refuse. A mounted
    /// one won't go by itself, so it ends the wait at once.
    static func settled(_ image: URL, runner: CommandRunner, within: TimeInterval, control: RunControl?,
                        holding lock: ImageLock) throws -> Set<String>? {
        let target = image.resolvingSymlinksInPath().path
        let until = Date().addingTimeInterval(within)
        while true {
            guard let attaches = MirrorMounts.attachesIfKnown(runner: runner) else { return nil }
            let mine = attaches.filter { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == target }
            let devices = Set(mine.flatMap(\.devices))
            if devices.isEmpty || mine.contains(where: \.mounted) || Date() >= until { return devices }
            if control?.isCancelled == true { throw CancelledError() }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }
}

/// Which attaches of a disk image Cryoframe made, and which of its processes made
/// them, so that one a crashed process left behind can be told from everyone else's.
///
/// Only an attach that is mounted can be traced to its owner by its mount point
/// (MirrorMounts.releaseAbandoned). One with nothing mounted (a file system or key
/// check attaches that way; a crash between unmounting and ejecting leaves one) looks
/// the same as Disk Utility's or a command's in Terminal, which must never be
/// detached. So it was never detached at all, and a crashed check blocked every run
/// of that mirror until someone ejected the image by hand or restarted the Mac.
///
/// Every attach records itself here as it is made, holding the image's lock: the
/// image, its devices, the process that attached it, and the disk-image process
/// serving the attach. Device names are handed out again once an image is detached,
/// even to a new attach of the same image; the serving process isn't, so a record
/// matches only the attach it was made for. A device is detached as a leftover only
/// when its record names this image, the recording process is gone (its pid is free
/// or belongs to a later process), the attach it recorded is still the one on the
/// device, and nothing is mounted on it.
///
/// The records sit in the temporary folder beside the image locks, shared by the app
/// and the scheduled agent. A record whose attach has ended says nothing and goes.
enum AttachRecords {
    struct Record: Codable, Equatable {
        /// the image's canonical path
        var image: String
        var devices: [String]
        /// the disk-image process serving the attach
        var helper: ProcessIdentity
        /// the Cryoframe process that attached it
        var owner: ProcessIdentity
    }

    static func folder(in base: URL) -> URL { base.appendingPathComponent("cf-image-attaches", isDirectory: true) }

    static func key(_ path: String) -> String {
        TMUtilSnapshotBackend.canonicalPath(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
    }

    /// `attach`, an attach of `image` made holding its lock, and then a record of the
    /// attach it made. Only an attach that is provably this one is recorded: the one
    /// holding the disk `attach` printed (when it hands back hdiutil's result) or, failing
    /// that, the volume mounted at `mnt`, taken with the disk-image process serving it
    /// now. Anything else new of the image may be another program's, attached in the same
    /// moment, and would be detached as Cryoframe's once it was unmounted. So a failed
    /// attach records nothing (the attach's cleanup takes what it left, holding the lock),
    /// and neither does one that says nothing about its disk.
    ///
    /// Even the attach's own disk is not recorded when it was there before (`before`) or
    /// is served by a process that was already running: hdiutil hands back an existing
    /// attach's disk instead of making one when the image is held read-only elsewhere.
    static func recording<T>(_ image: URL, sparing before: Set<String>, mountedAt mnt: URL? = nil, runner: CommandRunner,
                             owner: ProcessIdentity? = .current, in base: URL = MirrorMounts.defaultBase,
                             _ attach: () throws -> T) rethrows -> T {
        let since = Date().timeIntervalSince1970
        let result = try attach()
        if let device = attachedDevice(result, mountedAt: mnt) {
            record(image, device: device, since: since, sparing: before, runner: runner, owner: owner, in: base)
        }
        return result
    }

    /// the disk an attach says it made: the first device hdiutil printed, or the one
    /// mounted at `mnt`
    static func attachedDevice<T>(_ result: T, mountedAt mnt: URL?) -> String? {
        if let r = result as? CommandResult {
            guard r.ok else { return nil }
            if let printed = r.stdout.split(whereSeparator: \.isWhitespace).first(where: { $0.hasPrefix("/dev/disk") }) {
                return String(printed)
            }
        }
        return mnt.flatMap { MountPoint.device(at: $0) }
    }

    private static func record(_ image: URL, device: String, since: TimeInterval, sparing before: Set<String>,
                               runner: CommandRunner, owner: ProcessIdentity?, in base: URL) {
        guard let owner, let attaches = MirrorMounts.attachesIfKnown(runner: runner) else { return }
        let target = key(image.path)
        // the attach of this image holding the disk; two claiming it say nothing
        let holding = attaches.filter { key($0.path) == target && $0.devices.contains(device) }
        guard holding.count == 1, let a = holding.first, !a.devices.contains(where: before.contains) else { return }
        // served by a process that was already running: an attach that began before
        // this one, so not this one's
        guard let pid = a.helper, let helper = ProcessIdentity.of(pid: pid), helper.startedAt >= since else { return }
        let r = Record(image: target, devices: a.devices, helper: helper, owner: owner)
        guard let data = try? JSONEncoder().encode(r) else { return }
        let dir = folder(in: base)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: dir.appendingPathComponent(UUID().uuidString + ".json"), options: .atomic)
    }

    /// Detach every attach of `image` recorded by a Cryoframe process that is no longer
    /// running, when the attach is still the recorded one and nothing is mounted on it,
    /// and drop the records of attaches that have ended. Held with the image's lock, so
    /// no attach of Cryoframe's is under way. Anything unrecorded, recorded by a live
    /// process, or mounted stays.
    static func releaseLeftovers(of image: URL, runner: CommandRunner, holding lock: ImageLock,
                                 in base: URL = MirrorMounts.defaultBase,
                                 isAlive: (ProcessIdentity) -> Bool = { $0.isAlive }) {
        let fm = FileManager.default
        let dir = folder(in: base)
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil), !files.isEmpty,
              let attaches = MirrorMounts.attachesIfKnown(runner: runner) else { return }
        let target = key(image.path)
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let r = try? JSONDecoder().decode(Record.self, from: data) else { continue }
            // the attach has ended: its devices may be anyone's now
            guard isAlive(r.helper) else { try? fm.removeItem(at: file); continue }
            guard r.image == target, !isAlive(r.owner) else { continue }
            // one process serving two attaches isn't one attach's, and says nothing
            // about which attach is the recorded one (not seen on macOS 26, where
            // diskimages-helper and diskimagesiod each serve a single attach)
            let served = attaches.filter { $0.helper == r.helper.pid }
            guard served.count == 1, let a = served.first, key(a.path) == target,
                  !r.devices.isEmpty, Set(r.devices).isSubset(of: a.devices), !a.mounted else { continue }
            // the image's own disk, listed first, takes the rest with it
            guard let whole = a.devices.first else { continue }
            if (try? runner.runRetryingBusy("/usr/bin/hdiutil", ["detach", whole, "-force"]))?.ok == true {
                try? fm.removeItem(at: file)
            }
        }
    }

    /// releaseLeftovers, when no attach of the image is under way (its lock is free);
    /// otherwise nothing
    static func releaseLeftovers(of image: URL, runner: CommandRunner) {
        guard let lock = ImageLock.acquire(image) else { return }
        defer { lock.release() }
        releaseLeftovers(of: image, runner: runner, holding: lock)
    }
}
