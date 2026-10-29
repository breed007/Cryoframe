//
//  BandCheckTests.swift
//  CryoframeKitTests
//
//  The rolling check of a mirror's data bands for decay: how much each run reads,
//  in what order, what counts as decay and what as a band rewritten, and what the
//  run, the dashboard and the checks say about it.
//

import Testing
import Foundation
@testable import CryoframeKit

private func tempDir(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-bands-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// a stand-in sparsebundle in `dir` whose bands are small files, named as an image names them
private func fakeBundle(in dir: URL, bands: Int) throws -> URL {
    let bundle = dir.appendingPathComponent("Lib.sparsebundle", isDirectory: true)
    let b = bundle.appendingPathComponent("bands", isDirectory: true)
    try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
    for i in 0..<bands { try Data("band \(i)".utf8).write(to: b.appendingPathComponent(String(i, radix: 16))) }
    return bundle
}

/// Change one byte of a band and put its modification time back, as `touch -r` does:
/// what a drive changing data under a file looks like.
private func rot(_ band: URL) throws {
    let ref = band.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("ref-\(UUID().uuidString)")
    try #require(touch(["-r", band.path, ref.path]))
    let h = try FileHandle(forUpdating: band)
    try h.seek(toOffset: 4)
    let old = try h.read(upToCount: 1) ?? Data([0])
    try h.seek(toOffset: 4)
    try h.write(contentsOf: Data([old[0] ^ 0xFF]))
    try h.close()
    try #require(touch(["-r", ref.path, band.path]))
    try? FileManager.default.removeItem(at: ref)
}

private func touch(_ args: [String]) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/touch")
    p.arguments = args
    guard (try? p.run()) != nil else { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}

private let day: TimeInterval = 86_400
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

// MARK: - pure

@Suite struct BandCheckSlices {

    @Test func aRunReadsItsShareOfAThirtyDayRoundAtLeastTheFloor() {
        #expect(BandCheck.sliceSize(total: 0, interval: day) == 0)
        #expect(BandCheck.sliceSize(total: 10, interval: day) == 10)            // never more than there are
        #expect(BandCheck.sliceSize(total: 1_000, interval: day) == 64)         // 34 is under the floor
        #expect(BandCheck.sliceSize(total: 64_000, interval: day) == 2_134)     // 500 GB of 8 MB bands, daily
        #expect(BandCheck.sliceSize(total: 64_000, interval: 3_600) == 89)      // hourly
        #expect(BandCheck.sliceSize(total: 64_000, interval: 7 * day) == 14_934)
        #expect(BandCheck.sliceSize(total: 500, interval: 60 * day) == 500)
    }

    @Test func aBandIsChangedWhenItsSizeOrTimeMovedAndUnchangedOtherwise() {
        let found = BandStat(name: "1a", size: 8, mtime: 100)
        #expect(BandCheck.classify(found, recorded: nil) == .new)
        #expect(BandCheck.classify(found, recorded: .init(size: 8, mtime: 100, sha256: "x")) == .unchanged)
        #expect(BandCheck.classify(found, recorded: .init(size: 8, mtime: 101, sha256: "x")) == .changed)
        #expect(BandCheck.classify(found, recorded: .init(size: 7, mtime: 100, sha256: "x")) == .changed)
    }

    @Test func withoutATableEveryBandIsRecordedUnreadAndTheSliceTakesThemInBandOrder() {
        let found = ["10", "2", "a", "0", "f", "1"].map { BandStat(name: $0, size: 1, mtime: 1) }
        let plan = BandCheck.plan(table: nil, found: found, sliceSize: 4)
        #expect(plan.rehash.isEmpty)
        #expect(plan.slice == ["0", "1", "2", "a"])
        #expect(plan.table.entries.count == 6 && plan.table.entries.values.allSatisfy { $0.sha256 == nil })
    }

    @Test func changedBandsAreReadAgainAndTheSliceIsOldestReadFirst() {
        var table = BandTable()
        table.entries["0"] = .init(size: 1, mtime: 1, sha256: String(repeating: "a", count: 64), verifiedAt: t0.addingTimeInterval(-3 * day))
        table.entries["1"] = .init(size: 1, mtime: 1, sha256: String(repeating: "b", count: 64), verifiedAt: t0.addingTimeInterval(-9 * day))
        table.entries["2"] = .init(size: 1, mtime: 1)                                       // never read
        table.entries["3"] = .init(size: 1, mtime: 1, sha256: String(repeating: "c", count: 64), verifiedAt: t0.addingTimeInterval(-9 * day))
        table.entries["4"] = .init(size: 1, mtime: 1, sha256: String(repeating: "d", count: 64), verifiedAt: t0)
        table.entries["9"] = .init(size: 1, mtime: 1, sha256: String(repeating: "e", count: 64), verifiedAt: t0)   // compacted away
        let found = [BandStat(name: "0", size: 1, mtime: 1), BandStat(name: "1", size: 1, mtime: 1),
                     BandStat(name: "2", size: 1, mtime: 1), BandStat(name: "3", size: 1, mtime: 1),
                     BandStat(name: "4", size: 1, mtime: 2),                                  // rewritten
                     BandStat(name: "b", size: 1, mtime: 1)]                                  // added
        let plan = BandCheck.plan(table: table, found: found, sliceSize: 3)
        #expect(plan.rehash == ["4", "b"])
        #expect(plan.slice == ["2", "1", "3"])
        #expect(plan.dropped == ["9"])
        #expect(plan.table.entries["4"]?.sha256 == nil && plan.table.entries["4"]?.mtime == 2)
        #expect(plan.table.entries["9"] == nil)
    }

    @Test func theTableRoundTripsAndOneThatCantBeReadThrows() throws {
        let dir = tempDir("table")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try BandTable.read(in: dir) == nil)
        var table = BandTable()
        table.entries["1f"] = .init(size: 8_388_608, mtime: 1_793_299_257_694_117_518,
                                    sha256: String(repeating: "0", count: 64), verifiedAt: t0)
        table.entries["2"] = .init(size: 12, mtime: 5)
        try table.write(in: dir)
        #expect(try BandTable.read(in: dir) == table)
        try Data("cryoframe-bands.v1\n1f\tnot a number\t5\t-\t-\n".utf8).write(to: dir.appendingPathComponent(BandTable.fileName))
        #expect(throws: BandTableError.self) { _ = try BandTable.read(in: dir) }
    }
}

