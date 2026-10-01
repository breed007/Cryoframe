//
//  CancelableCheckTests.swift
//  CryoframeKitTests
//
//  Stop on a check of a job's archives (checksums, a restore drill, a recovery
//  rehearsal). A stopped check is not a check: it never becomes the job's latest
//  record, never raises an alert, and never reads as a pass to 1.5.6, which reads the
//  same archive-health.json. An attach Stop finds in flight is let finish and then
//  closed, never signaled.
//

import Testing
import Foundation
@testable import CryoframeKit

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-cancelcheck-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

/// a job of three libraries, each sealed once at <base>/dest/<name>
private func threeLibraries(_ base: URL, _ kind: SealedArchiveEngine.Sealed = .zip) throws -> BackupJob {
    var libraries: [ContentType] = []
    for name in ["Alpha", "Bravo", "Charlie"] {
        let lib = base.appendingPathComponent("src/\(name)")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try Data("inside \(name)".utf8).write(to: lib.appendingPathComponent("a.txt"))
        let dir = base.appendingPathComponent("dest/\(name)")
        let result = try SealedArchiveEngine(kind).archive(ArchiveSource(name: name, root: lib), to: dir)
        try ArchiveManifest.write(try ArchiveManifest.build(for: result, encrypted: false), toDir: dir)
        libraries.append(.genericFolder(id: name.lowercased(), displayName: name, path: .absolute(lib.path)))
    }
    let target = Target.localVolume(id: "d", name: "Backups", dir: base.appendingPathComponent("dest"))
    return BackupJob(name: "Nightly", libraries: libraries, target: target, format: kind == .zip ? .sealedZip : .sealedDMG,
                     frequency: .daily(hour: 2, minute: 0), createdAt: Date(timeIntervalSince1970: 0))
}

/// The run's runner, pressing Stop at a chosen moment: `before` is asked about each
/// command as it is about to start, and Stop is pressed when it says so (the command
/// then isn't started, as after any Stop); `during` likewise, but Stop is pressed a
/// moment after the command has started.
private struct StopAt: CommandRunner {
    let inner: ProcessCommandRunner
    let before: @Sendable (String, [String]) -> Bool
    let during: @Sendable (String, [String]) -> Bool
    init(_ control: RunControl, before: @escaping @Sendable (String, [String]) -> Bool = { _, _ in false },
         during: @escaping @Sendable (String, [String]) -> Bool = { _, _ in false }) {
        inner = ProcessCommandRunner(control: control); self.before = before; self.during = during
    }
    var control: RunControl? { inner.control }
    var forTeardown: CommandRunner { inner.forTeardown }
    func run(_ launchPath: String, _ args: [String], stdin: Data?) throws -> CommandResult {
        if before(launchPath, args) { inner.control?.cancel() }
        if during(launchPath, args) {
            let control = inner.control
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { control?.cancel() }
        }
        return try inner.run(launchPath, args, stdin: stdin)
    }
}

/// counts calls across the runner's copies
private final class Count: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}

private func isUnpack(_ tool: String, _ args: [String]) -> Bool { tool.hasSuffix("ditto") && args.first == "-x" }

@Suite(.serialized) struct CancelableCheckTests {

    // MARK: the drill

    // Stop as the second archive starts: the first archive's drill counts, the
    // second's (cut short) doesn't, the third is never started, and the report says
    // it was stopped, after 1 of 3.
    @Test func stopBetweenArchivesEndsTheDrillThere() throws {
        let base = folder("drill")
        defer { try? FileManager.default.removeItem(at: base) }
        let job = try threeLibraries(base)
        let control = RunControl(), unpacks = Count()
        let runner = StopAt(control, before: { tool, args in isUnpack(tool, args) && unpacks.next() == 2 })
        let report = RestoreDriller(runner: runner, freeSpace: { _ in 1 << 40 }).drill(job: job)
        #expect(report.canceled)
        #expect(report.planned == 3)
        #expect(report.checks.map(\.library) == ["Alpha"], "\(report.checks)")
        #expect(report.checks.first?.passed == true)
    }

    // Stop before anything: nothing checked, and nothing reads as checked.
    @Test func stopBeforeTheDrillStartsChecksNothing() throws {
        let base = folder("early")
        defer { try? FileManager.default.removeItem(at: base) }
        let job = try threeLibraries(base)
        let control = RunControl()
        control.cancel()
        let report = RestoreDriller(runner: ProcessCommandRunner(control: control), freeSpace: { _ in 1 << 40 }).drill(job: job)
        #expect(report.canceled && report.checks.isEmpty && report.planned == 3)
    }

