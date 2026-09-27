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
        for i in 0..<5 {
            if !isMounted(url) { break }
            if let r = try? runner.run("/usr/bin/hdiutil", ["detach", url.path], stdin: nil), r.ok { break }
            Thread.sleep(forTimeInterval: 0.4 * Double(i + 1))
        }
        if isMounted(url) { _ = try? runner.runRetryingBusy("/usr/bin/hdiutil", ["detach", "-force", url.path]) }
        removeDirectory(url)
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