@Suite struct BandCheckRuns {

    private func settings(cap: TimeInterval = 600, interval: TimeInterval = day) -> BandCheck.Settings {
        BandCheck.Settings(interval: interval, timeCap: cap)
    }

    // The table is the cursor: what one run didn't read is first at the next, so a
    // run that is missed or cut short loses nothing.
    @Test func eachRunCarriesOnWhereTheLastOneStopped() throws {
        let dir = tempDir("cursor")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try fakeBundle(in: dir, bands: 130)
        var read: [Set<String>] = []
        for run in 0..<3 {
            var names = Set<String>()
            let r = BandCheck.run(bundle: bundle, in: dir, library: "Lib", settings: settings(), now: t0.addingTimeInterval(Double(run) * day),
                                  hash: { url, _ in names.insert(url.lastPathComponent); return try Checksum.sha256(of: url) })
            #expect(r.checked == 64 && r.mismatches == 0 && r.error == nil, "\(r)")
            read.append(names)
        }
        #expect(read[0].isDisjoint(with: read[1]))
        #expect(read[0].union(read[1]).count == 128)
        // the two never read, then the 62 read longest ago
        let left = Set((0..<130).map { String($0, radix: 16) }).subtracting(read[0].union(read[1]))
        #expect(left.count == 2 && left.isSubset(of: read[2]))
        #expect(read[2].subtracting(left).isSubset(of: read[0]))
        let last = BandCheck.run(bundle: bundle, in: dir, library: "Lib", settings: settings(cap: 0), now: t0.addingTimeInterval(3 * day))
        #expect(last.unverified == 0 && last.total == 130)
        #expect(last.oldestVerified == t0)          // 3e and 3f, read by the first run only
    }

    // Only a band as recorded whose contents moved is decay. One whose time moved was
    // written since: by this run, or by an older Cryoframe after a downgrade.
    @Test func decayIsReportedAndARewrittenBandIsRecordedAgain() throws {
        let dir = tempDir("classify")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try fakeBundle(in: dir, bands: 6)
        let first = BandCheck.run(bundle: bundle, in: dir, library: "Lib", settings: settings(), now: t0)
        #expect(first.checked == 6 && first.unverified == 0)
        let bands = bundle.appendingPathComponent("bands")
        try rot(bands.appendingPathComponent("3"))
        Thread.sleep(forTimeInterval: 0.01)
        try Data("band 4 rewritten".utf8).write(to: bands.appendingPathComponent("4"))   // a downgrade-style write
        let second = BandCheck.run(bundle: bundle, in: dir, library: "Lib", settings: settings(), now: t0.addingTimeInterval(day))
        #expect(second.mismatches == 1 && second.damaged == ["3"], "\(second)")
        #expect(second.recorded == 1 && second.checked == 5)
        // the rewritten band is recorded as it is now; the decayed one keeps what it should hold
        let table = try #require(try BandTable.read(in: dir))
        let four = try Checksum.sha256(of: bands.appendingPathComponent("4"))
        let three = try Checksum.sha256(of: bands.appendingPathComponent("3"))
        #expect(table.entries["4"]?.sha256 == four)
        #expect(table.entries["3"]?.sha256 != three)
    }

    // The cap covers the whole check; what it leaves unread is first in line next time.
    @Test func theTimeCapStopsTheCheckAndWhatWasLeftWaitsItsTurn() throws {
        let dir = tempDir("cap")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try fakeBundle(in: dir, bands: 10)
        var tick = t0
        let clock = { () -> Date in defer { tick = tick.addingTimeInterval(1) }; return tick }
        let r = BandCheck.run(bundle: bundle, in: dir, library: "Lib", settings: settings(cap: 4), now: t0, clock: clock)
        #expect(r.stoppedEarly && r.checked == 3 && r.unverified == 7, "\(r)")
        let next = BandCheck.run(bundle: bundle, in: dir, library: "Lib", settings: settings(), now: t0.addingTimeInterval(day))
        #expect(next.checked == 10 && next.unverified == 0)
    }

