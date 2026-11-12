//
//  EngineReviewFixTests.swift
//  CryoframeKitTests
//
//  What the review of the 1.8.0 engines found, each as the case that went wrong: a
//  library whose mirror was found decayed counted as a completed copy, an image that
//  couldn't be shown to be detached was sealed as closed, removing a damaged mirror
//  first took its history without saying so, and Storage showed about nothing for
//  the entry that holds a whole old image.
//

import Testing
import Foundation
@testable import CryoframeKit

private func tempDir(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-review-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return TempTracker.track(d)
}

private let day: TimeInterval = 86_400
private let start = Date(timeIntervalSince1970: 1_789_948_800)

/// a sparsebundle's folder with `bands` small bands, in `dir`
private func fakeBundle(in dir: URL, name: String = "Lib.sparsebundle", bands: Int) throws -> URL {
    let bundle = dir.appendingPathComponent(name, isDirectory: true)
    let b = bundle.appendingPathComponent("bands", isDirectory: true)
    try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
    for i in 0..<bands { try Data(repeating: 0x5A, count: 1_000).write(to: b.appendingPathComponent(String(i, radix: 16))) }
    return bundle
}

/// an entry of the history of the mirror in `dir`, holding an image of `bands` bands
private func fakeEntry(_ dir: URL, _ date: Date, written: UInt64, bands: Int = 1) throws -> MirrorHistory.Entry {
    let e = MirrorHistory.folder(in: dir).appendingPathComponent(VersionStamp.string(date), isDirectory: true)
    try FileManager.default.createDirectory(at: e, withIntermediateDirectories: true)
    _ = try fakeBundle(in: e, bands: bands)
    try Data("{}".utf8).write(to: e.appendingPathComponent(ArchiveManifest.sidecarName))
    try MirrorHistory.record(written: written, in: e)
    return MirrorHistory.Entry(dir: e, date: date, written: written)
}

// A run whose check found decay in a library's mirror didn't complete a copy of it.
@Suite struct DecayFoundIsNotACompletedCopy {
    @Test func aLibraryWhoseMirrorDecayedFailsWithTheReason() {
        #expect(JobExecutor.decayFailure(nil, library: "Photos", destination: "Disk") == nil)
        let clean = BandCheckReport(library: "Photos", total: 40, checked: 4)
        #expect(JobExecutor.decayFailure(clean, library: "Photos", destination: "Disk") == nil)

        var bad = BandCheckReport(library: "Photos", total: 40, checked: 4, mismatches: 1, damaged: ["1a"])
        guard case .failed(let library, let destination, let why)? = JobExecutor.decayFailure(bad, library: "Photos", destination: "Disk") else {
            Issue.record("decay found, and the library counted as copied")
            return
        }
        #expect(library == "Photos" && destination == "Disk")
        #expect(why.contains("data band 1a") && why.contains("Start this mirror over"), "\(why)")
        #expect(!why.contains("history"))
        bad.history = 3
        guard case .failed(_, _, let shared)? = JobExecutor.decayFailure(bad, library: "Photos", destination: "Disk") else {
            Issue.record("decay found, and the library counted as copied")
            return
        }
        #expect(shared.contains("history shares"), "\(shared)")
        // and so the run's results don't read as a copy made
        let results = [JobExecutor.decayFailure(bad, library: "Photos", destination: "Disk")].compactMap { $0 }
        #expect(summarizeRun(results).kind == .failed)
    }
}

// An image is closed only when hdiutil says nothing of it is attached.
@Suite struct AnImageNotShownToBeClosed {
    private let image = URL(fileURLWithPath: "/nowhere/Lib.sparsebundle")

    private func listing(_ entity: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>images</key><array><dict>
        <key>image-path</key><string>\(image.path)</string>
        <key>system-entities</key><array><dict>\(entity)</dict></array>
        </dict></array></dict></plist>
        """
    }

    private func answering(_ status: Int32, _ stdout: String) -> ScriptedCommandRunner {
        ScriptedCommandRunner { (_: String, _: [String]) -> CommandResult in CommandResult(status: status, stdout: stdout, stderr: "") }
    }

    @Test func onlyAnAnswerThatListsNoDeviceOfItSaysClosed() {
        let nothing = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>images</key><array/></dict></plist>"
        #expect(MirrorMounts.isClosed(image, runner: answering(0, nothing)))

        // hdiutil couldn't be asked, or said something unreadable: not known to be closed
        let failed = answering(1, "")
        #expect(MirrorMounts.mountPoints(of: image, runner: failed).isEmpty)
        #expect(!MirrorMounts.isClosed(image, runner: failed))
        #expect(!MirrorMounts.isClosed(image, runner: answering(0, "not a property list")))

        // attached with nothing mounted
        let unmounted = answering(0, listing("<key>dev-entry</key><string>/dev/disk9</string>"))
        #expect(MirrorMounts.mountPoints(of: image, runner: unmounted).isEmpty)
        #expect(!MirrorMounts.isClosed(image, runner: unmounted))

        // mounted
        let mounted = answering(0, listing("<key>dev-entry</key><string>/dev/disk9s1</string><key>mount-point</key><string>/Volumes/Lib</string>"))
        #expect(MirrorMounts.mountPoints(of: image, runner: mounted) == ["/Volumes/Lib"])
        #expect(!MirrorMounts.isClosed(image, runner: mounted))
    }
}
