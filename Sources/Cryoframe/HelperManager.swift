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