    // A band that can't be read isn't decay. It is skipped and counted, and the check
    // goes on past it, so one bad sector can't stop it at the same place every run.
    // Three in a row that had read before end the check (an unplugged drive, a share
    // that timed out, an offline cloud file): that is a check that couldn't be made.
    @Test func aBandThatCantBeReadIsSkippedAndCountedNotDecay() throws {
        let fm = FileManager.default
        let dir = tempDir("eio")
        defer { try? fm.removeItem(at: dir) }
        let bundle = try fakeBundle(in: dir, bands: 6)
        _ = BandCheck.run(bundle: bundle, in: dir, library: "Lib", settings: settings(), now: t0)
        var asked: [String] = []
        let r = BandCheck.run(bundle: bundle, in: dir, library: "Lib", settings: settings(), now: t0.addingTimeInterval(day), hash: { url, _ in
            asked.append(url.lastPathComponent)
            if url.lastPathComponent == "1" { throw POSIXError(.ETIMEDOUT) }
            return try Checksum.sha256(of: url)
        })
        #expect(r.mismatches == 0 && r.damaged.isEmpty && !r.failed, "\(r)")
        #expect(r.error == nil && r.unread == ["1"] && (r.unreadable ?? []).isEmpty, "\(r)")
        #expect(asked == ["0", "1", "2", "3", "4", "5"], "the check went on past the band")
        #expect(r.checked == 5)
        let table = try #require(try BandTable.read(in: dir))
        #expect(table.entries["1"]?.misses == 1 && table.entries["2"]?.misses == 0)
        #expect(table.entries["1"]?.verifiedAt == t0, "a band that didn't read isn't counted as read")
        #expect(BandCoverage([r]) != nil)
        let line = BandCheckSummary(copies: [r]).line(at: t0.addingTimeInterval(day))
        #expect(line.contains("data band 1 couldn't be read"), "\(line)")
        // it reads again: its count starts over
        _ = BandCheck.run(bundle: bundle, in: dir, library: "Lib", settings: settings(), now: t0.addingTimeInterval(2 * day))
        #expect(try BandTable.read(in: dir)?.entries["1"]?.misses == 0)

        // three that read before, in a row: the drive isn't reading, and the check ends
        asked = []
        let stuck = BandCheck.run(bundle: bundle, in: dir, library: "Lib", settings: settings(), now: t0.addingTimeInterval(3 * day), hash: { url, _ in
            asked.append(url.lastPathComponent)
            if url.lastPathComponent != "0" { throw POSIXError(.ETIMEDOUT) }
            return try Checksum.sha256(of: url)
        })
        #expect(asked == ["0", "1", "2", "3"], "\(asked)")
        #expect(stuck.error?.hasPrefix("data bands 1, 2 and 3 couldn't be read") == true && !stuck.failed, "\(String(describing: stuck.error))")
        #expect(BandCoverage([stuck]) == nil)

        let unlisted = BandCheck.run(bundle: dir.appendingPathComponent("Nope.sparsebundle"), in: dir, library: "Lib",
                                     settings: settings(), now: t0)
        #expect(unlisted.error != nil && !unlisted.failed)
        // a table that can't be read is said, and checking starts over from a new one
        try Data("garbage".utf8).write(to: dir.appendingPathComponent(BandTable.fileName))
        let restarted = BandCheck.run(bundle: bundle, in: dir, library: "Lib", settings: settings(), now: t0)
        #expect(restarted.error?.contains("started over") == true && !restarted.failed)
        #expect(try BandTable.read(in: dir)?.entries.count == 6)
        // the drive went away part way through: nothing is recorded
        let before = try BandTable.read(in: dir)
        let gone = BandCheck.run(bundle: bundle, in: dir, library: "Lib", settings: settings(), now: t0.addingTimeInterval(4 * day), hash: { _, _ in
            try fm.removeItem(at: bundle)
            throw POSIXError(.ENOENT)
        })
        #expect(gone.error?.contains("went away") == true && !gone.failed, "\(String(describing: gone.error))")
        #expect(try BandTable.read(in: dir) == before)
    }

    // A band that never reads (a bad sector) is tried each run, ahead of the rest, which
    // are checked past it. Three checks in a row without it reading is a warning.
    @Test func aBandThatNeverReadsIsAWarningAfterThreeChecks() throws {
        let dir = tempDir("never")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try fakeBundle(in: dir, bands: 200)
        _ = BandCheck.run(bundle: bundle, in: dir, library: "Lib", settings: settings(interval: 60 * day), now: t0)
        var reports: [BandCheckReport] = []
        var seen = Set<String>()
        for n in 1...3 {
            var asked: [String] = []
            let r = BandCheck.run(bundle: bundle, in: dir, library: "Lib", settings: settings(), now: t0.addingTimeInterval(Double(n) * day),
                                  hash: { url, _ in
                asked.append(url.lastPathComponent)
                if url.lastPathComponent == "0" { throw POSIXError(.EIO) }
                return try Checksum.sha256(of: url)
            })
            #expect(asked.first == "0", "the band that didn't read is tried again first: \(asked.prefix(3))")
            seen.formUnion(asked)
            reports.append(r)
        }
        #expect(seen.count > 64 * 2, "the check moved on past the band: \(seen.count) bands read")
        #expect((reports[1].unreadable ?? []).isEmpty, "two checks isn't yet a warning")
        #expect(reports[2].unreadable == ["0"], "\(reports[2])")
        #expect(!reports[2].failed)
        let job = BackupJob(id: "j", name: "Photos", libraries: [.genericFolder(id: "l", displayName: "Lib", path: .home("Lib"))],
                            target: .localVolume(id: "t", name: "Disk", dir: URL(fileURLWithPath: "/tmp/x")),
                            format: .liveMirror(sizeGB: 1), frequency: .daily(hour: 1, minute: 0), createdAt: t0)
        let done = JobOutcome.finished(results: [.completed(library: "Lib", destination: "Disk", parts: 1, bytes: 10, verified: nil)], warning: nil)
        let at = t0.addingTimeInterval(3 * day)
        let record = RunRecord.make(job: job, outcome: done, startedAt: at, finishedAt: at, trigger: "scheduled", bandChecks: [reports[2]])
        #expect(record.summary.contains("data band 0 hasn't read back in 3 checks in a row"), "\(record.summary)")
        let standing = ProtectionVerdict.standing(of: job, latest: record, lastGood: at, health: nil, now: at)
        #expect(standing == .bandsUnreadable && standing.level == .attention, "\(standing)")
        #expect(RunFollowUp.bandCheckRecord(record, latest: nil) == nil, "a warning, not decay")
    }

