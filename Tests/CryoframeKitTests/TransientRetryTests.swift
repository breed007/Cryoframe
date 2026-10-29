//
//  TransientRetryTests.swift
//  CryoframeKitTests
//
//  Which tool failures are waited out and which fail at once. Only a busy disk-image
//  system or a busy volume is worth another try; a refusal, a missing file, a wrong
//  passphrase or an image already attached elsewhere is reported straight away.
//

import Testing
import Foundation
@testable import CryoframeKit

/// counts the commands a script answers
private final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func bump(_ verb: String) { lock.lock(); counts[verb, default: 0] += 1; lock.unlock() }
    subscript(_ verb: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[verb] ?? 0 }
}

private func info(listing path: String?) -> String {
    let images = path.map { "<dict><key>image-path</key><string>\($0)</string><key>system-entities</key><array/></dict>" } ?? ""
    return """
    <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>images</key><array>\(images)</array></dict></plist>
    """
}

/// an hdiutil that fails `verb` with `stderr` every time, and lists `attached` in `info`
private func hdiutil(failing verb: String, with stderr: String, attached: String? = nil, tally: Tally) -> ScriptedCommandRunner {
    ScriptedCommandRunner { _, args in
        let v = args.first ?? ""
        tally.bump(v)
        if v == "info" { return CommandResult(status: 0, stdout: info(listing: attached), stderr: "") }
        if v == verb { return CommandResult(status: 1, stdout: "", stderr: stderr) }
        return CommandResult(status: 0, stdout: "", stderr: "")
    }
}

@Suite struct TransientRetryTests {
    let image = "/Volumes/T7/Backups/Photos/Photos.sparsebundle"

    // A refusal says something true: no wait changes it. "Operation not permitted"
    // was retried for up to 13 s (it is also how a missing Full Disk Access grant
    // reads), and so was any refusal printed alongside a busy line.
    @Test(arguments: [
        "hdiutil: attach failed - Permission denied",
        "hdiutil: attach failed - Operation not permitted",
        "hdiutil: attach failed - No such file or directory",
        "hdiutil: attach failed - Authentication error",
        "hdiutil: attach failed - image not recognized",
        "diskimages-helper: Resource temporarily unavailable\nhdiutil: attach failed - Permission denied",
    ])
    func aRefusalFailsAtOnce(_ stderr: String) throws {
        let tally = Tally()
        let r = try hdiutil(failing: "attach", with: stderr, tally: tally).runRetryingBusy("/usr/bin/hdiutil", ["attach", image], attempts: 3)
        #expect(!r.ok)
        #expect(tally["attach"] == 1, "\(stderr) was tried \(tally["attach"]) times")
    }

    // On current macOS a second attach of an attached image always fails "Resource
    // busy". It is open elsewhere; retrying only delayed saying so.
    @Test func anImageAttachedElsewhereFailsAtOnce() throws {
        let tally = Tally()
        let runner = hdiutil(failing: "attach", with: "hdiutil: attach failed - Resource busy", attached: image, tally: tally)
        let r = try runner.runRetryingBusy("/usr/bin/hdiutil", ["attach", "-nomount", "-readonly", image], attempts: 3)
        #expect(!r.ok)
        #expect(tally["attach"] == 1)
        // found by its real path, too
        let viaPrivate = hdiutil(failing: "attach", with: "hdiutil: attach failed - Resource busy",
                                 attached: "/private/var/folders/x/Lib.sparsebundle", tally: tally)
        _ = try viaPrivate.runRetryingBusy("/usr/bin/hdiutil", ["attach", "/var/folders/x/Lib.sparsebundle"], attempts: 3)
        #expect(tally["attach"] == 2)
    }

    // Busy with nothing of ours attached, a busy volume on detach, and a saturated
    // disk-image system are waited out, as before.
    @Test func busyAndSaturatedAreWaitedOut() throws {
        let busy = Tally()
        _ = try hdiutil(failing: "attach", with: "hdiutil: attach failed - Resource busy", tally: busy)
            .runRetryingBusy("/usr/bin/hdiutil", ["attach", image], attempts: 3)
        #expect(busy["attach"] == 3)

        let detach = Tally()
        _ = try hdiutil(failing: "detach", with: "hdiutil: couldn't unmount \"disk9\" - Resource busy", tally: detach)
            .runRetryingBusy("/usr/bin/hdiutil", ["detach", "/tmp/mnt"], attempts: 3)
        #expect(detach["detach"] == 3)

        // saturation is waited out even for an image attached elsewhere: it says
        // nothing about the image
        let saturated = Tally()
        _ = try hdiutil(failing: "attach", with: "hdiutil: attach failed - Resource temporarily unavailable", attached: image, tally: saturated)
            .runRetryingBusy("/usr/bin/hdiutil", ["attach", image], attempts: 3)
        #expect(saturated["attach"] == 3)
    }

    // The reader's extra attempt from scratch (after every retry has failed) is for a
    // saturated disk-image system only.
    @Test func theReaderTriesAgainFromScratchOnlyWhenSaturated() {
        func e(_ s: String) -> ArchiveError { .toolFailed(tool: "hdiutil", status: 1, stderr: s) }
        #expect(ArchiveReader.isTransient(e("hdiutil: attach failed - Resource temporarily unavailable")))
        #expect(!ArchiveReader.isTransient(e("hdiutil: attach failed - Resource busy")))
        #expect(!ArchiveReader.isTransient(e("hdiutil: attach failed - Operation not permitted")))
        #expect(!ArchiveReader.isTransient(e("hdiutil: attach failed - Authentication error")))
    }
}

