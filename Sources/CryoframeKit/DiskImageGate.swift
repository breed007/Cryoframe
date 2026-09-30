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
/// detached again. So a device of the image with nothing mounted on it, found while
/// the lock is held, belongs to no attach under way: a failed attach left it, or a
/// volume was unmounted without ejecting the image, and it is safe to detach (see
/// ArchiveReader.detachOrphans). Without the lock, such a device may be another
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
    /// image's lock; then, still holding it, any device of the image left with nothing
    /// mounted on it is detached (an attach that fails, or is retried, can leave one).
    /// When the lock isn't had in time the attach goes ahead, and nothing is detached.
    static func attaching<T>(_ image: URL, runner: CommandRunner, _ body: () throws -> T) rethrows -> T {
        let lock = acquire(image, wait: patience, control: runner.control)
        defer {
            if let lock {
                ArchiveReader.detachOrphans(ofImage: image, runner: runner.forTeardown, holding: lock)
                lock.release()
            }
        }
        return try body()
    }
}
