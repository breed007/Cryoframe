//
//  ProtectionVerdictTests.swift
//  CryoframeKitTests
//
//  "Am I protected?" and the restore failure wording, pinned as they behaved when
//  they lived in the app's views.
//

import Testing
import Foundation
@testable import CryoframeKit

private let dir = URL(fileURLWithPath: "/Volumes/T7/Backups", isDirectory: true)

private func job(_ id: String, libraries: [String] = ["Photos"], dest: String = "/Volumes/T7/Backups") -> BackupJob {
    BackupJob(id: id, name: "Job \(id)",
              libraries: libraries.map { ContentType(id: $0, displayName: $0, paths: [.absolute("/tmp/\($0)")],
                                                     owningProcess: nil, kind: .staticContent) },
              target: .localVolume(id: dest, name: "T7", dir: URL(fileURLWithPath: dest, isDirectory: true)),
              format: .sealedDMG, frequency: .manual, createdAt: Date(timeIntervalSince1970: 0))
}

private func run(_ job: BackupJob, _ outcome: RunOutcomeKind, at t: TimeInterval = 1_000) -> RunRecord {
    RunRecord(id: UUID().uuidString, jobID: job.id, jobName: job.name,
              startedAt: Date(timeIntervalSince1970: t - 10), finishedAt: Date(timeIntervalSince1970: t),
              trigger: "manual", outcome: outcome, summary: "", libraries: [], bytes: 0, warning: nil)
}

private func health(_ job: BackupJob, passed: Bool) -> HealthRecord {
    HealthRecord(jobID: job.id, jobName: job.name, checkedAt: Date(timeIntervalSince1970: 0),
                 archivesChecked: 1, failures: passed ? [] : ["checksum mismatch"])
}

private func verdict(_ jobs: [BackupJob], runs: [RunRecord] = [], health: [HealthRecord] = [],
                     running: Int = 0, lastGood: [String: Date] = [:], now: TimeInterval = 2_000,
                     scheduleOn: Bool = true) -> ProtectionVerdict {
    ProtectionVerdict.compute(jobs: jobs,
                              lastRecords: Dictionary(runs.map { ($0.jobID, $0) }, uniquingKeysWith: { a, _ in a }),
                              lastHealth: Dictionary(health.map { ($0.jobID, $0) }, uniquingKeysWith: { a, _ in a }),
                              runningCount: running, lastGood: lastGood, now: Date(timeIntervalSince1970: now),
                              scheduleOn: scheduleOn)
}

// MARK: - the verdict

@Test func noJobsIsIdle() {
    let v = verdict([])
    #expect(v.level == .idle && v.title == "No backup jobs yet" && v.glyph == "plus.circle")
}

@Test func aRunningJobTrumpsEverythingElse() {
    let a = job("a")
    let v = verdict([a], runs: [run(a, .failed)], running: 2)
    #expect(v.level == .idle && v.title == "Backing up…")
    #expect(v.subtitle == "2 jobs are running right now.")
    #expect(verdict([a], running: 1).subtitle == "1 job is running right now.")
}

@Test func aFailedLastRunIsCritical() {
    let (a, b, c) = (job("a"), job("b"), job("c"))
    let v = verdict([a, b, c], runs: [run(a, .completed), run(b, .failed), run(c, .failed)])
    #expect(v.level == .critical && v.title == "2 backups failed" && v.glyph == "xmark.octagon.fill")
    #expect(v.subtitle == "Job b didn't finish — open it to see why. 1 of 3 jobs are healthy.")
}

@Test func aPartialRunOrFailedCheckNeedsAttention() {
    let (a, b) = (job("a"), job("b"))
    let partial = verdict([a, b], runs: [run(a, .partial), run(b, .verified)])
    #expect(partial.level == .attention && partial.title == "1 job needs attention")
    #expect(partial.subtitle == "Job a finished as a partial backup — open it to fix. 1 of 2 jobs are fully healthy.")

    let badCheck = verdict([a, b], runs: [run(a, .verified), run(b, .verified)], health: [health(b, passed: false)])
    #expect(badCheck.level == .attention)
    #expect(badCheck.subtitle == "Job b failed an archive check — open it to fix. 1 of 2 jobs are fully healthy.")
}

@Test func aJobBothPartialAndCheckFailedCountsOnce() {
    let (a, b) = (job("a"), job("b"))
    let v = verdict([a, b], runs: [run(a, .partial), run(b, .verified)], health: [health(a, passed: false)])
    #expect(v.subtitle.hasSuffix("1 of 2 jobs are fully healthy."))
}

