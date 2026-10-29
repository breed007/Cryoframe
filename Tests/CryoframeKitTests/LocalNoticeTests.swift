//
//  LocalNoticeTests.swift
//  CryoframeKitTests
//
//  The notices on this Mac, which the app posts while it runs and the scheduled
//  agent posts when it isn't open: what each says, when one is posted at all, and
//  the overdue ledger the two share, so a notice is posted once whichever looks.
//

import Testing
import Foundation
@testable import CryoframeKit

private let t = Target.localVolume(id: "t", name: "Backup", dir: URL(fileURLWithPath: "/Volumes/Backup"))
private let job = BackupJob(id: "j", name: "Photos nightly", libraries: [], targets: [t],
                            format: .liveMirror(sizeGB: 0), frequency: .manual, verification: .checksumOnly,
                            runPolicy: .proceed, createdAt: Date(timeIntervalSince1970: 0))
private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func record(_ outcome: RunOutcomeKind, summary: String = "1 library archived", warning: String? = nil) -> RunRecord {
    RunRecord(id: "r1", jobID: job.id, jobName: job.name, startedAt: now, finishedAt: now, trigger: "scheduled",
              outcome: outcome, summary: summary, libraries: [], bytes: 0, warning: warning)
}

private func mirrored(_ reports: [BandCheckReport], warning: String? = nil) -> RunRecord {
    RunRecord.make(job: job, outcome: .finished(results: [.completed(library: "Photos", destination: "Backup", parts: 1,
                                                                     bytes: 10, verified: true)], warning: warning),
                   startedAt: now, finishedAt: now, trigger: "scheduled", id: "r2", bandChecks: reports)
}

private func health(checked: Int, failures: [String] = [], skipped: Int = 0) -> HealthRecord {
    HealthRecord(id: "h1", jobID: job.id, jobName: job.name, checkedAt: now, archivesChecked: checked,
                 failures: failures, skipped: skipped, trigger: "scheduled")
}

@Suite struct LocalNoticeTests {

    // MARK: whether the agent posts

