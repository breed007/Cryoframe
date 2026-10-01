//
//  StoppedCheckFixTests.swift
//  CryoframeKitTests
//
//  A stopped check keeps what it found: its failures alert, a rehearsal's missing
//  libraries stay, its "of N" counts every destination, and its line on the job's
//  row never hides a failed last check.
//

import Testing
import Foundation
@testable import CryoframeKit

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-stopfix-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

private final class Fired: @unchecked Sendable {
    private let lock = NSLock(); private var set = false
    func raise() { lock.lock(); set = true; lock.unlock() }
    var raised: Bool { lock.lock(); defer { lock.unlock() }; return set }
}

/// Stop pressed a moment after the first command `when` picks starts
private struct StopAtFirst: CommandRunner {
    let inner: ProcessCommandRunner
    let when: @Sendable (String, [String]) -> Bool
    let fired = Fired()
    init(_ control: RunControl, when: @escaping @Sendable (String, [String]) -> Bool) {
        inner = ProcessCommandRunner(control: control); self.when = when
    }
    var control: RunControl? { inner.control }
    var forTeardown: CommandRunner { inner.forTeardown }
    func run(_ launchPath: String, _ args: [String], stdin: Data?) throws -> CommandResult {
        if !fired.raised, when(launchPath, args) {
            fired.raise()
            let control = inner.control
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { control?.cancel() }
        }
        return try inner.run(launchPath, args, stdin: stdin)
    }
}

/// libraries `names`, each sealed once as a zip at <dest>/<name>
private func sealedZips(_ base: URL, dest: URL, names: [String]) throws {
    for name in names {
        let lib = base.appendingPathComponent("src-\(UUID().uuidString)/\(name)")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        var data = Data(count: 40 << 20)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, 40 << 20) }
        try data.write(to: lib.appendingPathComponent("a.bin"))
        let dir = dest.appendingPathComponent(name)
        let result = try SealedArchiveEngine(.zip).archive(ArchiveSource(name: name, root: lib), to: dir)
        try ArchiveManifest.write(try ArchiveManifest.build(for: result, encrypted: false), toDir: dir)
    }
}

private func health(_ passed: Bool, checked: Int, at: TimeInterval) -> HealthRecord {
    HealthRecord(jobID: "j", jobName: "Nightly", checkedAt: Date(timeIntervalSince1970: at),
                 archivesChecked: checked, failures: passed ? [] : ["Alpha: checksums don't match"])
}

private func stopped(at: TimeInterval, failures: [String] = []) -> CanceledCheck {
    CanceledCheck(jobID: "j", jobName: "Nightly", kind: "checksum", stoppedAt: Date(timeIntervalSince1970: at),
                  finished: 1 + failures.count, planned: 5, failures: failures, skipped: 0, trigger: "manual")
}

@Suite(.serialized) struct StoppedCheckFixTests {

    // A rehearsal of two destinations stopped in the first counts the second's
    // libraries in its "of N", and keeps a library the first can't find.
    @Test func aStoppedRehearsalCountsEveryDestinationAndKeepsWhatsMissing() throws {
        let base = folder("reh")
        defer { try? FileManager.default.removeItem(at: base) }
        let first = base.appendingPathComponent("first"), second = base.appendingPathComponent("second")
        try sealedZips(base, dest: first, names: ["Alpha", "Bravo"])
        try sealedZips(base, dest: second, names: ["Alpha", "Bravo", "Charlie"])
        let control = RunControl()
        let runner = StopAtFirst(control) { tool, args in tool.hasSuffix("ditto") && args.first == "-x" }
        let report = RecoveryRehearsal(runner: runner, freeSpace: { _ in 1 << 40 })
            .rehearse([.init(destination: first), .init(destination: second)], expecting: ["Alpha", "Bravo", "Charlie"],
                      multiDestination: true)
        #expect(report.canceled)
        // first: 2 to open and Charlie missing; second: 3 to open
        #expect(report.planned == 6, "planned \(report.planned)")
        let missing = report.checks.filter { $0.version == nil && !$0.passed }
        #expect(missing.map(\.library) == ["Charlie"], "\(report.checks.map(\.library))")
        let job = BackupJob(name: "Nightly", libraries: [], target: .localVolume(id: "d", name: "first", dir: first),
                            format: .sealedZip, frequency: .manual, createdAt: Date(timeIntervalSince1970: 0))
        let c = CanceledCheck.from(job: job, report: report, at: Date(), kind: "rehearsal", trigger: "manual")
        #expect(c.planned == 6 && c.summary.contains("of 6"), "\(c.summary)")
        #expect(!c.failures.isEmpty, "the missing library was dropped")
        #expect(AlertPolicy.payload(forStopped: c)?.high == true)
    }

    // What a stopped check found failing is alerted; one that found nothing isn't.
    @Test func aStoppedChecksFailuresAlert() {
        #expect(AlertPolicy.payload(forStopped: stopped(at: 10)) == nil)
        let p = AlertPolicy.payload(forStopped: stopped(at: 10, failures: ["Alpha: checksums don't match"]))
        #expect(p?.high == true && p?.body.contains("1 archive check failed") == true && p?.body.contains("Alpha") == true, "\(p?.body ?? "nil")")
        let outcome = CheckRecording.Outcome.canceled(stopped(at: 10, failures: ["Alpha: x", "Bravo: y"]))
        #expect(outcome.alert(everyEvent: false)?.body.contains("2 archive checks failed") == true)
        #expect(CheckRecording.Outcome.canceled(stopped(at: 10)).alert(everyEvent: true) == nil)
    }

    // The stopped line never stands in for a last check that failed or found nothing.
    @Test func theStoppedLineNeverHidesAFailedLastCheck() {
        #expect(CheckLines.shown(last: health(true, checked: 3, at: 5), stopped: stopped(at: 10)) == (false, true))
        #expect(CheckLines.shown(last: health(false, checked: 3, at: 5), stopped: stopped(at: 10)) == (true, true))
        #expect(CheckLines.shown(last: health(true, checked: 0, at: 5), stopped: stopped(at: 10)) == (true, true))
        #expect(CheckLines.shown(last: health(false, checked: 3, at: 20), stopped: stopped(at: 10)) == (true, false))
        #expect(CheckLines.shown(last: nil, stopped: stopped(at: 10)) == (false, true))
        #expect(CheckLines.shown(last: health(true, checked: 3, at: 5), stopped: nil) == (true, false))
    }
}
