//
//  DiskAccess.swift
//  Cryoframe (app)
//
//  There's no API to query Full Disk Access, so we probe it: the per-user TCC
//  database is readable only by a process that holds FDA. A successful read ⇒
//  granted; "Operation not permitted" ⇒ not granted.
//
//  Note: TCC evaluates a process's grant at launch, so a freshly granted FDA may
//  not take effect until Cryoframe is relaunched.
//

import Foundation
import AppKit

enum DiskAccess {
    static func hasFullDiskAccess() -> Bool {
        let path = ("~/Library/Application Support/com.apple.TCC/TCC.db" as NSString).expandingTildeInPath
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 1)) != nil
    }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }
}