@Test func onlyNeverRunJobsAreReadyToBackUp() {
    let (a, b) = (job("a"), job("b"))
    #expect(verdict([a]).title == "Ready to back up")
    #expect(verdict([a]).subtitle == "Your job hasn't run yet — press Run now, or wait for its schedule.")
    #expect(verdict([a, b]).subtitle == "2 jobs haven't run yet.")
    #expect(verdict([a]).level == .idle)
}

@Test func healthyJobsAreProtected() {
    let (a, b) = (job("a"), job("b"))
    let v = verdict([a, b], runs: [run(a, .verified)])
    #expect(v.level == .protected && v.title == "You're protected" && v.glyph == "checkmark.shield.fill")
    #expect(v.subtitle.hasPrefix("1 job healthy · "))
    #expect(v.subtitle.hasSuffix(" · nothing needs your attention. 1 haven't run yet."))
}

// Pinned in 1.6's first milestone as it was: a stopped or deferred run counted as
// protected, and the dashboard said "2 jobs healthy · never". Neither kept anything.
@Test func aStoppedOrDeferredRunIsNotASuccess() {
    let (a, b) = (job("a"), job("b"))
    let v = verdict([a, b], runs: [run(a, .cancelled), run(b, .deferred)])
    #expect(v.level == .attention)
    #expect(v.title == "2 jobs need attention")
    #expect(v.subtitle == "Job a was stopped before it finished — open it to fix. 0 of 2 jobs are fully healthy.")
    // put off, with nothing good behind it
    let put = verdict([b], runs: [run(b, .deferred)])
    #expect(put.subtitle.hasPrefix("Job b hasn't finished a backup yet (put off"))
}

// MARK: - honest about time

private let hour: TimeInterval = 3600, day: TimeInterval = 86_400

private func scheduled(_ id: String, _ frequency: BackupFrequency = .daily(hour: 2, minute: 0),
                       created: TimeInterval = 0, enabled: Bool = true) -> BackupJob {
    var j = job(id)
    j.frequency = frequency
    j.createdAt = Date(timeIntervalSince1970: created)
    j.enabled = enabled
    return j
}

// A nightly job is overdue once two nights pass without a good run, and critical
// after a week. Its latest record alone doesn't say: a job put off every night for a
// week still had "put off" as its latest record, which used to count as fine.
@Test func aScheduledJobIsOverdueAtTwiceItsIntervalAndCriticalAtAWeek() {
    let a = scheduled("a")
    let lastGood = ["a": Date(timeIntervalSince1970: 10 * day)]
    #expect(verdict([a], runs: [run(a, .verified, at: 10 * day)], lastGood: lastGood, now: 11.9 * day).level == .protected)
    let late = verdict([a], runs: [run(a, .deferred, at: 12 * day)], lastGood: lastGood, now: 12.1 * day)
    #expect(late.level == .attention)
    #expect(late.subtitle.hasPrefix("Job a hasn't had a good backup in 2 days (put off"), "\(late.subtitle)")
    let week = verdict([a], runs: [run(a, .deferred, at: 17 * day)], lastGood: lastGood, now: 17 * day)
    #expect(week.level == .critical)
    #expect(week.title == "1 backup is overdue")
    #expect(week.subtitle.hasPrefix("Job a hasn't had a good backup in 7 days"))
    // an hourly job: overdue after two hours, but critical only after a week
    let h = scheduled("h", .everyHours(1))
    let hourly = verdict([h], runs: [run(h, .completed, at: 100 * day)], lastGood: ["h": Date(timeIntervalSince1970: 100 * day)],
                         now: 100 * day + 3 * hour)
    #expect(hourly.level == .attention)
    // a weekly one: not overdue until two weeks, and then critical at once
    let w = scheduled("w", .everyHours(168))
    let good = ["w": Date(timeIntervalSince1970: 100 * day)]
    #expect(verdict([w], runs: [run(w, .completed, at: 100 * day)], lastGood: good, now: 113 * day).level == .protected)
    #expect(verdict([w], runs: [run(w, .completed, at: 100 * day)], lastGood: good, now: 114 * day).level == .critical)
}

