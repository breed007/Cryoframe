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
    ///
    /// Nothing is attached without the lock: an attach made after giving up on the
    /// holder could be taken for the holder's debris and detached under it. After
    /// `wait` seconds that is `DiskImageInUse`, and Stop ends the wait early; the run's
    /// control is `control`, or else the runner's (a teardown runner has none).
    static func attaching<T>(_ image: URL, runner: CommandRunner, control: RunControl? = nil,
                             wait: TimeInterval = patience, _ body: (_ before: Set<String>) throws -> T) throws -> T {
        let control = control ?? runner.control
        let look = runner.forTeardown
        guard let lock = acquire(image, wait: wait, control: control) else {
            if control?.isCancelled == true { throw CancelledError() }
            throw DiskImageInUse(image: image.path, mountedAt: MirrorMounts.mountPoints(of: image, runner: look))
        }
        defer { lock.release() }
        // can't tell what is attached: nothing here could be told apart from this attach's
        guard let before = MirrorMounts.devicesIfKnown(of: image, runner: look) else {
            throw ArchiveError.toolFailed(tool: "hdiutil", status: 1, stderr: "couldn't list the disk images attached on this Mac")
        }
        defer { ArchiveReader.detachOrphans(ofImage: image, runner: look, holding: lock, sparing: before) }
        return try body(before)
    }
}
