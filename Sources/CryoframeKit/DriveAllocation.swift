//
//  DriveAllocation.swift
//  CryoframeKit
//
//  What a folder's drive really allocates per file, measured by writing one.
//
//  statfs reports the real cluster on the FSKit drivers (macOS 26 and later) but not
//  on the exFAT and FAT drivers macOS 15 uses, where an export asked for 4 KiB a
//  file and a 128 KiB-cluster drive filled partway through. A file written and
//  measured gives the answer whatever the driver says.
//
//  On CI's macOS 15 runner those drivers reported 512 for statfs's block size, and
//  the probe file showed no blocks once written and synced. So when it shows none,
//  it is measured by what the drive gives it: it is lengthened a power of two at a
//  time until the drive's free space drops, and the drop is one unit.
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

    /// What exFAT clusters can be as large as, and FAT32's (32 KiB by its
    /// specification), assumed when nothing can be measured (a read-only folder).
    public static let conservativeExFATCluster: UInt64 = 128 * 1024
    public static let conservativeFAT32Cluster: UInt64 = 32 * 1024

    /// the largest unit a probe looks for (exFAT's largest cluster)
    static let largestUnit: UInt64 = 32 * 1024 * 1024

    static let probePrefix = ".cryoframe-probe-"

    /// Writes a one-byte file in `folder`, syncs it, reads what it took and whether a
    /// `._` companion came with it, then removes both. Nothing is left behind, and a
    /// folder that can't be written to gives an empty result rather than an error.
    /// `readingBlocks: false` skips the file's block count, for a test of the
    /// free-space measure on a drive that has one.
    public static func probe(at folder: URL) -> DriveAllocation { probe(at: folder, readingBlocks: true) }

    static func probe(at folder: URL, readingBlocks: Bool) -> DriveAllocation {
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
        let blocks: UInt64? = readingBlocks && fstat(fd, &st) == 0 && st.st_blocks > 0 ? UInt64(st.st_blocks) * 512 : nil
        let unit = blocks ?? unitByGrowing(fd)
        close(fd)
        let companion = listxattr(file.path, nil, 0, XATTR_NOFOLLOW) != 0 || access(companionPath, F_OK) == 0
        return DriveAllocation(allocationUnit: unit, companion: companion)
    }

    /// The unit the drive gives the open file `fd` (one byte long, synced), from the
    /// drive's free space: the file is lengthened to 513 bytes, then 1025, and so on,
    /// synced each time, until the free space drops. A file one byte past a unit takes
    /// two, so the first drop is one unit, and its size is where it came. Anything
    /// else (the free space moving for another reason, the drive refusing the write)
    /// measures nothing. Measured on macOS 27's exFAT and FAT32: 131072 and 512, the
    /// sizes the drives were made with.
    static func unitByGrowing(_ fd: Int32) -> UInt64? {
        func free() -> UInt64? {
            var s = statfs()
            return fstatfs(fd, &s) == 0 && s.f_bsize > 0 ? UInt64(s.f_bfree) * UInt64(s.f_bsize) : nil
        }
        guard let before = free() else { return nil }
        var size: UInt64 = 512
        while size <= largestUnit {
            guard pwrite(fd, "x", 1, off_t(size)) == 1, fsync(fd) == 0, let now = free() else { return nil }
            if now != before { return now < before && before - now == size ? size : nil }
            size *= 2
        }
        return nil
    }

    /// The drive's allocation unit. On exFAT and FAT, what the probe measured, as
    /// statfs can't be trusted there (512 on macOS 15 whatever the cluster); with no
    /// measurement, the larger of statfs and the largest cluster the format commonly
    /// uses (128 KiB for exFAT, 32 KiB for FAT32), so room is never underestimated.
    /// Elsewhere, the larger of statfs and the measurement.
    public static func cluster(statfsBlockSize: UInt64?, fsType: String, probed: DriveAllocation) -> UInt64 {
        let fallback: UInt64? = fsType == "exfat" ? conservativeExFATCluster : fsType == "msdos" ? conservativeFAT32Cluster : nil
        switch (probed.allocationUnit, fallback) {
        case let (unit?, _?): return max(unit, 512)
        case let (unit?, nil): return max(statfsBlockSize ?? 0, unit, 512)
        case let (nil, fallback?): return max(statfsBlockSize ?? 0, fallback)
        case (nil, nil): return max(statfsBlockSize ?? 4096, 512)
        }
    }
}
