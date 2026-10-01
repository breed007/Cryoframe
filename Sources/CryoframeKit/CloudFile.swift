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

    /// Whether any of `archive`'s own files, the artifacts its manifest names, is a
    /// placeholder. Not its whole folder: a version's file list (see ContentsListing)
    /// evicted on its own made a version on this Mac read "not downloaded, skipped".
    public static func anyDataless(of archive: RestorableArchive) -> Bool {
        archive.archiveResult().artifacts.contains { anyDataless(in: $0) }
    }

    /// the same, downloading: only the artifacts, never the file list beside them
    public static func materialize(_ archive: RestorableArchive) {
        archive.archiveResult().artifacts.forEach { materialize($0) }
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

/// Bringing an evicted archive down from its cloud provider before a tool reads it.
///
/// A dataless file is fetched when something first reads it, and until then the
/// reader waits. When that reader was hdiutil or ditto, the wait happened inside the
/// tool, which shows no CPU, disk activity or output while the provider downloads,
/// so the tool watchdog stopped a restore of a large archive part-way (about 11 GB
/// fits in 15 minutes at 100 Mbps). The drill and the checks already download first;
/// opening an archive (restore, verification, rehearsal) now does too, here, where
/// the download itself is watched: the bytes on disk growing, or the provider
/// saying it is downloading, is progress.
public struct CloudDownload: Sendable {
    /// whether the archive (a file, or a folder of parts or bands) is evicted
    public let isEvicted: @Sendable (URL) -> Bool
    /// fetch it; returns when it is local
    public let fetch: @Sendable (URL) -> Void
    /// a figure that moves while it downloads (bytes on disk, the provider's word)
    public let progress: @Sendable (URL) -> UInt64

    public init(isEvicted: @escaping @Sendable (URL) -> Bool, fetch: @escaping @Sendable (URL) -> Void,
                progress: @escaping @Sendable (URL) -> UInt64) {
        self.isEvicted = isEvicted; self.fetch = fetch; self.progress = progress
    }

    public static let system = CloudDownload(
        isEvicted: { CloudFile.anyDataless(in: $0) },
        fetch: { CloudFile.materialize($0) },
        progress: { url in
            var total: UInt64 = 0
            let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .ubiquitousItemIsDownloadingKey]
            func add(_ u: URL) {
                let v = try? u.resourceValues(forKeys: keys)
                total &+= UInt64(v?.totalFileAllocatedSize ?? 0)
                if v?.ubiquitousItemIsDownloading == true { total &+= UInt64(Date().timeIntervalSince1970 * 1000) }   // alive
            }
            add(url)
            if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) {
                for case let f as URL in e { add(f) }
            }
            return total
        })

    /// Fetch each evicted artifact, stopping if the download shows no progress for
    /// `quietLimit` seconds, or at once on Stop. The fetch runs on its own thread: a
    /// read of a dataless file can't be interrupted, so a stopped or stalled one is
    /// left to finish (or fail) on its own.
    public func bringDown(_ artifacts: [URL], quietLimit: TimeInterval, control: RunControl?) throws {
        for url in artifacts where isEvicted(url) {
            let done = DispatchSemaphore(value: 0)
            let fetch = self.fetch
            Thread.detachNewThread { fetch(url); done.signal() }
            let clock = { ProcessInfo.processInfo.systemUptime }
            var quietSince = clock(), last = progress(url)
            let tick = min(1, max(0.02, quietLimit / 10))
            while done.wait(timeout: .now() + tick) == .timedOut {
                if control?.isCancelled == true { throw CancelledError() }
                let now = progress(url)
                if now != last { last = now; quietSince = clock(); continue }
                if clock() - quietSince >= quietLimit { throw CloudDownloadStalled(path: url.path, quiet: clock() - quietSince) }
            }
            // The fetch has returned, but that doesn't mean the archive came down: offline,
            // or refused by the provider, it is still a placeholder, and the open went on
            // to hand it to hdiutil or ditto, which then failed with a message about the
            // image or waited on the download themselves. iCloud's download can also
            // still be finishing after the kick returns, so it is given until it goes
            // quiet (a few seconds at most) before the archive is called not downloaded.
            let grace = min(quietLimit, Self.settleLimit)
            quietSince = clock(); last = progress(url)
            while isEvicted(url) {
                if control?.isCancelled == true { throw CancelledError() }
                if clock() - quietSince >= grace { throw CloudDownloadIncomplete(path: url.path) }
                Thread.sleep(forTimeInterval: tick)
                let now = progress(url)
                if now != last { last = now; quietSince = clock() }
            }
        }
    }

    /// how long a fetch that has returned may go without progress while the archive
    /// is still evicted, before it is called not downloaded
    static let settleLimit: TimeInterval = 5
}

/// An evicted archive the cloud provider didn't bring down: the fetch finished and
/// the archive is still a placeholder (offline, or the provider refused).
public struct CloudDownloadIncomplete: Error, Equatable {
    public let path: String
}

extension CloudDownloadIncomplete: LocalizedError {
    public var errorDescription: String? {
        "this archive is in a cloud folder and the cloud copy couldn't be downloaded to this Mac. Check that you're online and signed in to the cloud service, and that the file is still in the cloud folder, then try again."
    }
}

/// An evicted archive whose download made no progress.
public struct CloudDownloadStalled: Error, Equatable {
    public let path: String
    public let quiet: TimeInterval
}

extension CloudDownloadStalled: LocalizedError {
    public var errorDescription: String? {
        let minutes = Int((quiet / 60).rounded())
        return "this archive is in a cloud folder and isn't on this Mac, and downloading it made no progress for \(quiet >= 90 ? "\(minutes) minutes" : "\(Int(quiet.rounded())) seconds"). Check the internet connection and that the cloud service is running, then try again."
    }
}