/// A sealed image build on the macOS 27 CI runner sometimes fails "create failed - No
/// such file or directory" with nothing missing. That build, and only that one, is
/// tried once more, and only while what it reads and writes into is still there.
@Suite(.serialized) struct MissingFileRetryTests {
    static let enoent = "hdiutil: create failed - No such file or directory"

    /// a library folder and a destination, with an hdiutil whose `create` answers
    /// `answers` in turn (the last one again after that): a success writes the image
    func build(_ answers: [String?], before: @escaping @Sendable (_ library: URL, _ dest: URL) -> Void = { _, _ in })
        throws -> (result: Result<ArchiveResult, Error>, creates: Int) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("enoent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let library = base.appendingPathComponent("src/Photos")
        let dest = base.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: library.appendingPathComponent("a.jpg"))
        let tally = Tally()
        let runner = ScriptedCommandRunner { (_: String, args: [String]) -> CommandResult in
            guard args.first == "create" else { return CommandResult(status: 0, stdout: "", stderr: "") }
            tally.bump("create")
            before(library, dest)
            let answer: String? = answers[min(tally["create"], answers.count) - 1]
            guard let said = answer else {
                FileManager.default.createFile(atPath: args[args.count - 1], contents: Data("dmg".utf8))
                return CommandResult(status: 0, stdout: "", stderr: "")
            }
            return CommandResult(status: 1, stdout: "", stderr: said)
        }
        let engine = SealedArchiveEngine(.dmg, runner: runner)
        let result = Result<ArchiveResult, Error>(catching: { () throws -> ArchiveResult in
            try engine.archive(ArchiveSource(name: "Photos", root: library), to: dest)
        })
        return (result, tally["create"])
    }

    @Test func aMissingFileWithEverythingThereIsTriedOnceMore() throws {
        let (result, creates) = try build([Self.enoent, nil])
        #expect(creates == 2)
        #expect(try result.get().artifacts.map(\.lastPathComponent) == ["Photos.dmg"])
    }

    // the second failure is reported exactly as the first would have been
    @Test func aSecondMissingFileIsReportedAsBefore() throws {
        let (result, creates) = try build([Self.enoent])
        #expect(creates == 2)
        guard case .failure(let error) = result, case ArchiveError.toolFailed(let tool, let status, let text)? = error as? ArchiveError else {
            Issue.record("expected toolFailed, got \(result)"); return
        }
        #expect(tool == "hdiutil" && status == 1 && text == Self.enoent)
    }

    // the library or the destination gone during the build: really missing
    @Test func nothingIsRetriedWhenTheFolderOrTheDestinationIsGone() throws {
        let noLibrary = try build([Self.enoent, nil]) { (library: URL, _: URL) -> Void in _ = try? FileManager.default.removeItem(at: library) }
        #expect(noLibrary.creates == 1)
        let noDest = try build([Self.enoent, nil]) { (_: URL, dest: URL) -> Void in _ = try? FileManager.default.removeItem(at: dest) }
        #expect(noDest.creates == 1)
    }

    @Test(arguments: [
        "hdiutil: create failed - Permission denied",
        "hdiutil: create failed - Resource busy\nhdiutil: create failed - No space left on device",
        "hdiutil: create failed - No such file or directory\nhdiutil: create failed - Operation not permitted",
        "hdiutil: create failed - File exists",
    ])
    func anotherErrorIsNotRetried(_ stderr: String) throws {
        let (result, creates) = try build([stderr, nil])
        #expect(creates == 1, "\(stderr) was tried \(creates) times")
        #expect(throws: ArchiveError.self) { try result.get() }
    }

    // a missing file is retried for a folder image only, and not when hdiutil names
    // an item it could not read
    @Test func onlyAFolderImageIsRetried() {
        let dir = FileManager.default.temporaryDirectory
        let failed = CommandResult(status: 1, stdout: "", stderr: Self.enoent)
        let folder = DiskImageTool.folderImage(root: dir, output: dir.appendingPathComponent("o.dmg"))
        #expect(SealedArchiveEngine.isMissingWithEverythingThere(folder, failed))
        let blank = DiskImageTool.sparseBundle(output: dir.appendingPathComponent("o.sparsebundle"), name: "o", sizeGB: 1, bandSectors: 16384)
        #expect(!SealedArchiveEngine.isMissingWithEverythingThere(blank, failed))
        let attach = Command("/usr/bin/hdiutil", ["attach", dir.appendingPathComponent("o.dmg").path])
        #expect(!SealedArchiveEngine.isMissingWithEverythingThere(attach, CommandResult(status: 1, stdout: "", stderr: "hdiutil: attach failed - No such file or directory")))
        let named = CommandResult(status: 1, stdout: "could not access /x/a.jpg - No such file or directory", stderr: Self.enoent)
        #expect(!SealedArchiveEngine.isMissingWithEverythingThere(folder, named))
        #expect(!SealedArchiveEngine.isMissingWithEverythingThere(folder, CommandResult(status: 0, stdout: "", stderr: Self.enoent)))
    }
}
