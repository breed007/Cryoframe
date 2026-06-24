//
//  ScheduleManager.swift
//  Cryoframe (app)
//
//  Registers the GUI-side schedule as an SMAppService LaunchAgent. Once enabled,
//  launchd wakes the agent on its interval to run due jobs (AgentMain).
//

import Foundation
import ServiceManagement

@MainActor
final class ScheduleManager: ObservableObject {
    @Published private(set) var statusText: String = "—"

    private let service = SMAppService.agent(plistName: "app.cryoframe.agent.plist")

    init() { refresh() }

    var isEnabled: Bool { service.status == .enabled }

    func refresh() { statusText = HelperManager.describe(service.status) }
    func register() throws { try service.register(); refresh() }
    func unregister() throws { try service.unregister(); refresh() }
}
