//
//  AlertPolicyTests.swift
//  CryoframeKitTests
//
//  An alert that never fires looks exactly like a backup that never failed, so
//  these pin the cases that must reach you — and the ones that must not, because
//  an alert for every good night is how people mute the channel.
//

import Testing
import Foundation
@testable import CryoframeKit

private let t = Target.localVolume(id: "t", name: "Backup", dir: URL(fileURLWithPath: "/Volumes/Backup"))
private let job = BackupJob(id: "j", name: "Photos nightly", libraries: [], targets: [t],
                            format: .sealedDMG, frequency: .manual, verification: .checksumOnly,
                            runPolicy: .proceed, createdAt: Date(timeIntervalSince1970: 0))

private func run(_ outcome: RunOutcomeKind, summary: String = "1 library archived") -> RunRecord {
    RunRecord(id: "r", jobID: job.id, jobName: job.name,
              startedAt: Date(timeIntervalSince1970: 0), finishedAt: Date(timeIntervalSince1970: 60),
              trigger: "scheduled", outcome: outcome, summary: summary,
              libraries: [], bytes: 0, warning: nil)
}

private func health(checked: Int, failures: [String], skipped: Int = 0) -> HealthRecord {
    HealthRecord(jobID: job.id, jobName: job.name, checkedAt: Date(timeIntervalSince1970: 0),
                 archivesChecked: checked, failures: failures, skipped: skipped)
}

// MARK: - runs

@Test func failureAlwaysAlerts() {
    let p = AlertPolicy.payload(for: run(.failed, summary: "0/1 archived, 1 failed"), everyEvent: false)
    #expect(p != nil)
    #expect(p?.high == true)                       // it should break through a quiet phone
    #expect(p?.title.contains("Photos nightly") == true)
}

@Test func partialAlertsToo() {
    // a downed secondary means you have fewer copies than you think — worth knowing.
    #expect(AlertPolicy.payload(for: run(.partial), everyEvent: false)?.high == true)
}

@Test func aGoodRunIsSilentUnlessYouAskedForEveryRun() {
    #expect(AlertPolicy.payload(for: run(.verified), everyEvent: false) == nil)
    #expect(AlertPolicy.payload(for: run(.completed), everyEvent: false) == nil)
    let p = AlertPolicy.payload(for: run(.verified), everyEvent: true)
    #expect(p != nil && p?.high == false)          // good news never gets high priority
}

@Test func deferredAndCancelledDoNotAlert() {
    // a run held back for low battery, or one you stopped yourself, is not a failure.
    #expect(AlertPolicy.payload(for: run(.deferred), everyEvent: false) == nil)
    #expect(AlertPolicy.payload(for: run(.cancelled), everyEvent: false) == nil)
}

// MARK: - health

@Test func failedArchiveChecksAlert() {
    let p = AlertPolicy.payload(forHealth: health(checked: 3, failures: ["Photos: mismatch"]), everyEvent: false)
    #expect(p?.high == true)
    #expect(p?.body.contains("1 archive check(s) failed") == true)
}

@Test func nothingFoundToCheckAlerts() {
    // the destination is probably unplugged — silence here is how a backup quietly
    // stops happening for weeks.
    let p = AlertPolicy.payload(forHealth: health(checked: 0, failures: []), everyEvent: false)
    #expect(p?.high == true)
    #expect(p?.body.contains("is the target connected?") == true)
}

@Test func cleanHealthIsSilentUnlessYouAskedForEveryRun() {
    #expect(AlertPolicy.payload(forHealth: health(checked: 5, failures: []), everyEvent: false) == nil)
    #expect(AlertPolicy.payload(forHealth: health(checked: 5, failures: []), everyEvent: true)?.high == false)
}

@Test func allCloudPlaceholdersIsBenignNotAnOutage() {
    // every copy offloaded and none downloaded is not the same as "no archives found",
    // and must not read as an alarm.
    let rec = health(checked: 0, failures: [], skipped: 4)
    #expect(AlertPolicy.payload(forHealth: rec, everyEvent: false) == nil)
    let p = AlertPolicy.payload(forHealth: rec, everyEvent: true)
    #expect(p?.high == false)
    #expect(p?.body.contains("not downloaded") == true)
}

// MARK: - who owns the alert

@Test func healthRecordCarriesWhoAskedForIt() throws {
    #expect(health(checked: 1, failures: []).trigger == "manual")
    let scheduled = HealthRecord.from(job: job, report: HealthReport(checks: []),
                                      at: Date(timeIntervalSince1970: 0), trigger: "scheduled")
    #expect(scheduled.trigger == "scheduled")
    // pre-1.5 records have no trigger and must still decode
    let legacy = #"[{"id":"x","jobID":"j","jobName":"n","checkedAt":0,"archivesChecked":1,"failures":[],"kind":"checksum","skipped":0}]"#
    let back = try JSONDecoder().decode([HealthRecord].self, from: Data(legacy.utf8))
    #expect(back[0].trigger == "manual")
}
