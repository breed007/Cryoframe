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
                     running: Int = 0) -> ProtectionVerdict {
    ProtectionVerdict.compute(jobs: jobs,
                              lastRecords: Dictionary(runs.map { ($0.jobID, $0) }, uniquingKeysWith: { a, _ in a }),
                              lastHealth: Dictionary(health.map { ($0.jobID, $0) }, uniquingKeysWith: { a, _ in a }),
                              runningCount: running)
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

// This is today's behavior, pinned so the move changes nothing. The honest-status
// work in 1.6 is meant to change it: a stopped or deferred run is not a success.
@Test func todayAStoppedOrDeferredRunCountsAsProtected() {
    let (a, b) = (job("a"), job("b"))
    let v = verdict([a, b], runs: [run(a, .cancelled), run(b, .deferred)])
    #expect(v.level == .protected)
    #expect(v.subtitle.hasPrefix("2 jobs healthy · never · "))
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
