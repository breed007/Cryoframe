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
private func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-sch-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private final class RecordingEngine: ArchiveEngine, @unchecked Sendable {
    var ran = false
    func archive(_ source: ArchiveSource, to destinationDir: URL) throws -> ArchiveResult {
        ran = true
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        let a = destinationDir.appendingPathComponent("out.zip"); try Data("z".utf8).write(to: a)
        return ArchiveResult(artifacts: [a], format: .sealedZip)
    }
}

private func job(_ freq: BackupFrequency, policy: RunPolicy = .proceed,
                 created: Date, dir: URL = URL(fileURLWithPath: "/tmp")) -> BackupJob {
    BackupJob(id: "j1", name: "Photos→Disk", contentType: .photos,
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
    let a = BackupJob(id: "a", name: "a", contentType: ct, target: tgt,
                      format: .sealedZip, frequency: .everyHours(1), createdAt: at(2026,1,1,0,0))
    let b = BackupJob(id: "b", name: "b", contentType: ct, target: tgt,
                      format: .sealedZip, frequency: .daily(hour: 23, minute: 0), createdAt: at(2026,1,1,0,0))
    let state = ScheduleState(jobs: [a, b], lastRun: [:])
    let due = s.dueJobs(state, now: at(2026,1,1,2,0), calendar: cal)
    #expect(due.map(\.id) == ["a"])
}

// MARK: - run policy

@Test func runPolicyDecisions() {
    let running = FakeProcessDetector(runningBundleIDs: ["com.apple.Photos"])
    let idle = FakeProcessDetector()
    #expect(decide(.proceed, type: .photos, detector: running) == .proceed)
    if case .proceedWithWarning = decide(.warnIfRunning, type: .photos, detector: running) {} else { Issue.record("expected warning") }
    #expect(decide(.warnIfRunning, type: .photos, detector: idle) == .proceed)
    if case .deferred = decide(.deferIfRunning, type: .photos, detector: running) {} else { Issue.record("expected deferred") }
    #expect(decide(.deferIfRunning, type: .photos, detector: idle) == .proceed)
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

// MARK: - job runner

@Test func jobRunnerDefersWhenOwningAppOpen() async throws {
    let helper = FakePrivilegedHelper()
    let engine = RecordingEngine()
    let targeted = TargetedBackupRunner(
        backup: BackupRunner(helper: helper, locator: ContentLocator(exists: { _ in true })),
        probe: FakeTargetProbe(TargetAvailability(reachable: true, writable: true)),
        engineProvider: { _, _ in engine })
    let runner = JobRunner(targeted: targeted, detector: FakeProcessDetector(runningBundleIDs: ["com.apple.Photos"]))

    let result = try await runner.run(job(.manual, policy: .deferIfRunning, created: at(2026,1,1,0,0)),
                                      ownerUID: 501, now: at(2026,1,1,1,0))
    guard case .deferred = result else { Issue.record("expected deferred"); return }
    #expect(!engine.ran)
    #expect(await helper.calls.isEmpty)              // nothing ran
}

@Test func jobRunnerCompletesAndRecordsRun() async throws {
    let helper = FakePrivilegedHelper()
    let engine = RecordingEngine()
    let out = tempDir(); defer { try? FileManager.default.removeItem(at: out) }
    let store = JobStore(url: tempURL())
    let targeted = TargetedBackupRunner(
        backup: BackupRunner(helper: helper, locator: ContentLocator(exists: { _ in true })),
        probe: FakeTargetProbe(TargetAvailability(reachable: true, writable: true)),
        engineProvider: { _, _ in engine })
    let runner = JobRunner(targeted: targeted, detector: FakeProcessDetector(), store: store)

    let j = job(.everyHours(6), policy: .proceed, created: at(2026,1,1,0,0), dir: out)
    store.upsert(j)
    let result = try await runner.run(j, ownerUID: 501, now: at(2026,1,1,6,0))

    guard case .completed = result else { Issue.record("expected completed"); return }
    #expect(engine.ran)
    #expect(await helper.calls == ["create", "mount", "unmount", "delete"])
    #expect(store.load().lastRun[j.id] == at(2026,1,1,6,0))
}
