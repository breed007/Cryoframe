//
//  DriveAllocation.swift
//  CryoframeKit
//
//  What a folder's drive really allocates per file, measured by writing one.
//
//  statfs reports the real cluster on the FSKit drivers (macOS 26 and later) but not
//  on the kernel exFAT and FAT drivers macOS 15 uses, where an export asked for
//  4 KiB a file and a 128 KiB-cluster drive filled partway through. A file written
//  and measured gives the answer whatever the driver says.
//

import Foundation

public struct DriveAllocation: Sendable, Equatable {
    /// the bytes a one-byte file took on the drive; nil when none could be written
    public var allocationUnit: UInt64?
    /// whether the write got a hidden `._` companion; nil when none could be written
    public var companion: Bool?

    public init(allocationUnit: UInt64? = nil, companion: Bool? = nil) {
        self.allocationUnit = allocationUnit; self.companion = companion
    }

    /// What exFAT and FAT clusters can be as large as, assumed when nothing can be
    /// measured (a read-only folder).
    public static let conservativeFATCluster: UInt64 = 128 * 1024

    static let probePrefix = ".cryoframe-probe-"

    /// Writes a one-byte file in `folder`, syncs it, reads what it took and whether a
    /// `._` companion came with it, then removes both. Nothing is left behind, and a
    /// folder that can't be written to gives an empty result rather than an error.
    public static func probe(at folder: URL) -> DriveAllocation {
        let file = folder.appendingPathComponent(probePrefix + UUID().uuidString)
        let companionPath = folder.appendingPathComponent("._" + file.lastPathComponent).path
        let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else { return DriveAllocation() }
        defer {
            unlink(file.path)
            unlink(companionPath)
        }
        guard write(fd, "x", 1) == 1 else { close(fd); return DriveAllocation() }
        _ = fsync(fd)
        var st = stat()
        let measured = fstat(fd, &st) == 0 && st.st_blocks > 0
        close(fd)
        let companion = listxattr(file.path, nil, 0, XATTR_NOFOLLOW) != 0 || access(companionPath, F_OK) == 0
        return DriveAllocation(allocationUnit: measured ? UInt64(st.st_blocks) * 512 : nil, companion: companion)
    }

    /// The drive's allocation unit: the larger of what statfs reports and what the
    /// probe measured. With no measurement, 128 KiB on exFAT and FAT (the largest
    /// cluster they use, so room is never underestimated) and statfs elsewhere.
    public static func cluster(statfsBlockSize: UInt64?, fsType: String, probed: DriveAllocation) -> UInt64 {
        if let unit = probed.allocationUnit { return max(statfsBlockSize ?? 0, unit, 512) }
        if ["exfat", "msdos"].contains(fsType) { return max(statfsBlockSize ?? 0, conservativeFATCluster) }
        return max(statfsBlockSize ?? 4096, 512)
    }
}
