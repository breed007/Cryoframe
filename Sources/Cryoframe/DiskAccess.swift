//
//  DiskAccess.swift
//  Cryoframe (app)
//
//  Full Disk Access is probed in the Kit (FullDiskAccess); this opens the
//  System Settings pane that grants it.
//

import Foundation
import AppKit
import CryoframeKit

enum DiskAccess {
    /// shown wherever Full Disk Access can't be confirmed either way.
    static let unknownNote = "Can't confirm Full Disk Access on this macOS. Cryoframe will report it if a backup can't read a library."

    static func status() -> FullDiskAccess.Status { FullDiskAccess.status() }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }
}
