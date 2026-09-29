//
//  MirrorWriteGuard.swift
//  CryoframeKit
//
//  Guarding a mirror run against the drive filling under it.
//
//  A sparse image's writes land in band files on the drive it lives on. When that
//  drive fills while the image is being written, the band writes are lost and the
//  file system inside is damaged, silently: rsync still exits 0. The image is held to
//  what the drive can back (MirrorSizing.targetBytes), which covers the run's own
//  writes, but not another program writing to the same drive at the same time: Time
//  Machine sharing the container, a Finder copy, another job. Measured with a second
//  writer filling a 400 MB drive part-way through a run, 10 runs: 5 failed cleanly,
//  2 reported success with the update lost, 3 left the only copy damaged (files
//  matching neither version, or an image that would not mount). Every bad run took
//  the drive below the reserve.
//
//  So a run watches the drive's free space the whole time the image is attached,
//  flushes the new copy all the way down to the bands before swapping it in, and
//  swaps only if the drive never dipped below its floor. If it did, the run fails,
//  and the image is checked with fsck_apfs before anything else is claimed about it.
//  Mirror runs to the same drive are also taken one at a time, so two of our own jobs
//  can't do this to each other.
//

import Foundation

/// what a run's outcome depends on besides its errors
final class RunWatch: @unchecked Sendable {
    var drive: DriveWatch?
    /// the new copy went in place
    var swapped = false
}

/// the lowest free space seen on a drive while a run writes to it.
final class DriveWatch: @unchecked Sendable {
    let path: String
    /// below this the drive has come close enough to full that writes may have failed
    let floor: UInt64
    private let lock = NSLock()
    private var lowest: UInt64 = .max
    private var watching = false
    private let interval: TimeInterval

    init(watching dir: URL, floor: UInt64, interval: TimeInterval = 0.05) {
        self.path = dir.path; self.floor = floor; self.interval = interval
    }

    func start() {
        lock.lock(); watching = true; lock.unlock()
        sample()
        let t = Thread { [weak self] in
            while let self, self.isWatching {
                self.sample()
                Thread.sleep(forTimeInterval: self.interval)
            }
        }
        t.qualityOfService = .utility
        t.start()
    }

    func stop() {
        sample()
        lock.lock(); watching = false; lock.unlock()
    }

    private var isWatching: Bool { lock.lock(); defer { lock.unlock() }; return watching }

    /// read the drive's free space now
    func sample() {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return }
        let free = UInt64(s.f_bavail) * UInt64(s.f_bsize)
        lock.lock(); lowest = min(lowest, free); lock.unlock()
    }

    var lowestFree: UInt64 { lock.lock(); defer { lock.unlock() }; return lowest }
    var dipped: Bool { lowestFree < floor }
}

/// one mirror run per destination drive at a time, across the app and the agent.
struct VolumeLock {
    let fd: Int32

    /// wait for the drive holding `dir`; Stop ends the wait. The lock files sit
    /// beside the runs' mount directories and are never removed (an flock lives on
    /// its inode, so removing a held one would let a second holder in).
    static func acquire(for dir: URL, in base: URL, control: RunControl?) throws -> VolumeLock? {
        var s = statfs()
        guard statfs(dir.path, &s) == 0 else { return nil }            // can't identify the drive: don't wait
        let id = withUnsafeBytes(of: s.f_fsid) { $0.map { String(format: "%02x", $0) }.joined() }
        let url = base.appendingPathComponent("cf-volume-lock-\(id)")
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if control?.isCancelled == true { close(fd); throw CancelledError() }
            control?.waitWhilePaused()
            Thread.sleep(forTimeInterval: 0.5)
        }
        return VolumeLock(fd: fd)
    }

    func release() { flock(fd, LOCK_UN); close(fd) }
}

/// Whether the file system inside a mirror's image is sound, by fsck_apfs, read-only,
/// on the image attached without mounting. Used after a run whose drive came close to
/// full: it catches a damaged file system, though not lost file data inside a sound
/// one (which is why a run that dipped never counts as a success).
enum MirrorIntegrity {
    enum Verdict: Equatable { case sound, damaged(String), unknown(String) }

    static func check(_ bundle: URL, passphrase: String?, runner: CommandRunner) -> Verdict {
        var args = ["attach", "-nomount", "-readonly", "-nobrowse", bundle.path]
        if passphrase != nil { args.append("-stdinpass") }
        guard let a = try? runner.run("/usr/bin/hdiutil", args, stdin: passphrase.map { Data($0.utf8) }), a.ok else {
            return .unknown("the image wouldn't attach to be checked")
        }
        let lines = a.stdout.split(separator: "\n")
        let whole = lines.first.map { String($0.split(separator: " ", omittingEmptySubsequences: true).first ?? "") } ?? ""
        defer { _ = try? runner.runRetryingBusy("/usr/bin/hdiutil", ["detach", "-force", whole]) }
        guard let container = lines.first(where: { $0.contains("Apple_APFS") })
                .map({ String($0.split(separator: " ", omittingEmptySubsequences: true).first ?? "") }), !container.isEmpty else {
            return .unknown("no APFS container in the image")
        }
        guard let f = try? runner.run("/sbin/fsck_apfs", ["-n", container]) else { return .unknown("fsck_apfs didn't run") }
        if f.ok { return .sound }
        let why = (f.stdout + f.stderr).split(separator: "\n").first { $0.contains("error") }.map(String.init) ?? "fsck_apfs exit \(f.status)"
        return .damaged(why)
    }
}