    // Pause holds the check between bands, and the time paused isn't taken from its cap.
    @Test func pauseHoldsTheCheckWithoutUsingItsTime() async throws {
        let dir = tempDir("pause")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try fakeBundle(in: dir, bands: 3)
        let control = RunControl()
        #expect(control.pause())
        let resumer = Task.detached {
            try? await Task.sleep(for: .milliseconds(400))
            control.resume()
        }
        let started = Date()
        var firstRead: Date?
        let r = BandCheck.run(bundle: bundle, in: dir, library: "Lib", settings: settings(cap: 0.2), now: t0, control: control,
                              hash: { url, c in firstRead = firstRead ?? Date(); return try Checksum.sha256(of: url, control: c) })
        await resumer.value
        #expect(try #require(firstRead).timeIntervalSince(started) >= 0.35)
        #expect(r.checked == 3 && !r.stoppedEarly, "\(r)")
    }

    @Test func aCloudFolderIsSkippedUnlessItsDownloadSettingIsOn() throws {
        let job = BackupJob(id: "j", name: "j", libraries: [.genericFolder(id: "l", displayName: "Lib", path: .home("Lib"))],
                            target: .localVolume(id: "t", name: "Disk", dir: URL(fileURLWithPath: "/tmp/x")),
                            format: .liveMirror(sizeGB: 1), frequency: .daily(hour: 1, minute: 0), createdAt: t0)
        let cloud = Target.cloudSyncFolder(id: "c", name: "iCloud", dir: URL(fileURLWithPath: "/tmp/c"), provider: .iCloud)
        #expect(BandCheckPolicy().settings(for: job, target: cloud).skip == BandCheck.cloudSkip)
        #expect(BandCheckPolicy(downloadCloud: true).settings(for: job, target: cloud).skip == nil)
        #expect(BandCheckPolicy().settings(for: job, target: job.targets[0]).skip == nil)
        #expect(BandCheckPolicy().settings(for: job, target: job.targets[0]).interval == day)
        let r = BandCheck.run(bundle: URL(fileURLWithPath: "/nonexistent"), in: URL(fileURLWithPath: "/nonexistent"),
                              library: "Lib", settings: BandCheckPolicy().settings(for: job, target: cloud))
        #expect(r.skipped != nil && !r.failed)
    }
}

// MARK: - what the run, the dashboard and the checks say

@Suite struct BandCheckReporting {

    private func job() -> BackupJob {
        BackupJob(id: "j", name: "Photos", libraries: [.genericFolder(id: "l", displayName: "Lib", path: .home("Lib"))],
                  target: .localVolume(id: "t", name: "Disk", dir: URL(fileURLWithPath: "/tmp/x")),
                  format: .liveMirror(sizeGB: 1), frequency: .daily(hour: 1, minute: 0), createdAt: t0)
    }
    private func finished() -> JobOutcome {
        .finished(results: [.completed(library: "Lib", destination: "Disk", parts: 1, bytes: 10, verified: nil)], warning: nil)
    }

    @Test func theSummarySaysHowMuchWasCheckedAndHowRecently() {
        let first = BandCheckReport(library: "Lib", destination: "Disk", total: 1_000, checked: 64, recent: 610,
                                    unverified: 390, oldestVerified: t0.addingTimeInterval(-20 * day))
        #expect(BandCheckSummary(copies: [first]).line(at: t0) == "checked 6% of the mirror for decay; 61% checked so far")
        let whole = BandCheckReport(library: "Lib", destination: "Disk", total: 1_000, checked: 34, recent: 1_000,
                                    oldestVerified: t0.addingTimeInterval(-28.5 * day))
        #expect(BandCheckSummary(copies: [whole]).line(at: t0) == "checked 3% of the mirror for decay; all of it within the last 29 days")
        #expect(BandCoverage([whole])?.line(at: t0) == "Whole mirror checked for decay within the last 29 days")
        #expect(BandCoverage([first])?.line(at: t0) == "61% of the mirror checked for decay so far")
        let few = BandCheckReport(library: "Lib", total: 64_000, checked: 89, recent: 64_000, oldestVerified: t0)
        #expect(BandCheckSummary(copies: [few]).line(at: t0).hasPrefix("checked under 1% of the mirror"))
    }

