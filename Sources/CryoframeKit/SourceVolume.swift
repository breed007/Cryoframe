//
//  SourceVolume.swift
//  CryoframeKit
//
//  Which disk a library actually lives on, and whether that disk can be frozen.
//
//  Cryoframe used to assume every library sat on the boot Data volume. Its target
//  user does not work that way: a photo or music library big enough to be worth
//  backing up is usually on an external SSD. Those libraries failed at run time
//  with "library not found" — the library was right there, it just was not inside
//  the snapshot we took, because we snapshotted the wrong disk.
//

import Foundation

public struct SourceVolume: Sendable, Equatable {
    /// where the volume is mounted: "/System/Volumes/Data", "/Volumes/Media", …
    public let mountPoint: String
    /// lowercased filesystem type as the kernel reports it: "apfs", "hfs", "exfat".
    public let fsType: String
    public let name: String

    public init(mountPoint: String, fsType: String, name: String) {
        self.mountPoint = mountPoint; self.fsType = fsType; self.name = name
    }

    /// the boot volume's data half, where the home directory lives.
    public var isBootData: Bool { mountPoint == "/" || mountPoint == "/System/Volumes/Data" }

    /// only APFS can give us a point-in-time copy. HFS+ and exFAT — ordinary formats
    /// for an external media drive — cannot, so those libraries have to be read live
    /// with their app closed instead.
    public var canSnapshot: Bool { fsType == "apfs" }

    /// where `live` appears inside a snapshot of this volume mounted at `snapshotMount`.
    ///
    /// The boot volume is the awkward one. Its data half is mounted at
    /// /System/Volumes/Data, but firmlinks make its contents show up at / — so a live
    /// "/Users/me/Pictures/X" is "<snapshot>/Users/me/Pictures/X", not
    /// "<snapshot>/System/Volumes/Data/Users/…". Every other volume is the simple
    /// case: strip the mount point, keep the rest.
    public func frozenPath(live: String, snapshotMount: String) -> String? {
        let rest: String
        if isBootData {
            rest = String(live.drop(while: { $0 == "/" }))
        } else {
            let prefix = mountPoint.hasSuffix("/") ? String(mountPoint.dropLast()) : mountPoint
            guard live == prefix || live.hasPrefix(prefix + "/") else { return nil }
            rest = String(live.dropFirst(prefix.count).drop(while: { $0 == "/" }))
        }
        let base = snapshotMount.hasSuffix("/") ? String(snapshotMount.dropLast()) : snapshotMount
        return rest.isEmpty ? base : base + "/" + rest
    }
}

public enum VolumeInspector {
    /// the volume a path lives on, straight from the kernel — no guessing from the
    /// path's shape, which is what got this wrong before.
    public static func volume(for url: URL) -> SourceVolume? {
        var s = statfs()
        guard statfs(url.path, &s) == 0 else { return nil }
        let mount = withUnsafePointer(to: s.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        let fs = withUnsafePointer(to: s.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
        }
        let name = (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName)
            ?? (mount as NSString).lastPathComponent
        return SourceVolume(mountPoint: mount, fsType: fs.lowercased(), name: name ?? mount)
    }
}