    // Stop while a disk image is being attached: the attach isn't signaled, it is let
    // finish, and the image is then detached; the work folder goes too. The archive
    // whose open Stop came in isn't counted, as a pass or a failure.
    @Test func stopDuringAnAttachLetsItFinishAndClosesIt() throws {
        let base = folder("attach")
        defer { try? FileManager.default.removeItem(at: base) }
        let job = try threeLibraries(base, .dmg)
        let before = Set(Self.openWorkDirs())
        let control = RunControl(), attaches = Count()
        let runner = StopAt(control, during: { tool, args in tool.hasSuffix("hdiutil") && args.first == "attach" && attaches.next() == 1 })
        let report = RestoreDriller(runner: runner, freeSpace: { _ in 1 << 40 }).drill(job: job)
        #expect(report.canceled)
        #expect(report.checks.isEmpty, "the archive Stop came in was counted: \(report.checks)")
        // nothing of the drill's is left attached or on disk. Only the image the drill
        // opened (Alpha's) is looked for: macOS attaches each fresh image by itself to
        // scan it, and under load its attach of the others can outlast the test (seen:
        // Bravo's, never opened by the drill, held by a "system-image" attach). Its scan
        // of Alpha's goes; a leftover of the drill's doesn't.
        let opened = base.appendingPathComponent("dest/Alpha/Alpha.dmg").path
        let until = Date().addingTimeInterval(30)
        var info = ""
        repeat {
            info = try ProcessCommandRunner().run("/usr/bin/hdiutil", ["info"]).stdout
            if !info.contains(opened) { break }
            Thread.sleep(forTimeInterval: 1)
        } while Date() < until
        #expect(!info.contains(opened), "the drill's image was left attached:\n\(info)")
        #expect(Set(Self.openWorkDirs()).subtracting(before).isEmpty, "a work folder was left")
    }