    @Test func aRunThatFoundDecayFailsAndSaysSo() {
        let bad = BandCheckReport(library: "Lib", destination: "Disk", total: 10, checked: 10, mismatches: 2,
                                  damaged: ["3", "7"], recent: 10, oldestVerified: t0)
        let r = RunRecord.make(job: job(), outcome: finished(), startedAt: t0, finishedAt: t0, trigger: "scheduled", bandChecks: [bad])
        #expect(r.outcome == .failed)
        #expect(r.summary.contains("found decay in 2 of the mirror's data bands"), "\(r.summary)")
        #expect(r.bandCheck?.mismatches == 2)
        #expect(AlertPolicy.payload(for: r, everyEvent: false)?.high == true)
        let standing = ProtectionVerdict.standing(of: job(), latest: r, lastGood: t0, health: nil, now: t0)
        #expect(standing == .decayFound && standing.level == .critical)

        let good = BandCheckReport(library: "Lib", destination: "Disk", total: 10, checked: 10, recent: 10, oldestVerified: t0)
        let ok = RunRecord.make(job: job(), outcome: finished(), startedAt: t0, finishedAt: t0, trigger: "manual", bandChecks: [good])
        #expect(ok.outcome == .completed && ok.summary.hasSuffix("; checked 100% of the mirror for decay; all of it within the last day"), "\(ok.summary)")
        let none = RunRecord.make(job: job(), outcome: finished(), startedAt: t0, finishedAt: t0, trigger: "manual")
        #expect(none.bandCheck == nil && none.summary == "1 library archived")
    }

    // A check that couldn't be made says so in the run's summary. It isn't decay: the
    // run isn't failed, the alert isn't urgent, and nothing is marked or recorded.
    @Test func aCheckThatCouldntBeMadeIsANoteNotAFailure() throws {
        let unread = BandCheckReport(library: "Lib", destination: "Disk", total: 10, checked: 1,
                                     error: "data band 1 couldn't be read (Operation timed out)")
        let r = RunRecord.make(job: job(), outcome: finished(), startedAt: t0, finishedAt: t0, trigger: "scheduled", bandChecks: [unread])
        #expect(r.outcome == .completed)
        #expect(r.summary.hasSuffix("; the mirror couldn't be checked for decay (data band 1 couldn't be read (Operation timed out))"), "\(r.summary)")
        #expect(AlertPolicy.payload(for: r, everyEvent: false) == nil)
        #expect(AlertPolicy.payload(for: r, everyEvent: true)?.high == false)
        #expect(ProtectionVerdict.standing(of: job(), latest: r, lastGood: t0, health: nil, now: t0) == .healthy)
        #expect(RunFollowUp.bandCheckRecord(r, latest: nil) == nil)
        // nor does it clear a failure of that mirror: it didn't check it
        let bad = BandCheckReport(library: "Lib", destination: "Disk", total: 10, checked: 10, mismatches: 1, damaged: ["3"])
        let failed = try #require(RunFollowUp.bandCheckRecord(
            RunRecord.make(job: job(), outcome: finished(), startedAt: t0, finishedAt: t0, trigger: "scheduled", bandChecks: [bad]), latest: nil))
        #expect(RunFollowUp.bandCheckRecord(r, latest: failed) == nil)
    }

    @Test func aFailedCheckIsRecordedAndOnlyASoundCheckOfThatMirrorClearsIt() throws {
        let bad = BandCheckReport(library: "Lib", destination: "Drive A", total: 10, checked: 10, mismatches: 1,
                                  damaged: ["3"], recent: 10, oldestVerified: t0)
        let failedRun = RunRecord.make(job: job(), outcome: finished(), startedAt: t0, finishedAt: t0, trigger: "scheduled", bandChecks: [bad])
        let failed = try #require(RunFollowUp.bandCheckRecord(failedRun, latest: nil))
        #expect(!failed.passed && failed.kind == HealthRecord.bandCheckKind)
        #expect(failed.failures == ["Lib → Drive A: data band 3 no longer reads back as it was written; start this mirror over"])
        #expect(ProtectionVerdict.standing(of: job(), latest: nil, lastGood: t0, health: failed, now: t0) == .decayFound)

        func clean(_ dest: String) -> RunRecord {
            RunRecord.make(job: job(), outcome: finished(), startedAt: t0, finishedAt: t0.addingTimeInterval(day), trigger: "scheduled",
                           bandChecks: [BandCheckReport(library: "Lib", destination: dest, total: 10, checked: 10, recent: 10, oldestVerified: t0)])
        }
        // the rotation's other drive passing says nothing about this one
        #expect(RunFollowUp.bandCheckRecord(clean("Drive B"), latest: failed) == nil)
        let cleared = try #require(RunFollowUp.bandCheckRecord(clean("Drive A"), latest: failed))
        #expect(cleared.passed && cleared.kind == HealthRecord.bandCheckKind)
        // nothing to clear: nothing recorded
        #expect(RunFollowUp.bandCheckRecord(clean("Drive A"), latest: cleared) == nil)
    }

    // Moving the job to another drive, or dropping the damaged one, is the other way
    // out: the failure of a mirror the job no longer writes doesn't stand.
    @Test func aFailureOfAMirrorTheJobNoLongerWritesIsCleared() throws {
        let bad = BandCheckReport(library: "Lib", destination: "Drive A", total: 10, checked: 10, mismatches: 1, damaged: ["3"])
        let failed = try #require(RunFollowUp.bandCheckRecord(
            RunRecord.make(job: job(), outcome: finished(), startedAt: t0, finishedAt: t0, trigger: "scheduled", bandChecks: [bad]), latest: nil))
        let driveA = Target.localVolume(id: "a", name: "Drive A", dir: URL(fileURLWithPath: "/tmp/a"))
        let driveB = Target.localVolume(id: "b", name: "Drive B", dir: URL(fileURLWithPath: "/tmp/b"))
        var moved = job(); moved.targets = [driveB]
        let onB = RunRecord.make(job: moved, outcome: finished(), startedAt: t0, finishedAt: t0.addingTimeInterval(day), trigger: "scheduled",
                                 bandChecks: [BandCheckReport(library: "Lib", destination: "Drive B", total: 10, checked: 10, recent: 10, oldestVerified: t0)])
        #expect(RunFollowUp.bandCheckRecord(onB, latest: failed, job: moved)?.passed == true)
        // still one of the job's drives (a rotation): it stands
        var both = job(); both.targets = [driveA, driveB]
        #expect(RunFollowUp.bandCheckRecord(onB, latest: failed, job: both) == nil)
    }

    @Test func aDestinationsRunsCarryTheirCoverage() {
        let older = DestinationRun(at: t0, good: true, bytes: 1, seconds: 1, freeAfter: nil, checkPassed: nil,
                                   bands: BandCoverage(total: 10, recent: 5, unverified: 5, oldest: t0))
        let newest = DestinationRun(at: t0.addingTimeInterval(day), good: true, bytes: 1, seconds: 1, freeAfter: nil, checkPassed: nil)
        let trend = DestinationTrend([newest, older])
        #expect(trend?.bands?.unverified == 5 && trend?.bandsAt == t0)
    }
}

