//
//  ScheduleManager.swift
//  Cryoframe (app)
//
//  Registers the GUI-side schedule as an SMAppService LaunchAgent. Once enabled,
//  launchd wakes the agent on its interval to run due jobs (AgentMain).
//
//  An install from 1.7 or earlier has the old agent definition registered, and
//  launchd keeps what it was given then. At launch, and while a pass of the old one
//  holds things up, the app moves the schedule to this version's definition (see
//  AgentRegistration). The helper daemon is never unregistered here or anywhere: it
//  reloads through reloadForUpdate (HelperManager).
//

import Foundation
import ServiceManagement
import CryoframeKit

@MainActor
final class ScheduleManager: ObservableObject {
    @Published private(set) var statusText: String = "—"

    private let service = SMAppService.agent(plistName: AgentRegistration.currentPlist)
    private let legacy = SMAppService.agent(plistName: AgentRegistration.legacyPlist)
    private var moved = false

    init() { refresh() }

    /// on under either definition: during the move, the old one is still the schedule
    var isEnabled: Bool { service.status == .enabled || legacy.status == .enabled }

    func refresh() {
        let unmoved = Self.state(service.status) == .notRegistered && Self.state(legacy.status) != .notRegistered
        statusText = HelperManager.describe(unmoved ? legacy.status : service.status)
    }

    func register() throws { try service.register(); refresh() }

    /// switched off in Settings: both definitions, so the old one doesn't carry on
    func unregister() throws {
        if Self.state(legacy.status) != .notRegistered { try? legacy.unregister() }
        if Self.state(service.status) != .notRegistered { try service.unregister() }
        refresh()
    }

    /// Move a schedule registered by 1.7 or earlier to this version's agent, a step at
    /// a time (see AgentRegistration.nextStep). `otherRunsActive`: whether a job's run
    /// lock is held by another process, perhaps a pass of the old agent, which holds no
    /// pass lock. Cheap once done: the move is remembered for this launch.
    func moveToCurrentAgent(otherRunsActive: () -> Bool) {
        guard !moved else { return }
        for _ in 0..<2 {
            let passes = AgentPassLock.isHeld() || otherRunsActive()
            switch AgentRegistration.nextStep(current: Self.state(service.status), legacy: Self.state(legacy.status),
                                              passesRunning: passes) {
            case .none: moved = true; refresh(); return
            case .waitForPasses: return
            case .registerCurrent:
                do { try service.register() } catch { refresh(); return }    // the old one stays the schedule
            case .retireLegacy:
                try? legacy.unregister()
                moved = Self.state(legacy.status) == .notRegistered
                refresh(); return
            }
        }
        refresh()
    }

    private static func state(_ status: SMAppService.Status) -> AgentRegistration.State {
        switch status {
        case .enabled: return .enabled
        case .requiresApproval: return .awaitingApproval
        default: return .notRegistered     // not registered, or not found
        }
    }
}
