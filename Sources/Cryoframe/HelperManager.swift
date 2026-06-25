//
//  HelperManager.swift
//  Cryoframe (app)
//
//  Registers / checks the root LaunchDaemon via SMAppService. First registration
//  requires the user to approve a background item and authenticate (root install).
//

import Foundation
import ServiceManagement
import CryoframeShared

@MainActor
final class HelperManager: ObservableObject {
    @Published private(set) var statusText: String = "—"

    private let service = SMAppService.daemon(plistName: CryoframeHelper.daemonPlistName)

    init() { refresh() }

    var isEnabled: Bool { service.status == .enabled }

    func refresh() { statusText = Self.describe(service.status) }

    func register() throws {
        try service.register()
        refresh()
    }

    func unregister() throws {
        try service.unregister()
        refresh()
    }

    /// After an app update the resident on-demand daemon keeps running the OLD
    /// helper binary — it never exits, so launchd never respawns it, and fixes in
    /// the helper (e.g. snapshot unmount) don't take effect until reboot. Detect a
    /// newer embedded binary by mtime and ask the daemon to exit; launchd respawns
    /// the new binary on the next connection, with no re-approval.
    ///
    /// Only the clean self-exit path is used. A helper predating `reloadForUpdate`
    /// (e.g. 0.2.0) just errors and keeps running its old code until the next
    /// reboot — we never `unregister`, which would force the user to re-approve the
    /// background item. Runs at launch only, when no job is in flight; the build
    /// stamp makes it a no-op once the current binary has been handled.
    func reloadIfStale() async {
        guard isEnabled else { return }
        let binPath = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/CryoframeHelper").path
        guard let mtime = (try? FileManager.default.attributesOfItem(atPath: binPath)[.modificationDate]) as? Date
        else { return }
        let stamp = mtime.timeIntervalSince1970
        let key = "helper.reloadedForBuild"
        if abs(UserDefaults.standard.double(forKey: key) - stamp) <= 1 { return }   // already current

        let xpc = XPCPrivilegedHelper()
        try? await xpc.reloadForUpdate()   // self-exit → launchd respawns new binary; old helpers no-op
        xpc.invalidate()
        UserDefaults.standard.set(stamp, forKey: key)   // handled this binary either way
        refresh()
    }

    static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered:    return "not registered"
        case .enabled:          return "enabled"
        case .requiresApproval: return "requires approval — System Settings ▸ General ▸ Login Items"
        case .notFound:         return "not found"
        @unknown default:       return "unknown"
        }
    }
}
