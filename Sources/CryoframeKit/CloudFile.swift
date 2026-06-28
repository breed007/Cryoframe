//
//  CloudFile.swift
//  CryoframeKit
//
//  Detecting whether a file in a cloud-sync folder is actually present locally or has
//  been evicted to a dataless placeholder (Dropbox Smart Sync / OneDrive Files
//  On-Demand / Google Drive streaming). Reading a placeholder silently re-downloads
//  it — fine for a restore (you asked for the data), a surprise for a scheduled health
//  check. So health/drill detect placeholders and skip them unless told to download.
//

import Foundation

public enum CloudFile {
    private static let SF_DATALESS: UInt32 = 0x4000_0000   // <sys/stat.h>: per-file "this is a placeholder" bit

    /// a regular file that's a placeholder: the dataless flag is set, or it's
    /// structurally hollow (logical size large, almost nothing actually on disk). A
    /// sealed archive is never legitimately sparse, so hollow ⇒ evicted in practice.
    public static func isDataless(_ url: URL) -> Bool {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return false }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return directoryIsHollow(url) }
        if (st.st_flags & SF_DATALESS) != 0 { return true }
        let logical = UInt64(st.st_size), onDisk = UInt64(st.st_blocks) * 512
        return logical > 1_000_000 && onDisk < logical / 10
    }

    /// an archive directory (its split parts, or a sparsebundle's bands) is dataless if
    /// any regular file inside is a placeholder. Bounded: a sealed archive has a handful
    /// of files, but a sparsebundle has thousands of bands — a sample catches an eviction
    /// without stat-walking the whole thing on every scheduled check.
    public static func anyDataless(in dir: URL, sampleLimit: Int = 256) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir) else { return false }
        if !isDir.boolValue { return isDataless(dir) }
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return false }
        var scanned = 0
        for case let f as URL in e {
            guard (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            if isDataless(f) { return true }
            scanned += 1
            if scanned >= sampleLimit { break }
        }
        return false
    }

    /// best-effort download of a placeholder so a subsequent read is local. iCloud gets
    /// an explicit kick; the file providers fault the data in on a coordinated read.
    public static func materialize(_ url: URL) {
        let fm = FileManager.default
        if (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true {
            try? fm.startDownloadingUbiquitousItem(at: url)
        }
        var isDir: ObjCBool = false
        fm.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) {
                for case let f as URL in e where (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                    faultIn(f)
                }
            }
        } else {
            faultIn(url)
        }
    }

    private static func faultIn(_ url: URL) {
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { u in
            if let fh = try? FileHandle(forReadingFrom: u) { _ = try? fh.read(upToCount: 1); try? fh.close() }
        }
    }

    private static func directoryIsHollow(_ dir: URL) -> Bool {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey]) else { return false }
        var logical: UInt64 = 0, onDisk: UInt64 = 0
        for case let f as URL in e {
            guard let v = try? f.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey]),
                  v.isRegularFile == true else { continue }
            logical += UInt64(v.fileSize ?? 0)
            onDisk += UInt64(v.totalFileAllocatedSize ?? 0)
        }
        return logical > 1_000_000 && onDisk < logical / 10
    }
}