// MARK: - on real disk images

@Suite(.serialized) struct BandCheckOnImages {

    private func create(_ image: URL, passphrase: String? = nil) throws {
        var args = ["create", "-size", "60m", "-type", "SPARSEBUNDLE", "-fs", "APFS", "-volname", "Bands",
                    "-imagekey", "sparse-band-size=2048", image.path]
        if passphrase != nil { args += ["-encryption", "AES-256", "-stdinpass"] }
        let r = try TestDiskImages.run(args, stdin: passphrase.map { Data($0.utf8) })
        try #require(r.ok, "\(r.stderr)")
    }

    // Ciphertext is what is on the drive: no passphrase, nothing attached.
    @Test func anEncryptedMirrorIsCheckedWithoutItsPassphrase() throws {
        let dir = tempDir("enc")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = dir.appendingPathComponent("Lib.sparsebundle", isDirectory: true)
        try create(bundle, passphrase: "correct horse battery")
        let s = BandCheck.Settings(interval: 30 * day)
        let first = BandCheck.run(bundle: bundle, in: dir, library: "Lib", settings: s, now: t0)
        #expect(first.total > 0 && first.checked == first.total && first.unverified == 0 && !first.failed, "\(first)")
        let band = try #require(try BandCheck.stats(of: bundle).first { $0.size > 64 && $0.name != "0" })
        try rot(bundle.appendingPathComponent("bands").appendingPathComponent(band.name))
        let second = BandCheck.run(bundle: bundle, in: dir, library: "Lib", settings: s, now: t0.addingTimeInterval(day))
        #expect(second.damaged == [band.name], "\(second)")
    }

