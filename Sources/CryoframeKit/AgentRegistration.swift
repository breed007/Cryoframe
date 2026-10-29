//
//  AgentRegistration.swift
//  CryoframeKit
//
//  Moving the schedule to the agent definition this version ships. launchd keeps the
//  definition it was given when the agent was registered, and registering the same
//  plist again only answers "already registered" (SMAppService.h), so an install
//  that registered 1.7's agent would keep 1.7's hourly interval after an update, and
//  miss the runs a wake was set for. The agent now has a new plist name; the app
//  registers it at launch in place of the old one, and then retires the old one.
//
//  Retiring an agent kills a pass of it that is running (SMAppService.h), so the old
//  one is retired only when no pass is: none holds the pass lock, and no job's run
//  lock is held by another process. Until then, a pass the old definition starts
//  ends at once, because the new one does the work.
//

import Foundation

public enum AgentRegistration {
    /// the agent definition this version ships, in Contents/Library/LaunchAgents
    public static let currentPlist = "app.cryoframe.agent.v2.plist"
    public static let currentLabel = "app.cryoframe.agent.v2"
    /// the one 1.7 and earlier registered, kept in the bundle so it can be retired
    public static let legacyPlist = "app.cryoframe.agent.plist"
    public static let legacyLabel = "app.cryoframe.agent"

    /// what SMAppService says of a definition
    public enum State: Sendable, Equatable { case enabled, awaitingApproval, notRegistered }

    public enum Step: Sendable, Equatable {
        /// nothing to do: the old definition isn't registered, or the user has the
        /// schedule switched off in System Settings
        case none
        /// the schedule is on under the old definition: register the new one
        case registerCurrent
        /// the new one is enabled, and a pass is running: retire the old one later
        case waitForPasses
        /// the new one is enabled and nothing is running: unregister the old one
        case retireLegacy
    }

    /// The next step of the move. Only a schedule the user has on is moved: an old
    /// definition switched off in System Settings is left as it is, as is one that
    /// isn't registered at all, so the move never turns a schedule on.
    public static func nextStep(current: State, legacy: State, passesRunning: Bool) -> Step {
        guard legacy != .notRegistered else { return .none }
        switch current {
        case .enabled: return passesRunning ? .waitForPasses : .retireLegacy
        case .notRegistered: return legacy == .enabled ? .registerCurrent : .none
        case .awaitingApproval: return .none
        }
    }

    /// Whether a pass launchd started should do its work. `launchedAs` is the label
    /// launchd gave it (XPC_SERVICE_NAME). One the old definition started does nothing
    /// once the new one is enabled, so the two never both run the schedule; one started
    /// any other way (by hand, with no label) runs.
    public static func passShouldRun(launchedAs label: String?, currentEnabled: Bool) -> Bool {
        !(label == legacyLabel && currentEnabled)
    }
}

/// Held by a pass of the scheduled agent for as long as it runs, so the app can tell
/// whether retiring an agent definition would kill one. An flock(2), so a pass that
/// crashes lets go of it.
public enum AgentPassLock {
    public static func standardURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.cryoframe", isDirectory: true)
            .appendingPathComponent("agent-pass.lock")
    }

    /// Take a shared hold for the rest of the process (passes may overlap), or -1 when
    /// the lock file can't be opened. The pass runs either way.
    @discardableResult
    public static func hold(at url: URL = standardURL()) -> Int32 {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return -1 }
        // blocking: the app holds it only for the moment it takes to look
        guard flock(fd, LOCK_SH) == 0 else { close(fd); return -1 }
        return fd
    }

    /// Whether a pass holds it. One that can't be told (the file can't be opened, but
    /// is there) counts as held, so the old definition is kept rather than a pass killed.
    public static func isHeld(at url: URL = standardURL()) -> Bool {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return errno != ENOENT }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return true }
        flock(fd, LOCK_UN)
        return false
    }
}