    @Test func theAgentPostsOnlyWhenAllowedAndTheAppIsClosed() {
        typealias A = AgentNotices.Authorization
        for auth in [A.authorized, .provisional, .denied, .notDetermined, .unknown] {
            #expect(!AgentNotices.shouldPost(appOpen: true, authorization: auth), "app open, \(auth)")
            #expect(AgentNotices.shouldPost(appOpen: false, authorization: auth) == (auth == .authorized || auth == .provisional),
                    "app closed, \(auth)")
        }
    }

    @Test func runsFollowTheSamePolicyAsTheApp() {
        let cases: [(RunOutcomeKind, NotifyPolicy, Bool)] = [
            (.failed, .never, false), (.failed, .failure, true), (.failed, .all, true),
            (.partial, .never, false), (.partial, .failure, true), (.partial, .all, true),
            (.verified, .never, false), (.verified, .failure, false), (.verified, .all, true),
            (.completed, .failure, false), (.completed, .all, true),
            (.deferred, .all, false), (.cancelled, .all, false),
        ]
        for (outcome, policy, posted) in cases {
            #expect((NoticeContent.run(record(outcome), policy: policy) != nil) == posted, "\(outcome) on \(policy)")
        }
    }

    // MARK: what a run says

    @Test func aRunsNoticeIsIdentifiedByItsRecord() throws {
        let n = try #require(NoticeContent.run(record(.failed, summary: "0/1 libraries archived, 1 failed"), policy: .failure))
        #expect(n.id == "r1")                    // the app and the agent post one notice for it, not two
        #expect(n.title == "Cryoframe — Photos nightly")
        #expect(n.body == "⚠️ 0/1 libraries archived, 1 failed")
        #expect(!n.sound)
        #expect(NoticeContent.run(record(.verified, summary: "1 library verified"), policy: .all)?.body == "✓ 1 library verified")
    }

    @Test func decayFoundFailsTheRunAndItsNoticeSaysSo() throws {
        let decayed = mirrored([BandCheckReport(library: "Photos", destination: "Backup", total: 100, checked: 3,
                                                mismatches: 2, damaged: ["1a", "1b"])])
        let n = try #require(NoticeContent.run(decayed, policy: .failure))
        #expect(n.body.hasPrefix("⚠️ "))
        #expect(n.body.contains("found decay in 2 of the mirror's data bands"))
    }

    @Test func aCheckThatCouldNotBeMadeIsToldOnlyOnEveryRun() throws {
        let unread = mirrored([BandCheckReport(library: "Photos", destination: "Backup", total: 100,
                                               error: "data band 1a couldn't be read (timed out)")])
        #expect(unread.outcome == .verified)                                  // not decay, and not a failure
        #expect(NoticeContent.run(unread, policy: .failure) == nil)
        let n = try #require(NoticeContent.run(unread, policy: .all))
        #expect(n.body.contains("the mirror couldn't be checked for decay (data band 1a couldn't be read (timed out))"))
    }

    @Test func historyRemovedForRoomFollowsOnItsOwnLine() throws {
        let day = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 12))!
        let note = try #require(MirrorHistory.roomNote([MirrorHistory.Entry(dir: URL(fileURLWithPath: "/x"), date: day, written: nil)]))
        let n = try #require(NoticeContent.run(mirrored([], warning: note), policy: .all))
        let lines = n.body.components(separatedBy: "\n")
        #expect(lines.count == 2)
        #expect(lines[1] == note)
        #expect(note.contains("to make room for the mirror itself"))
        #expect(NoticeContent.run(record(.verified, warning: ""), policy: .all)?.body.contains("\n") == false)
    }

    // MARK: checks

    @Test func healthChecksFollowTheAppsRules() throws {
        #expect(NoticeContent.health(health(checked: 3), policy: .failure, jobHasRun: true) == nil)      // clean
        #expect(NoticeContent.health(health(checked: 3), policy: .all, jobHasRun: true)?.body == "✓ 3 archives verified")
        let failed = try #require(NoticeContent.health(health(checked: 3, failures: ["Photos: checksum mismatch"]),
                                                       policy: .failure, jobHasRun: true))
        #expect(failed.id == "health-h1")
        #expect(failed.body == "⚠️ archive check failed — Photos: checksum mismatch")
        #expect(NoticeContent.health(health(checked: 3, failures: ["x"]), policy: .never, jobHasRun: true) == nil)
        // nothing found: the destination may be missing, unless the job never ran
        #expect(NoticeContent.health(health(checked: 0), policy: .failure, jobHasRun: true)?.body
                == "⚠️ no archives found to check — is the target connected?")
        #expect(NoticeContent.health(health(checked: 0), policy: .all, jobHasRun: false) == nil)
        // every copy skipped: said on every run only
        #expect(NoticeContent.health(health(checked: 0, skipped: 2), policy: .failure, jobHasRun: true) == nil)
        #expect(NoticeContent.health(health(checked: 0, skipped: 2), policy: .all, jobHasRun: true)?.body.hasPrefix("☁︎ ") == true)
    }

    @Test func aStoppedCheckIsToldOnlyForWhatItFoundFailing() throws {
        func stopped(_ failures: [String]) -> CanceledCheck {
            CanceledCheck(id: "c1", jobID: job.id, jobName: job.name, kind: "checksum", stoppedAt: now,
                          finished: 2, planned: 5, failures: failures, skipped: 0, trigger: "scheduled")
        }
        #expect(NoticeContent.stopped(stopped([]), policy: .all) == nil)
        #expect(NoticeContent.stopped(stopped(["Photos: unreadable"]), policy: .never) == nil)
        let n = try #require(NoticeContent.stopped(stopped(["Photos: unreadable"]), policy: .failure))
        #expect(n.id == "stopped-c1")
        #expect(n.body.contains("1 archive check failed before the check was stopped"))
    }

    @Test func overdueAndFullDestinationsUnlessNotificationsAreOff() throws {
        let p = AlertPolicy.Payload(title: "Cryoframe — Photos nightly is overdue", body: "⚠️ late", high: true, tags: "warning")
        #expect(NoticeContent.overdue(p, subject: "j", policy: .never, now: now) == nil)
        let late = try #require(NoticeContent.overdue(p, subject: "j", policy: .failure, now: now))
        #expect(late.title == p.title && late.body == p.body && late.sound)
        #expect(late.id == "overdue-j-1800000000")

        let full = StoragePressure.Finding(kind: .tight, jobID: job.id, jobName: job.name, destination: "Backup",
                                           free: 1_000, runBytes: 5_000_000, versionCount: 1, reclaimable: 0)
        #expect(NoticeContent.storage(full, policy: .never, now: now) == nil)
        let n = try #require(NoticeContent.storage(full, policy: .failure, now: now))
        #expect(n.title == "Cryoframe — Backup is nearly full")
        #expect(n.sound)
    }

    // MARK: the overdue ledger the app and the agent share

    @Test func twoLedgersOnOneFilePostOnce() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cf-ledger-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("overdue-notices.json")
        let app = AlertThrottle(ledgerAt: url), agent = AlertThrottle(ledgerAt: url)

        let claim = try #require(app.claim("j", now: now))
        #expect(agent.claim("j", now: now.addingTimeInterval(60)) == nil)       // the app has it
        #expect(!agent.shouldSend("j", now: now.addingTimeInterval(60)))
        #expect(agent.claim("k", now: now) != nil)                             // another job is its own

        // a notice macOS didn't take is handed back, and owed
        app.release(claim)
        #expect(agent.shouldSend("j", now: now.addingTimeInterval(60)))
        #expect(agent.claim("j", now: now.addingTimeInterval(60)) != nil)
        #expect(app.claim("j", now: now.addingTimeInterval(120)) == nil)
        // a day later, due again
        #expect(app.claim("j", now: now.addingTimeInterval(86_460)) != nil)
    }

    @Test func aReleaseDoesNotUndoALaterClaim() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cf-ledger-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = AlertThrottle(ledgerAt: dir.appendingPathComponent("l.json")), b = AlertThrottle(ledgerAt: dir.appendingPathComponent("l.json"))
        let first = try #require(a.claim("j", now: now))
        b.clear("j")                                            // a good run since
        let second = try #require(b.claim("j", now: now.addingTimeInterval(10)))
        a.release(first)                                        // late: it isn't first's any more
        #expect(b.lastSent("j") == Date(timeIntervalSince1970: now.timeIntervalSince1970 + 10))
        b.release(second)
        #expect(b.lastSent("j") == nil)
    }

    @Test func theOverduePolicyRunsOnTheSharedLedger() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cf-ledger-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("l.json")
        var hourly = job; hourly.frequency = .everyHours(1)
        // put off since the last good run three hours ago
        let latest = [job.id: RunRecord(id: "d", jobID: job.id, jobName: job.name, startedAt: now, finishedAt: now,
                                        trigger: "scheduled", outcome: .deferred, summary: "", libraries: [], bytes: 0, warning: nil)]
        let lastGood = [job.id: now.addingTimeInterval(-3 * 3600)]
        let found = AlertPolicy.overdueAlerts(jobs: [hourly], latest: latest, lastGood: lastGood, now: now,
                                              throttle: AlertThrottle(ledgerAt: url))
        let alert = try #require(found.first)
        #expect(AlertThrottle(ledgerAt: url).claim(alert.subject, now: now) != nil)
        // the other process, looking next: nothing to post
        #expect(AlertPolicy.overdueAlerts(jobs: [hourly], latest: latest, lastGood: lastGood, now: now,
                                          throttle: AlertThrottle(ledgerAt: url)).isEmpty)
    }

    // MARK: never hangs

    @Test func aCallbackThatNeverComesIsGivenUp() async {
        let started = Date()
        let value = await BoundedWait.value(within: 0.2, timedOut: false) { _ in }
        #expect(value == false)
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test func aCallbackInTimeIsTakenAndALateOneIgnored() async {
        #expect(await BoundedWait.value(within: 5, timedOut: false) { done in done(true) })
        let late = await BoundedWait.value(within: 0.1, timedOut: 0) { done in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { done(1) }
        }
        #expect(late == 0)
    }
}