    // A whole mirror, run by the engine: a byte flipped in a band the runs don't write
    // is reported, marks the mirror damaged, is refused by the next run, and Start
    // This Mirror Over makes a new one.
    @Test func decayInAMirrorIsReportedRefusedAndStartedOver() throws {
        let fm = FileManager.default
        let base = tempDir("mirror"), mnt = tempDir("mnt")
        let lib = base.appendingPathComponent("Lib"), out = base.appendingPathComponent("dest/Lib")
        defer { for d in [base, mnt] { try? fm.removeItem(at: d) } }
        try fm.createDirectory(at: lib, withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0, count: 24 << 20)
        for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: i &* 2_654_435_761 >> 13) }
        try Data(bytes).write(to: lib.appendingPathComponent("big.bin"))
        for i in 0..<5 { try Data("small \(i)".utf8).write(to: lib.appendingPathComponent("f\(i).txt")) }
        let engine = SparseBundleMirrorEngine(sizeGB: 1, mountBase: mnt, bandCheck: BandCheck.Settings(interval: 30 * day))
        let source = ArchiveSource(name: "Lib", root: lib)

        let first = try engine.archive(source, to: out)
        let bundle = first.artifacts[0]
        #expect(first.bandCheck.map { $0.total > 0 && $0.unverified == 0 && !$0.failed } == true, "\(String(describing: first.bandCheck))")
        let before = try BandCheck.stats(of: bundle)
        let second = try engine.archive(source, to: out)
        #expect(second.bandCheck?.mismatches == 0)
        // a band neither run wrote after the first: file data, not the volume's metadata
        let after = Dictionary(uniqueKeysWithValues: try BandCheck.stats(of: bundle).map { ($0.name, $0) })
        let still = before.filter { $0.name != "0" && $0.size == 8 << 20 && after[$0.name] == $0 }
        let victim = try #require(still.dropFirst(still.count / 2).first, "no band left untouched: \(before) \(after)")
        try rot(bundle.appendingPathComponent("bands").appendingPathComponent(victim.name))

        let third = try engine.archive(source, to: out)
        #expect(third.bandCheck?.damaged == [victim.name], "\(String(describing: third.bandCheck))")
        #expect(MirrorSeal.isDecayed(out) && MirrorSeal.damage(in: out) != nil)
        // the damaged marker gone (1.7 clears it when fsck passes): decay still stands
        let marker = out.appendingPathComponent(MirrorSeal.damagedMarkerName)
        let saved = try Data(contentsOf: marker)
        try fm.removeItem(at: marker)
        #expect(MirrorSeal.damage(in: out) == MirrorSeal.decayReason([victim.name]))
        try saved.write(to: marker)
        let check = try ChecksumVerifier().reverify(archiveDir: out)
        #expect(!check.passed && check.details.contains("changed on its drive"), "\(check.details)")
        #expect {
            _ = try engine.archive(source, to: out)
        } throws: { error in
            guard case MirrorCopyError.imageDecayed = error else { return false }
            return error.localizedDescription.contains("Start This Mirror Over")
        }

        try MirrorSeal.requestStartOver(out)
        let fresh = try engine.archive(source, to: out)
        #expect(fresh.bandCheck.map { !$0.failed } == true)
        #expect(!MirrorSeal.isDecayed(out) && MirrorSeal.damage(in: out) == nil && !MirrorSeal.startOverRequested(out))
        #expect(!fm.fileExists(atPath: MirrorSeal.replaced(bundle).path))     // removed once the new one sealed
        #expect(try ChecksumVerifier().reverify(archiveDir: out).passed)
    }

    // A job's run checks the mirror it writes, and hands what it found to its record.
    @Test func aJobRunChecksItsMirrorAndItsRecordSaysSo() async throws {
        let base = tempDir("run")
        let mnt = base.appendingPathComponent("vol")
        try FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)
        // the library on a volume that isn't APFS, so the run reads it where it is (no
        // snapshot), as the fake helper can't make one
        let made = try TestDiskImages.run(["create", "-size", "20m", "-fs", "HFS+", "-volname", "Src",
                                           base.appendingPathComponent("src.dmg").path])
        try #require(made.ok, "\(made.stderr)")
        let attached = try DiskImageGate.serialized {
            try TestDiskImages.run(["attach", base.appendingPathComponent("src.dmg").path,
                                    "-mountpoint", mnt.path, "-nobrowse", "-owners", "on"])
        }
        try #require(attached.ok && MountPoint.isMounted(mnt), "\(attached.stderr)")
        defer {
            MountPoint.detach(mnt, runner: ProcessCommandRunner())
            try? FileManager.default.removeItem(at: base)
        }
        let lib = mnt.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: lib.appendingPathComponent("main.swift"))
        let dest = base.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let projects = ContentType.genericFolder(id: "projects", displayName: "Projects", path: .absolute(lib.path))
        let job = BackupJob(name: "Projects", libraries: [projects], target: .localVolume(id: "d", name: "Dest", dir: dest),
                            format: .liveMirror(sizeGB: 1), frequency: .manual, createdAt: Date(timeIntervalSince1970: 0))
        let exec = JobExecutor(helper: FakePrivilegedHelper(), detector: FakeProcessDetector(),
                               scratchBase: base.appendingPathComponent("scratch"), bandChecks: BandCheckPolicy())
        let control = RunControl()
        let outcome = try await exec.run(job, ownerUID: getuid(), now: Date(), control: control)
        let checks = control.bandChecks
        #expect(checks.count == 1 && checks.first?.library == "Projects" && checks.first?.destination == "Dest", "\(checks)")
        #expect(checks.first.map { $0.total > 0 && !$0.failed } == true)
        let record = RunRecord.make(job: job, outcome: outcome, startedAt: Date(), finishedAt: Date(), trigger: "manual",
                                    bandChecks: checks)
        #expect(record.outcome.isGood && record.summary.contains("of the mirror for decay"), "\(record.summary)")
    }

    // A request to start over a mirror that isn't damaged is dropped, and the image
    // is used as it is.
    @Test func startingOverASoundMirrorDoesNothing() throws {
        let dir = tempDir("sound")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try fakeBundle(in: dir, bands: 2)
        try MirrorSeal.requestStartOver(dir)
        try MirrorSeal.startOverIfAsked(bundle, in: dir, runner: ProcessCommandRunner())
        #expect(FileManager.default.fileExists(atPath: bundle.path) && !MirrorSeal.startOverRequested(dir))
    }
}

// MARK: - starting a mirror over

// The damaged image is kept until the new one is complete, so starting over needs
// room for both. That is known before anything starts, and a start over that can't
// fit is never left half built behind the old image.
@Suite struct StartingOverRoom {

    private let fm = FileManager.default
    private let copy: UInt64 = 1_000_000
    private var need: UInt64 { copy + copy / 20 }

    private func refusal(_ bundle: URL, _ free: UInt64?) -> String? {
        JobExecutor.startOverRefusal(bundle, in: bundle.deletingLastPathComponent(), destination: "Disk", copyBytes: copy, free: free)
    }

    @Test func aStartOverThatWontFitBesideTheDamagedMirrorIsRefusedBeforeItBegins() throws {
        let dir = tempDir("room")
        defer { try? fm.removeItem(at: dir) }
        let bundle = try fakeBundle(in: dir, bands: 2)
        MirrorSeal.markDamaged(dir, why: "x")
        #expect(refusal(bundle, 0) == nil)                  // nothing asked: not this check's business
        try MirrorSeal.requestStartOver(dir)
        let refused = try #require(refusal(bundle, need - 1))
        #expect(refused.hasPrefix("not enough space on Disk to start the mirror over beside the damaged one"), "\(refused)")
        #expect(refused.contains("remove the damaged mirror first"))
        #expect(refusal(bundle, need) == nil)
        #expect(refusal(bundle, nil) == nil)                // a drive that doesn't say what's free
        // removing the damaged one first counts the room it gives back
        let old = JobExecutor.directorySize(bundle)
        try MirrorSeal.requestStartOver(dir, removingDamagedFirst: true)
        #expect(refusal(bundle, need - old) == nil)
        #expect(refusal(bundle, need - old - 1)?.contains("even with the damaged one removed") == true)
        #expect(fm.fileExists(atPath: bundle.path) && MirrorSeal.startOverRequested(dir))   // refused: nothing touched
    }

