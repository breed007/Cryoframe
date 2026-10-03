//
//  QuitPlanTests.swift
//  CryoframeKitTests
//
//  Quitting while something runs (see QuitPlan): the app asks, stops what can be
//  stopped, and quits once nothing is left, however the work ended.
//

import Testing
import Foundation
@testable import CryoframeKit

@Suite struct QuitPlanTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    let backup = QuitWork(backups: 1)

    @Test func nothingRunningQuitsAtOnce() {
        #expect(QuitPlan().request(QuitWork(), system: false) == .quitNow)
        #expect(QuitPlan().request(QuitWork(), system: true) == .quitNow)
    }

    @Test func aRunningBackupAsksAndALogoutDoesNot() {
        #expect(QuitPlan().request(backup, system: false) == .ask)
        #expect(QuitPlan().request(backup, system: true) == .stopForSystem)
    }

    // The 1.7 bug: the question stayed up while the run finished on its own, "Stop and
    // Quit" found nothing to stop, and the app never quit.
    @Test func workThatEndedWhileTheQuestionWasUpQuitsAtOnce() {
        var plan = QuitPlan()
        #expect(plan.request(backup, system: false) == .ask)
        let r1 = plan.stop(QuitWork(), now: t0)
        #expect(r1)
        #expect(plan.request(QuitWork(), system: false) == .quitNow)
    }

    @Test func aStoppedRunQuitsWhenItHasEnded() {
        var plan = QuitPlan()
        let r2 = plan.stop(backup, now: t0)
        #expect(!r2)
        let r3 = plan.check(backup, now: t0.addingTimeInterval(5))
        #expect(r3 == .wait)
        #expect(plan.request(backup, system: false) == .askWhileStopping)
        let r4 = plan.check(QuitWork(), now: t0.addingTimeInterval(6))
        #expect(r4 == .quit)
        // the quit the app then asks for goes ahead without a question
        #expect(plan.request(QuitWork(), system: false) == .quitNow)
    }

    @Test func aStopThatNeverEndsQuitsAfterTheLimit() {
        var plan = QuitPlan()
        _ = plan.stop(QuitWork(backups: 1, exports: 1), now: t0)
        let r5 = plan.check(backup, now: t0.addingTimeInterval(QuitPlan.stopLimit - 1))
        #expect(r5 == .wait)
        let r6 = plan.check(backup, now: t0.addingTimeInterval(QuitPlan.stopLimit))
        #expect(r6 == .quitAfterLimit)
        // still running, but the app has decided: no second question
        #expect(plan.request(backup, system: false) == .quitNow)
    }

    @Test func aRestoreIsWaitedForPastTheLimit() {
        var plan = QuitPlan()
        let restoring = QuitWork(backups: 1, restores: 1)
        _ = plan.stop(restoring, now: t0)
        let r7 = plan.check(restoring, now: t0.addingTimeInterval(10 * QuitPlan.stopLimit))
        #expect(r7 == .wait)
        // once it has finished, a backup that still hasn't stopped no longer holds the quit
        let r8 = plan.check(backup, now: t0.addingTimeInterval(10 * QuitPlan.stopLimit))
        #expect(r8 == .quitAfterLimit)
    }

    @Test func noQuitAskedForNeverQuits() {
        var plan = QuitPlan()
        let r9 = plan.check(QuitWork(), now: t0)
        #expect(r9 == .wait)
        let r10 = plan.check(backup, now: t0.addingTimeInterval(3600))
        #expect(r10 == .wait)
    }

    @Test func theQuestionNamesWhatRuns() {
        #expect(QuitWork(backups: 1).described == ("A backup", false))
        #expect(QuitWork(backups: 2).described == ("Backups", true))
        #expect(QuitWork(exports: 1).described == ("An export", false))
        #expect(QuitWork(backups: 1, exports: 1).described == ("A backup and an export", true))
        #expect(QuitWork(backups: 1, checks: 2, restores: 1).described == ("A backup, checks of your backups and a restore", true))
        #expect(QuitWork(restores: 1).onlyRestores)
        #expect(!QuitWork(backups: 1, restores: 1).onlyRestores)
    }
}
