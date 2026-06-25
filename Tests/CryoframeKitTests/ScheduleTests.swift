//
//  ScheduleTests.swift
//  CryoframeKitTests
//
//  Frequency → next fire, due-job computation, run-policy decisions, job
//  persistence, and the defer/proceed wiring. All date-injected and pure.
//

import Testing
import Foundation
@testable import CryoframeKit
import CryoframeShared

private let cal: Calendar = {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
}()
private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
    cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}
private func tempURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("cf-sch-\(UUID().uuidString).json")
}
private func job(_ freq: BackupFrequency, policy: RunPolicy = .proceed,
                 created: Date, dir: URL = URL(fileURLWithPath: "/tmp")) -> BackupJob {
    BackupJob(id: "j1", name: "Photos→Disk", libraries: [.photos],
              target: .localVolume(id: "t", name: "Disk", dir: dir),
              format: .sealedZip, frequency: freq, runPolicy: policy, createdAt: created)
}

// MARK: - next fire

@Test func everyHoursAddsInterval() {
    #expect(BackupFrequency.everyHours(6).nextFireDate(after: at(2026,1,1,0,0), calendar: cal) == at(2026,1,1,6,0))
}

@Test func dailyFindsNextMatchingTime() {
    #expect(BackupFrequency.daily(hour: 3, minute: 30).nextFireDate(after: at(2026,1,1,1,0), calendar: cal) == at(2026,1,1,3,30))
    #expect(BackupFrequency.daily(hour: 3, minute: 30).nextFireDate(after: at(2026,1,1,4,0), calendar: cal) == at(2026,1,2,3,30))
}

@Test func oneTimeFiresOnceThenNil() {
    let d = at(2026,6,1,12,0)
    #expect(BackupFrequency.oneTime(d).nextFireDate(after: at(2026,5,1,0,0), calendar: cal) == d)
    #expect(BackupFrequency.oneTime(d).nextFireDate(after: d, calendar: cal) == nil)       // already fired
}

@Test func manualNeverFires() {
    #expect(BackupFrequency.manual.nextFireDate(after: at(2026,1,1,0,0), calendar: cal) == nil)
}

// MARK: - scheduler

@Test func intervalJobDueOnlyAfterIntervalFromReference() {
    let s = Scheduler()
    let created = at(2026,1,1,0,0)
    let j = job(.everyHours(6), created: created)
    #expect(!s.isDue(j, lastRun: nil, now: at(2026,1,1,5,0), calendar: cal))    // before first interval
    #expect(s.isDue(j, lastRun: nil, now: at(2026,1,1,6,0), calendar: cal))     // at first interval
    #expect(!s.isDue(j, lastRun: at(2026,1,1,6,0), now: at(2026,1,1,11,0), calendar: cal)) // since last run
    #expect(s.isDue(j, lastRun: at(2026,1,1,6,0), now: at(2026,1,1,12,0), calendar: cal))
}

@Test func dueJobsFiltersToTheReadyOnes() {
    let s = Scheduler()
    let ct = ContentType.photos
    let tgt = Target.localVolume(id: "t", name: "Disk", dir: URL(fileURLWithPath: "/tmp"))
    let a = BackupJob(id: "a", name: "a", libraries: [ct], target: tgt,
                      format: .sealedZip, frequency: .everyHours(1), createdAt: at(2026,1,1,0,0))
    let b = BackupJob(id: "b", name: "b", libraries: [ct], target: tgt,
                      format: .sealedZip, frequency: .daily(hour: 23, minute: 0), createdAt: at(2026,1,1,0,0))
    let state = ScheduleState(jobs: [a, b], lastRun: [:])
    let due = s.dueJobs(state, now: at(2026,1,1,2,0), calendar: cal)
    #expect(due.map(\.id) == ["a"])
}

// MARK: - run policy

@Test func runPolicyDecisions() {
    let running = FakeProcessDetector(runningBundleIDs: ["com.apple.Photos"])
    let idle = FakeProcessDetector()
    #expect(decide(.proceed, libraries: [.photos], detector: running) == .proceed)
    if case .proceedWithWarning = decide(.warnIfRunning, libraries: [.photos], detector: running) {} else { Issue.record("expected warning") }
    #expect(decide(.warnIfRunning, libraries: [.photos], detector: idle) == .proceed)
    if case .deferred = decide(.deferIfRunning, libraries: [.photos], detector: running) {} else { Issue.record("expected deferred") }
    #expect(decide(.deferIfRunning, libraries: [.photos], detector: idle) == .proceed)
}

// MARK: - persistence

@Test func jobStoreRoundTripsAndRecordsRuns() {
    let store = JobStore(url: tempURL())
    let j = job(.daily(hour: 2, minute: 0), created: at(2026,1,1,0,0))
    store.upsert(j)
    #expect(store.load().jobs == [j])
    store.recordRun(id: j.id, at: at(2026,1,2,2,0))
    #expect(store.load().lastRun[j.id] == at(2026,1,2,2,0))
    store.remove(id: j.id)
    #expect(store.load().jobs.isEmpty)
}

@Test func migratesLegacySingleLibraryJob() throws {
    // simulate a pre-0.3.0 job: one `contentType`, no `libraries`/`enabled`.
    let current = job(.manual, created: at(2026,1,1,0,0))
    var dict = try JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as! [String: Any]
    dict["contentType"] = (dict["libraries"] as! [Any])[0]
    dict.removeValue(forKey: "libraries")
    dict.removeValue(forKey: "enabled")

    let decoded = try JSONDecoder().decode(BackupJob.self, from: JSONSerialization.data(withJSONObject: dict))
    #expect(decoded.libraries.map(\.id) == ["com.apple.photos"])   // migrated to a one-element set
    #expect(decoded.enabled)                                       // defaulted to true
}

// MARK: - job executor

@Test func executorDefersWhenAnyOwningAppOpen() async throws {
    let helper = FakePrivilegedHelper()
    let exec = JobExecutor(helper: helper,
                           detector: FakeProcessDetector(runningBundleIDs: ["com.apple.Photos"]),
                           probe: FakeTargetProbe(TargetAvailability(reachable: true, writable: true)))
    let j = job(.manual, policy: .deferIfRunning, created: at(2026,1,1,0,0))
    guard case .deferred = try await exec.run(j, ownerUID: 501, now: at(2026,1,1,1,0)) else {
        Issue.record("expected deferred"); return
    }
    #expect(await helper.calls.isEmpty)
}

@Test func executorTakesOneSnapshotForAllLibrariesAndTearsDown() async throws {
    let helper = FakePrivilegedHelper()
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("cf-exec-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: out) }
    let exec = JobExecutor(helper: helper, detector: FakeProcessDetector(),
                           probe: FakeTargetProbe(TargetAvailability(reachable: true, writable: true)))
    let j = BackupJob(name: "multi", libraries: [.photos, .appleMusic],
                      target: .localVolume(id: "t", name: "Disk", dir: out),
                      format: .sealedZip, frequency: .manual, createdAt: at(2026,1,1,0,0))

    guard case .finished(let results, _) = try await exec.run(j, ownerUID: 501, now: at(2026,1,1,0,0)) else {
        Issue.record("expected finished"); return
    }
    #expect(results.count == 2)                              // both libraries processed in the run
    #expect(await helper.calls == ["create", "mount", "unmount", "delete"])  // exactly one snapshot for the job
}