    @Test func removingTheDamagedMirrorFirstDeletesItBeforeTheNewOneIsMade() throws {
        let dir = tempDir("remove")
        defer { try? fm.removeItem(at: dir) }
        let bundle = try fakeBundle(in: dir, bands: 2)
        MirrorSeal.markDamaged(dir, why: "x")
        MirrorSeal.markDecayed(dir, bands: ["1"])
        try BandTable().write(in: dir)
        try Data().write(to: dir.appendingPathComponent(ArchiveManifest.sidecarName))
        try MirrorSeal.requestStartOver(dir, removingDamagedFirst: true)
        try MirrorSeal.startOverIfAsked(bundle, in: dir, runner: ProcessCommandRunner())
        #expect(!fm.fileExists(atPath: bundle.path) && !fm.fileExists(atPath: MirrorSeal.replaced(bundle).path))
        #expect(MirrorSeal.damage(in: dir) == nil && !MirrorSeal.isDecayed(dir) && !MirrorSeal.startOverRequested(dir))
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent(ArchiveManifest.sidecarName).path))
        #expect(try BandTable.read(in: dir) == nil)
    }

    // The first start over put the damaged image aside, and the drive filled before
    // the new one was complete.
    @Test func anUnfinishedStartOverIsNeverStuckBehindTheOldImage() throws {
        let base = tempDir("underway")
        defer { try? fm.removeItem(at: base) }
        let lib = ContentType.genericFolder(id: "l", displayName: "Lib", path: .home("Lib"))
        let target = Target.localVolume(id: "t", name: "Disk", dir: base)
        let job = BackupJob(id: "j", name: "Lib", libraries: [lib], target: target, format: .liveMirror(sizeGB: 1),
                            frequency: .daily(hour: 1, minute: 0), createdAt: t0)
        let dir = base.appendingPathComponent("Lib")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try LibraryIdentity(job: job, library: lib).write(in: dir)
        let bundle = try fakeBundle(in: dir, bands: 2)
        MirrorSeal.markDamaged(dir, why: "x")
        try MirrorSeal.requestStartOver(dir)
        try MirrorSeal.startOverIfAsked(bundle, in: dir, runner: ProcessCommandRunner())
        let aside = MirrorSeal.replaced(bundle)
        #expect(fm.fileExists(atPath: aside.path) && !fm.fileExists(atPath: bundle.path))
        let partial = try fakeBundle(in: dir, bands: 1)

        // the next run, asked nothing, says why it can't go on and what to do
        let held = try #require(refusal(partial, 0))
        #expect(held.contains("still kept") && held.contains("remove the damaged mirror from Storage"), "\(held)")
        // what the new one already holds counts, and it carries on from there
        #expect(refusal(partial, need - JobExecutor.directorySize(partial)) == nil)
        // Storage lists it, with what removing the old one would free
        let listed = try #require(MirrorSeal.damaged(job: job, target: target, freeSpace: { _ in 0 }).first)
        #expect(listed.underWay && !listed.imageDamaged && listed.oldBytes == JobExecutor.directorySize(aside), "\(listed)")
        #expect(!listed.roomBeside)

        // removed first: the old image goes, and the half-built one stays to be finished
        try MirrorSeal.requestStartOver(dir, removingDamagedFirst: true)
        try MirrorSeal.startOverIfAsked(partial, in: dir, runner: ProcessCommandRunner())
        #expect(!fm.fileExists(atPath: aside.path) && fm.fileExists(atPath: partial.path) && !MirrorSeal.startOverRequested(dir))
        #expect(refusal(partial, 0) == nil)
        #expect(MirrorSeal.damaged(job: job, target: target).isEmpty)
    }

    // An old image left aside after the new mirror sealed (its removal failed) is the
    // one a later start over removes, not the newer mirror.
    @Test func aLeftoverOldImageIsRemovedRatherThanTheNewerMirror() throws {
        let dir = tempDir("leftover")
        defer { try? fm.removeItem(at: dir) }
        let bundle = try fakeBundle(in: dir, bands: 2)
        try Data("new".utf8).write(to: bundle.appendingPathComponent("which"))
        let aside = MirrorSeal.replaced(bundle)
        try fm.createDirectory(at: aside, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: aside.appendingPathComponent("which"))
        try Data().write(to: dir.appendingPathComponent(ArchiveManifest.sidecarName))   // the new one sealed since
        MirrorSeal.markDamaged(dir, why: "x")
        try MirrorSeal.requestStartOver(dir)
        try MirrorSeal.startOverIfAsked(bundle, in: dir, runner: ProcessCommandRunner())
        #expect(try String(contentsOf: aside.appendingPathComponent("which"), encoding: .utf8) == "new")
        #expect(!fm.fileExists(atPath: bundle.path))
    }
}