// A job that has never finished a good run is judged from when it was set up.
@Test func aScheduledJobThatNeverFinishedIsOverdueFromItsCreation() {
    let a = scheduled("a", created: 100 * day)
    #expect(verdict([a], now: 100 * day + hour).level == .idle)            // new: ready to back up
    let v = verdict([a], runs: [run(a, .cancelled, at: 101 * day)], now: 103 * day)
    #expect(v.level == .attention)
    #expect(v.subtitle.hasPrefix("Job a hasn't finished a backup since it was set up 3 days ago (its last run was stopped)"), "\(v.subtitle)")
    #expect(verdict([a], now: 108 * day).level == .critical)
}

// Only verified and completed runs are good ones. A partial run left part of the job
// behind; a job partial every night for a week is critical.
@Test func aPartialRunDoesNotResetTheClock() {
    let a = scheduled("a")
    let v = verdict([a], runs: [run(a, .partial, at: 20 * day)], lastGood: ["a": Date(timeIntervalSince1970: 12 * day)], now: 20 * day)
    #expect(v.level == .critical)
    #expect(v.subtitle.contains("(its last run was partial)"))
}

// A paused job is flagged, and doesn't turn overdue: it was paused on purpose.
@Test func aPausedJobIsFlaggedButNotOverdue() {
    let a = scheduled("a", enabled: false), b = scheduled("b")
    let good = ["a": Date(timeIntervalSince1970: 0), "b": Date(timeIntervalSince1970: 30 * day)]
    let v = verdict([a, b], runs: [run(a, .verified, at: 0), run(b, .verified, at: 30 * day)], lastGood: good, now: 30 * day + hour)
    #expect(v.level == .attention)
    #expect(v.subtitle == "Job a is paused, so its schedule doesn't run it — open it to fix. 1 of 2 jobs are fully healthy.")
}

// With the scheduled agent switched off nothing runs on its own.
@Test func aSwitchedOffScheduleIsFlagged() {
    let a = scheduled("a"), m = job("m")
    let good = ["a": Date(timeIntervalSince1970: 30 * day)]
    let v = verdict([a, m], runs: [run(a, .verified, at: 30 * day), run(m, .verified, at: 30 * day)], lastGood: good,
                    now: 30 * day + hour, scheduleOn: false)
    #expect(v.level == .attention && v.title == "Scheduled backups are off")
    #expect(v.subtitle.hasPrefix("1 job won't run on its schedule"))
    // manual jobs alone don't need it
    #expect(verdict([m], runs: [run(m, .verified, at: 30 * day)], now: 30 * day + hour, scheduleOn: false).level == .protected)
    // a failure still says so first
    #expect(verdict([a], runs: [run(a, .failed, at: 30 * day)], now: 30 * day + hour, scheduleOn: false).level == .critical)
}

// A job you run by hand has no schedule to fall behind: after a month it is worth a
// look, never critical for its age.
@Test func aManualJobIsFlaggedAfterAMonthAndNeverCritical() {
    let m = job("m")
    let good = ["m": Date(timeIntervalSince1970: 0)]
    #expect(verdict([m], runs: [run(m, .completed, at: 0)], lastGood: good, now: 29 * day).level == .protected)
    let v = verdict([m], runs: [run(m, .completed, at: 0)], lastGood: good, now: 400 * day)
    #expect(v.level == .attention)
    #expect(v.subtitle.hasPrefix("Job m hasn't been backed up in 400 days; it runs only when you press Run now"))
}

// The latest record may be a deferral while an older good run is still recent.
@Test func aDeferralWithinTheScheduleIsFine() {
    let a = scheduled("a")
    let v = verdict([a], runs: [run(a, .deferred, at: 10 * day + hour)], lastGood: ["a": Date(timeIntervalSince1970: 10 * day)],
                    now: 10 * day + 2 * hour)
    #expect(v.level == .protected)
}

// MARK: - dashboard figures

@Test func lastSuccessIgnoresRunsThatLeftNothing() {
    let (a, b, c) = (job("a"), job("b"), job("c"))
    let runs = [run(a, .partial, at: 500), run(b, .failed, at: 900), run(c, .cancelled, at: 950)]
    let latest = Dictionary(uniqueKeysWithValues: runs.map { ($0.jobID, $0) })
    #expect(ProtectionVerdict.lastSuccessfulRecord(jobs: [a, b, c], lastRecords: latest)?.jobID == "a")
    #expect(ProtectionVerdict.lastSuccess(jobs: [a, b, c], lastRecords: latest) == Date(timeIntervalSince1970: 500))
    #expect(ProtectionVerdict.lastBackupText(jobs: [b], lastRecords: latest) == "Never")
}