    /// this process's open-archive work folders (another process's tests share the folder)
    static func openWorkDirs() -> [String] {
        let tmp = FileManager.default.temporaryDirectory
        return ((try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [])
            .filter { $0.hasPrefix(OpenedArchive.workPrefix) }
            .filter { name in
                let owner = tmp.appendingPathComponent(name).appendingPathComponent(OpenedArchive.ownerFileName)
                guard let data = try? Data(contentsOf: owner),
                      let who = try? JSONDecoder().decode(ProcessIdentity.self, from: data) else { return false }
                return who.pid == getpid()
            }
    }

    // MARK: the checksum check and the rehearsal

    @Test func stopEndsAChecksumCheckBetweenArchives() throws {
        let base = folder("checksum")
        defer { try? FileManager.default.removeItem(at: base) }
        let job = try threeLibraries(base)
        let control = RunControl()
        control.cancel()
        let report = HealthChecker().check(job: job, control: control)
        #expect(report.canceled && report.checks.isEmpty && report.planned == 3)
        let whole = HealthChecker().check(job: job, control: RunControl())
        #expect(!whole.canceled && whole.passed && whole.checks.count == 3 && whole.planned == 3)
    }

    // Hashing a large archive on a slow drive takes minutes: Stop ends it.
    @Test func stopEndsHashing() throws {
        let base = folder("hash")
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("big")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        try #require(truncate(file.path, 200 << 20) == 0)
        let control = RunControl()
        control.cancel()
        #expect(throws: CancelledError.self) { _ = try Checksum.sha256(of: file, control: control) }
        #expect(try Checksum.sha256(of: file, control: RunControl()) == Checksum.sha256(of: file))
    }

    @Test func stopBetweenLibrariesEndsTheRehearsalThere() throws {
        let base = folder("rehearse")
        defer { try? FileManager.default.removeItem(at: base) }
        _ = try threeLibraries(base)
        let control = RunControl(), unpacks = Count()
        let runner = StopAt(control, before: { tool, args in isUnpack(tool, args) && unpacks.next() == 2 })
        let report = RecoveryRehearsal(runner: runner, freeSpace: { _ in 1 << 40 })
            .rehearse(destination: base.appendingPathComponent("dest"), expecting: ["Alpha", "Bravo", "Charlie", "Delta"])
        #expect(report.canceled && report.planned == 3)
        #expect(report.outcomes.count == 1 && report.outcomes.allSatisfy(\.ok), "\(report.outcomes)")
        // a stopped rehearsal says what it opened, and keeps the missing library a
        // finished one reports as a failure: it was found before anything was opened
        let health = report.asHealthReport(multiDestination: false)
        #expect(health.canceled && health.checks.count == 2 && health.planned == 4, "\(health.checks.map(\.library)) \(health.planned)")
        #expect(health.checks.contains { $0.library == "Delta" && !$0.passed })
    }

    // MARK: recording

    // The job's last finished check stands: archive-health.json is untouched, so
    // HealthStore.latest(forJob:), the verdict and 1.5.6 (which reads that file) see
    // it; a stopped check of nothing raises no "no archives found" alert, because no
    // record exists to raise it from.
    @Test func aStoppedCheckIsNeverTheJobsLatestCheck() throws {
        let base = folder("record")
        defer { try? FileManager.default.removeItem(at: base) }
        let job = try threeLibraries(base)
        let health = HealthStore(url: base.appendingPathComponent("archive-health.json"))
        let canceled = CanceledCheckStore(url: base.appendingPathComponent("canceled-checks.json"))
        let finished = HealthChecker().check(job: job)
        guard case .recorded(let good) = CheckRecording.record(finished, job: job, kind: "checksum", at: Date(timeIntervalSince1970: 1000),
                                                               health: health, canceled: canceled) else {
            Issue.record("a finished check wasn't recorded"); return
        }
        let bytes = try Data(contentsOf: base.appendingPathComponent("archive-health.json"))

        for report in [HealthReport(checks: [], canceled: true, planned: 3),
                       HealthReport(checks: [ArchiveCheck(library: "Alpha", version: nil, passed: false, detail: "checksum mismatch")],
                                    canceled: true, planned: 3)] {
            guard case .canceled(let stopped) = CheckRecording.record(report, job: job, kind: "drill", at: Date(timeIntervalSince1970: 2000),
                                                                       trigger: "scheduled", health: health, canceled: canceled) else {
                Issue.record("a stopped check was recorded as a check"); return
            }
            #expect(stopped.jobID == job.id && stopped.planned == 3)
        }
        #expect(try Data(contentsOf: base.appendingPathComponent("archive-health.json")) == bytes, "the health file changed")
        #expect(health.latest(forJob: job.id)?.id == good.id)
        #expect(health.all().count == 1)
        #expect(canceled.all().count == 2)
        // how 1.5.6 reads that file: an array of records, the newest first
        struct Record156: Decodable { let id: String; let archivesChecked: Int; let failures: [String] }
        let as156 = try JSONDecoder().decode([Record156].self, from: bytes)
        #expect(as156.map(\.id) == [good.id] && as156[0].archivesChecked == 3 && as156[0].failures.isEmpty)
    }

    @Test func theStoppedChecksListKeepsTheLastTwenty() {
        let base = folder("cap")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = CanceledCheckStore(url: base.appendingPathComponent("canceled-checks.json"))
        for i in 0..<25 {
            store.append(CanceledCheck(jobID: "j\(i)", jobName: "J", kind: "drill", stoppedAt: Date(), finished: 0, planned: 1,
                                       failures: [], skipped: 0, trigger: "manual"))
        }
        #expect(store.all().count == CanceledCheckStore.defaultCap)
        #expect(store.all().first?.jobID == "j24")
    }

    @Test func whatAStoppedCheckSays() {
        func say(_ kind: String, _ finished: Int, _ planned: Int, failed: Int = 0, skipped: Int = 0) -> String {
            CanceledCheck(jobID: "j", jobName: "J", kind: kind, stoppedAt: Date(), finished: finished, planned: planned,
                          failures: Array(repeating: "x", count: failed), skipped: skipped, trigger: "manual").summary
        }
        #expect(say("drill", 3, 7) == "Stopped after 3 of 7; those 3 opened")
        #expect(say("drill", 1, 7) == "Stopped after 1 of 7; it opened")
        #expect(say("checksum", 2, 5) == "Stopped after 2 of 5; those 2 matched their checksums")
        #expect(say("drill", 0, 7) == "Stopped before any of its 7 archives was checked")
        #expect(say("rehearsal", 0, 1) == "Stopped before any of its 1 library was checked")
        #expect(say("drill", 3, 7, failed: 1) == "Stopped after 3 of 7; 2 opened, 1 failed")
        #expect(say("drill", 3, 7, skipped: 1) == "Stopped after 3 of 7; 2 opened, 1 skipped")
    }

    // MARK: Stop from another process

    // The scheduled agent checks under the job's lock; Stop pressed in the app asks
    // the lock's holder to stop (RunLocks.requestStop), and the check hears it.
    @Test func stopPressedElsewhereReachesACheck() throws {
        let base = folder("lock")
        defer { try? FileManager.default.removeItem(at: base) }
        let locks = RunLocks(directory: base)
        let control = RunControl()
        let heard = locks.whileChecking(jobID: "job", control: control) { () -> Bool in
            #expect(locks.requestStop(jobID: "job"))
            let until = Date().addingTimeInterval(10)
            while !control.isCancelled, Date() < until { Thread.sleep(forTimeInterval: 0.05) }
            return control.isCancelled
        }
        guard case .done(let stopped) = heard else { Issue.record("the check didn't get the lock: \(heard)"); return }
        #expect(stopped, "the check never heard Stop")
    }
}
