//
//  WorkspaceProcessDetector.swift
//  Cryoframe (app)
//
//  Real ProcessDetector over NSWorkspace. App-side so CryoframeKit stays AppKit-free.
//

import AppKit
import CryoframeKit

struct WorkspaceProcessDetector: ProcessDetector {
    func isRunning(_ owner: OwningProcess) -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            if let b = owner.bundleIdentifier, app.bundleIdentifier == b { return true }
            if let e = owner.executableName, app.executableURL?.lastPathComponent == e { return true }
            return false
        }
    }
}
