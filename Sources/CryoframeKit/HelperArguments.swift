//
//  HelperArguments.swift
//  CryoframeKit
//
//  What the root helper checks of the arguments a caller sends, before any of them
//  reaches tmutil, diskutil or mount_apfs. The caller is pinned by its signature, so
//  this is depth: root should still not pass along a path a tool would read as an
//  option, or mount a device that isn't shaped like one.
//

import Foundation
import CryoframeShared

public enum HelperArguments {
    /// Throws unless `volume` is one the helper will hand to its tools: the mount
    /// point empty (the boot volume, see TMUtilSnapshotBackend.tmutilPath) or an
    /// absolute path, and the device empty (looked up from the mount point) or a
    /// disk slice such as /dev/disk3s5.
    public static func check(_ volume: VolumeRef) throws {
        guard isMountPoint(volume.mountPoint) else { throw HelperError.volumeNotFound(volume.mountPoint) }
        guard volume.bsdDevice.isEmpty || isDiskSlice(volume.bsdDevice) else {
            throw HelperError.volumeNotFound(volume.bsdDevice)
        }
    }

    /// Empty, or an absolute path: so never one that starts with "-", which tmutil
    /// and diskutil would take as an option. No control characters either.
    public static func isMountPoint(_ path: String) -> Bool {
        if path.isEmpty { return true }
        return path.hasPrefix("/") && !path.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    /// /dev/disk<digits>s<digits>, and nothing else
    public static func isDiskSlice(_ device: String) -> Bool {
        let prefix = "/dev/disk"
        guard device.hasPrefix(prefix) else { return false }
        let parts = device.dropFirst(prefix.count).split(separator: "s", omittingEmptySubsequences: false)
        let digits: Set<Character> = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]
        return parts.count == 2 && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { digits.contains($0) }
        }
    }
}