@Test func libraryAndDestinationCountsAreDistinct() {
    let jobs = [job("a", libraries: ["Photos", "Music"]), job("b", libraries: ["Photos"], dest: "/Volumes/NAS"),
                job("c", libraries: ["Mail"])]
    #expect(ProtectionVerdict.libraryCount(jobs) == 3)
    #expect(ProtectionVerdict.destinationCount(jobs) == 2)
}

// MARK: - restore and recovery failure wording

private struct Odd: Error {}

@Test func restoreMessagesByError() {
    typealias T = RestoreFailureText
    #expect(T.restoreMessage(RestoreError.verificationFailed("2 files differ"), encrypted: false) == "verification failed — 2 files differ")
    #expect(T.restoreMessage(RestoreError.destinationExists("/x/Photos"), encrypted: false)
            == "already exists in the destination — rename or move it, then try again")
    #expect(T.restoreMessage(RestoreError.libraryNotFound, encrypted: false) == "library not found inside the archive")
    #expect(T.restoreMessage(RestoreError.noManifest, encrypted: true) == "no checksum manifest beside the archive")
    #expect(T.restoreMessage(ArchiveError.toolFailed(tool: "hdiutil", status: 1, stderr: "a\nattach failed"), encrypted: false)
            == "couldn't open the archive — attach failed")
    #expect(T.restoreMessage(ArchiveError.toolFailed(tool: "hdiutil", status: 1, stderr: ""), encrypted: false)
            == "couldn't open the archive (hdiutil failed)")
    #expect(T.restoreMessage(ArchiveError.toolFailed(tool: "hdiutil", status: 1, stderr: "x"), encrypted: true)
            == "couldn't open the archive — check the passphrase")
    #expect(T.restoreMessage(ArchiveError.noArtifactProduced(dir), encrypted: false) == "the archive is missing its files")
    #expect(T.restoreMessage(ArchiveError.sourceMissing("part 2"), encrypted: false) == "missing part of the archive — part 2")
    #expect(T.restoreMessage(ArchiveError.passphraseUnavailable, encrypted: true)
            == "this archive is encrypted and no passphrase was found")
    #expect(T.restoreMessage(Odd(), encrypted: true) == "couldn't open the archive — check the passphrase")
    #expect(T.restoreMessage(Odd(), encrypted: false) == (Odd() as NSError).localizedDescription)
}

@Test func recoveryMessagesByError() {
    typealias T = RestoreFailureText
    #expect(T.recoveryMessage(RestoreError.verificationFailed("bad"), encrypted: false) == "verification failed — bad")
    #expect(T.recoveryMessage(RestoreError.destinationExists("/Users/me/Pictures/Photos Library.photoslibrary"), encrypted: false)
            == "something is already at Photos Library.photoslibrary — it was left alone")
    #expect(T.recoveryMessage(RestoreError.libraryNotFound, encrypted: false) == "the archive didn't contain the library")
    #expect(T.recoveryMessage(RestoreError.noManifest, encrypted: false) == "no checksum manifest beside the archive")
    #expect(T.recoveryMessage(ArchiveError.toolFailed(tool: "hdiutil", status: 1, stderr: "x"), encrypted: true)
            == "couldn't open — check the recovery key")
    #expect(T.recoveryMessage(ArchiveError.toolFailed(tool: "hdiutil", status: 1, stderr: "a\nb"), encrypted: false)
            == "couldn't open the archive — b")
    #expect(T.recoveryMessage(ArchiveError.toolFailed(tool: "hdiutil", status: 1, stderr: ""), encrypted: false)
            == "couldn't open the archive — unreadable")
    #expect(T.recoveryMessage(ArchiveError.passphraseUnavailable, encrypted: true) == "encrypted, and no passphrase was recovered")
    // unlike Restore, an unknown error is not blamed on the key
    #expect(T.recoveryMessage(Odd(), encrypted: true) == (Odd() as NSError).localizedDescription)
}

@Test func aFileLevelCopyFailureIsNamedInBothWindows() {
    let e = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
                    userInfo: [NSFilePathErrorKey: "/a/b/IMG_0001.HEIC",
                               NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))])
    #expect(RestoreFailureText.restoreMessage(e, encrypted: true) == "couldn't restore IMG_0001.HEIC — permission denied")
    #expect(RestoreFailureText.recoveryMessage(e, encrypted: true) == "couldn't restore IMG_0001.HEIC — permission denied")
}
