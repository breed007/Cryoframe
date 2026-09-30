//
//  MountPoint.swift
//  CryoframeKit
//
//  Rules for the directories disk images are attached at.
//
//  A recursive remove of a directory that still has a volume mounted on it walks
//  INTO the volume and deletes its contents. For the live mirror that volume is
//  the only copy of the backup: a Stop that left the image attached, followed by
//  the cleanup's `removeItem(mountpoint)`, emptied a 30-file mirror to 0. So a
//  mount directory is only ever removed with rmdir(2), which cannot remove
//  anything but an empty directory, and a mounted one is detached first.
//

import Foundation

public enum MountPoint {
    /// true when a volume is mounted exactly at `url` (not merely somewhere below it).
    public static func isMounted(_ url: URL) -> Bool {
        var s = statfs()
        guard statfs(url.path, &s) == 0 else { return false }
        let on = withUnsafeBytes(of: s.f_mntonname) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return canonical(on) == canonical(url.path)
    }

    /// the device mounted exactly at `url` ("/dev/disk7s1"), or nil when nothing is
    static func device(at url: URL) -> String? {
        var s = statfs()
        guard isMounted(url), statfs(url.path, &s) == 0 else { return nil }
        return withUnsafeBytes(of: s.f_mntfromname) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// unmount the volume at `url` and leave its device attached: for a volume mounted
    /// on another program's device (see ArchiveReader.attach), which detaching would
    /// take from it
    static func unmount(_ url: URL, runner: CommandRunner) {
        for i in 0..<5 {
            if !isMounted(url) { return }
            if let r = try? runner.run("/usr/bin/hdiutil", ["unmount", url.path], stdin: nil), r.ok { return }
            Thread.sleep(forTimeInterval: 0.4 * Double(i + 1))
        }
        if isMounted(url) { _ = try? runner.runRetryingBusy("/usr/bin/hdiutil", ["unmount", "-force", url.path]) }
    }

    /// remove an EMPTY mount directory. Never recursive: if something is still
    /// mounted there, or anything is inside it, it stays.
    public static func removeDirectory(_ url: URL) {
        _ = rmdir(url.path)
    }

    /// make `url` safe to attach at: detach whatever is mounted there (politely,
    /// then by force), and clear an unmounted leftover directory. Throws when a
    /// volume is still mounted afterwards, because attaching over it, or writing
    /// into it, is exactly how a mirror gets emptied or a run writes to the wrong
    /// place.
    public static func clear(_ url: URL, runner: CommandRunner) throws {
        if isMounted(url) {
            _ = try? runner.run("/usr/bin/hdiutil", ["detach", url.path], stdin: nil)
            if isMounted(url) { _ = try? runner.runRetryingBusy("/usr/bin/hdiutil", ["detach", "-force", url.path]) }
            if isMounted(url) { throw MountPointError.stillMounted(url.path) }
        }
        // not mounted, so a recursive remove only touches this directory's own files
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// detach the volume at `url`: retry while it's busy, then force. Leaves the
    /// directory if the volume would not go.
    public static func detach(_ url: URL, runner: CommandRunner) {
        detachImage(at: url, runner: runner)
        removeDirectory(url)
    }

    /// Detach the disk image mounted at `url`: retry while it's busy, then force. Returns
    /// at once when nothing is mounted there.
    ///
    /// Detaching unmounts the volume and then ejects the image's disk, and the eject can
    /// fail on its own ("couldn't eject disk4 - Resource busy", exit 16) when something
    /// still has the disk open for a moment after the unmount. That left the image
    /// attached with nothing mounted, for as long as the process ran: to the next run
    /// it looks like Disk Utility's or Terminal's, so every later mirror run of the
    /// scheduled agent was refused. So the attach that was mounted here is followed
    /// until it has gone, by the disk-image process serving it (a later attach of the
    /// image may be handed the same device name, never the same process).
    static func detachImage(at url: URL, runner: CommandRunner) {
        let own = attach(mountedAt: url, runner: runner)
        for i in 0..<5 {
            if !isMounted(url) { break }
            if let r = try? runner.run("/usr/bin/hdiutil", ["detach", url.path], stdin: nil), r.ok { break }
            Thread.sleep(forTimeInterval: 0.4 * Double(i + 1))
        }
        if isMounted(url) { _ = try? runner.runRetryingBusy("/usr/bin/hdiutil", ["detach", "-force", url.path]) }
        guard let own, !isMounted(url) else { return }
        for i in 0..<6 {
            guard let attaches = MirrorMounts.attachesIfKnown(runner: runner) else {
                Thread.sleep(forTimeInterval: 0.4 * Double(i + 1))
                continue
            }
            // gone, or mounted again (someone else's attach now): nothing of ours left
            guard let left = attaches.first(where: { $0.path == own.path && $0.helper == own.helper && $0.devices.first == own.devices.first }),
                  !left.mounted, let whole = left.devices.first else { return }
            if let r = try? runner.run("/usr/bin/hdiutil", ["detach", "-force", whole], stdin: nil), r.ok { return }
            Thread.sleep(forTimeInterval: 0.4 * Double(i + 1))
        }
    }

    /// the attach whose volume is mounted at `url`, as `hdiutil info` lists it
    static func attach(mountedAt url: URL, runner: CommandRunner) -> MirrorMounts.Attach? {
        guard let device = device(at: url) else { return nil }
        let holding = MirrorMounts.attachesIfKnown(runner: runner)?.filter { $0.devices.contains(device) } ?? []
        return holding.count == 1 ? holding.first : nil
    }

    /// statfs reports /private/var paths as /private/var, callers may say /var
    private static func canonical(_ p: String) -> String {
        TMUtilSnapshotBackend.canonicalPath(p)
    }
}

public enum MountPointError: Error, Equatable {
    case stillMounted(String)
}

extension MountPointError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .stillMounted(let path):
            return "a disk image is still open at \(path) and would not detach — close anything using it, then run again"
        }
    }
}
