//
//  TempTracker.swift
//  CryoframeKitTests
//
//  Temporary files and folders some older tests make without removing, removed
//  when the test process exits. Swift Testing has no teardown for free test
//  functions, and a few hundred were left in $TMPDIR by every full run.
//

import Foundation

enum TempTracker {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var tracked: [URL] = []
    nonisolated(unsafe) private static var registered = false

    /// remember `url` for removal at exit; returns it
    @discardableResult
    static func track(_ url: URL) -> URL {
        lock.lock(); defer { lock.unlock() }
        tracked.append(url)
        if !registered {
            registered = true
            atexit { TempTracker.removeAll() }
        }
        return url
    }

    static func removeAll() {
        lock.lock(); let all = tracked; tracked = []; lock.unlock()
        // never remove into something still mounted there
        let mounts = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? [])
            .map { $0.resolvingSymlinksInPath().path }
        for u in all {
            let path = u.resolvingSymlinksInPath().path
            if mounts.contains(where: { $0 == path || $0.hasPrefix(path + "/") }) { continue }
            try? FileManager.default.removeItem(at: u)
        }
    }
}
