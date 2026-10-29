//
//  AgentRegistrationTests.swift
//  CryoframeKitTests
//
//  Moving a schedule registered by 1.7 or earlier to this version's agent
//  definition. launchd itself isn't touched here: these pin the decisions, and that
//  the plists in the bundle are the ones the code names.
//

import Testing
import Foundation
@testable import CryoframeKit

@Suite struct AgentRegistrationTests {
    typealias S = AgentRegistration.State

    @Test func aScheduleOnUnderTheOldAgentIsMovedThenTheOldOneRetired() {
        #expect(AgentRegistration.nextStep(current: .notRegistered, legacy: .enabled, passesRunning: false) == .registerCurrent)
        #expect(AgentRegistration.nextStep(current: .notRegistered, legacy: .enabled, passesRunning: true) == .registerCurrent)
        #expect(AgentRegistration.nextStep(current: .enabled, legacy: .enabled, passesRunning: false) == .retireLegacy)
    }

    @Test func theOldAgentIsNeverRetiredUnderARunningPass() {
        // retiring an agent kills a pass of it that is running
        for legacy in [S.enabled, .awaitingApproval] {
            #expect(AgentRegistration.nextStep(current: .enabled, legacy: legacy, passesRunning: true) == .waitForPasses)
        }
    }

    @Test func theMoveNeverTurnsAScheduleOn() {
        // never registered, or switched off in System Settings: left as it is
        #expect(AgentRegistration.nextStep(current: .notRegistered, legacy: .notRegistered, passesRunning: false) == .none)
        #expect(AgentRegistration.nextStep(current: .notRegistered, legacy: .awaitingApproval, passesRunning: false) == .none)
        // already moved
        #expect(AgentRegistration.nextStep(current: .enabled, legacy: .notRegistered, passesRunning: true) == .none)
        #expect(AgentRegistration.nextStep(current: .awaitingApproval, legacy: .notRegistered, passesRunning: false) == .none)
        // the new one is waiting for approval: the old one stays the schedule
        #expect(AgentRegistration.nextStep(current: .awaitingApproval, legacy: .enabled, passesRunning: false) == .none)
    }

    @Test func aPassTheOldAgentStartsEndsOnceTheNewOneIsOn() {
        let old = AgentRegistration.legacyLabel, new = AgentRegistration.currentLabel
        #expect(!AgentRegistration.passShouldRun(launchedAs: old, currentEnabled: true))
        #expect(AgentRegistration.passShouldRun(launchedAs: old, currentEnabled: false))       // not moved yet: it is the schedule
        #expect(AgentRegistration.passShouldRun(launchedAs: new, currentEnabled: true))
        #expect(AgentRegistration.passShouldRun(launchedAs: nil, currentEnabled: true))        // started by hand
    }

    @Test func theBundleShipsBothDefinitionsUnderTheirNames() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for (name, label) in [(AgentRegistration.currentPlist, AgentRegistration.currentLabel),
                              (AgentRegistration.legacyPlist, AgentRegistration.legacyLabel)] {
            let data = try Data(contentsOf: root.appendingPathComponent("Sources/Cryoframe/" + name))
            let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
            #expect(plist["Label"] as? String == label)
            #expect(name == label + ".plist")
        }
        let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        for name in [AgentRegistration.currentPlist, AgentRegistration.legacyPlist] {
            #expect(project.contains("cp \"${SRCROOT}/Sources/Cryoframe/\(name)\" \"$DEST/\""), "\(name) isn't embedded")
        }
    }

    @Test func thePassLockShowsAPassRunningAndLetsGoWhenItEnds() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cf-pass-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("agent-pass.lock")
        #expect(!AgentPassLock.isHeld(at: url))                  // no file: no pass has run
        let first = AgentPassLock.hold(at: url), second = AgentPassLock.hold(at: url)
        #expect(first >= 0 && second >= 0)                       // passes may overlap
        #expect(AgentPassLock.isHeld(at: url))
        close(first)
        #expect(AgentPassLock.isHeld(at: url))
        close(second)                                            // as when the pass exits
        #expect(!AgentPassLock.isHeld(at: url))
    }
}
