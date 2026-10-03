//
//  QuitPlan.swift
//  CryoframeKit
//
//  What the app does with a quit while something runs (see QuitGuard in the app):
//  ask, stop what can be stopped, and quit once nothing is left. The app cancels the
//  quit and asks for it again itself, so whatever ends the work has to lead back to a
//  quit, or the app stays open with nothing left to do.
//
//  That happened in 1.7: the question stayed up while the run finished on its own, so
//  "Stop and Quit" had nothing to stop, and nothing that ends would ever ask for the
//  quit again. The answer is now judged against what is running when it is given,
//  and the app looks again every second as well as when work ends. A stop that never
//  finishes is given `stopLimit`; a restore, which can't be stopped part way, is
//  waited for however long it takes.
//

import Foundation

/// what is under way when the app is asked to quit
public struct QuitWork: Equatable, Sendable {
    public var backups: Int
    public var checks: Int
    public var exports: Int
    public var restores: Int

    public init(backups: Int = 0, checks: Int = 0, exports: Int = 0, restores: Int = 0) {
        self.backups = backups; self.checks = checks; self.exports = exports; self.restores = restores
    }

    public var isEmpty: Bool { backups == 0 && checks == 0 && exports == 0 && restores == 0 }

    /// only restores, which can't be stopped part way: the app waits for them
    public var onlyRestores: Bool { restores > 0 && backups == 0 && checks == 0 && exports == 0 }

    /// "A backup and an export", for the question, and whether it is more than one
    public var described: (text: String, plural: Bool) {
        var parts: [String] = []
        func add(_ n: Int, _ one: String, _ many: String) {
            if n == 1 { parts.append(one) } else if n > 1 { parts.append(many) }
        }
        add(backups, "a backup", "backups")
        add(checks, "a check of your backups", "checks of your backups")
        add(exports, "an export", "exports")
        add(restores, "a restore", "restores")
        guard let last = parts.last else { return ("Nothing", false) }
        let text = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " and " + last : last
        let plural = parts.count > 1 || !(last.hasPrefix("a ") || last.hasPrefix("an "))
        return (text.prefix(1).uppercased() + text.dropFirst(), plural)
    }
}

/// The quit the person asked for, from the question to the moment the app may go.
public struct QuitPlan: Sendable {
    /// how long a stop may take before the app quits anyway: a run that stops ends its
    /// tool at once and tidies up in seconds; one that hasn't after this never will
    public static let stopLimit: TimeInterval = 60

    /// when the person chose to stop and quit; nil: they haven't
    public private(set) var stoppingSince: Date?
    /// the app has decided to quit: the quit it asks for goes ahead without a question
    public private(set) var releasing = false

    public init() {}

    public var isStopping: Bool { stoppingSince != nil }

    /// What a quit request gets.
    public enum Request: Equatable, Sendable {
        /// nothing is running, or the app is already on its way out
        case quitNow
        /// a logout, restart or shutdown: stop everything and quit without asking
        case stopForSystem
        /// ask whether to stop and quit
        case ask
        /// asked again while things stop: offer to quit at once
        case askWhileStopping
    }

    public func request(_ work: QuitWork, system: Bool) -> Request {
        if releasing || work.isEmpty { return .quitNow }
        if system { return .stopForSystem }
        return isStopping ? .askWhileStopping : .ask
    }

    /// The person chose to stop and quit (or a logout did). Judged against what runs
    /// now, not when the question went up: true when nothing is left, and the app
    /// quits at once.
    public mutating func stop(_ work: QuitWork, now: Date) -> Bool {
        if stoppingSince == nil { stoppingSince = now }
        if work.isEmpty { releasing = true }
        return releasing
    }

    /// What a look at the work, when some ends and every second, comes to.
    public enum Check: Equatable, Sendable {
        /// keep waiting (or no quit was asked for)
        case wait
        /// nothing is left: quit
        case quit
        /// a stop has taken longer than `stopLimit`: quit anyway, and say so
        case quitAfterLimit
    }

    public mutating func check(_ work: QuitWork, now: Date) -> Check {
        guard let since = stoppingSince else { return .wait }
        if releasing || work.isEmpty { releasing = true; return .quit }
        // a restore is waited for: cut off, it leaves the library half moved
        guard work.restores == 0, now.timeIntervalSince(since) >= Self.stopLimit else { return .wait }
        releasing = true
        return .quitAfterLimit
    }
}
