//
//  ImageLockTests.swift
//  CryoframeKitTests
//
//  A device of a disk image with nothing mounted on it is an orphan only when no
//  attach of the image is under way. The orphan cleanup ran after any failed attach
//  and before every mirror run, and force-detached such devices whoever's they were:
//  another attach caught between attaching and mounting, or a check that attaches
//  without mounting, lost its device. And a device there before an attach began is
//  never that attach's: an image attached outside Cryoframe with nothing mounted takes
//  no lock, and lost its disk too.
//

import Testing
import Foundation
@testable import CryoframeKit

private final class InfoRunner: CommandRunner, @unchecked Sendable {
    let lock = NSLock()
    var detached: [String] = []
    /// listed from the start, or only once something runs `hdiutil attach`
    var listed: Bool
    let info: String
    let none = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict><key>images</key><array/></dict></plist>
    """
    init(image: URL, device: String, listed: Bool = true, helper: Int32? = nil) {
        self.listed = listed
        let served = helper.map { "<key>hdid-pid</key><integer>\($0)</integer>" } ?? ""
        info = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>images</key><array><dict>
        <key>image-path</key><string>\(image.path)</string>\(served)
        <key>system-entities</key><array><dict><key>dev-entry</key><string>\(device)</string></dict></array>
        </dict></array></dict></plist>
        """
    }
    func run(_ launchPath: String, _ args: [String], stdin: Data?) throws -> CommandResult {
        lock.lock(); defer { lock.unlock() }
        if args.first == "info" { return CommandResult(status: 0, stdout: listed ? info : none, stderr: "") }
        if args.first == "attach" { listed = true }
        if args.first == "detach", args.count > 1 { detached.append(args[1]); listed = false }
        return CommandResult(status: 0, stdout: "", stderr: "")
    }
    var control: RunControl? { nil }
    var forTeardown: CommandRunner { self }
    var detachedNow: [String] { lock.lock(); defer { lock.unlock() }; return detached }
}

private func image(_ tag: String) -> URL {
    URL(fileURLWithPath: "/tmp/cf-image-lock-test-\(tag)-\(UUID().uuidString)/Lib.sparsebundle")
}

@Suite(.serialized) struct ImageLockTests {
    // Another attach holds the image (here, the test): its device, not yet mounted,
    // is left alone. Once it lets go, a device still with nothing mounted is an orphan.
    @Test func aDeviceOfAnAttachUnderWayIsNotDetached() throws {
        let img = image("under-way")
        let runner = InfoRunner(image: img, device: "/dev/disk42")
        let attaching = try #require(ImageLock.acquire(img))
        ArchiveReader.detachOrphans(ofImage: img, runner: runner)
        #expect(runner.detachedNow.isEmpty, "detached another attach's device: \(runner.detachedNow)")
        attaching.release()
        ArchiveReader.detachOrphans(ofImage: img, runner: runner)
        #expect(runner.detachedNow == ["/dev/disk42"])
    }

    // One holder at a time, in one process as across two; another image's lock is
    // its own.
    @Test func theLockHasOneHolderAtATime() throws {
        let img = image("one")
        let first = try #require(ImageLock.acquire(img))
        #expect(ImageLock.acquire(img) == nil)
        #expect(ImageLock.acquire(img, wait: 0.5) == nil)
        let other = try #require(ImageLock.acquire(image("other")), "another image's lock")
        other.release()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { first.release(); done.signal() }
        let second = try #require(ImageLock.acquire(img, wait: 10), "had once the holder lets go")
        second.release()
        done.wait()
    }

    // A failed attach's own orphan is detached while its lock is held; a sweep by
    // anyone else meanwhile (another thread's cleanup, a mirror run starting) leaves
    // it, as it can't tell it from an attach under way.
    @Test func aFailedAttachDetachesItsOwnOrphan() {
        struct Failed: Error {}
        let img = image("failed")
        let runner = InfoRunner(image: img, device: "/dev/disk43", listed: false)
        #expect(throws: Failed.self) {
            try ImageLock.attaching(img, runner: runner) { before in
                #expect(before.isEmpty)
                _ = try runner.run("/usr/bin/hdiutil", ["attach", "-nomount", img.path], stdin: nil)
                let other = Thread { ArchiveReader.detachOrphans(ofImage: img, runner: runner) }
                other.start()
                while !other.isFinished { Thread.sleep(forTimeInterval: 0.01) }
                #expect(runner.detachedNow.isEmpty, "swept during the attach: \(runner.detachedNow)")
                throw Failed()
            }
        }
        #expect(runner.detachedNow == ["/dev/disk43"])
    }

    // A device attached before the attach began, with nothing mounted on it, is
    // another program's (Disk Utility, Terminal): handed to the attach as such, and
    // left attached when the attach fails.
    @Test func aDeviceThereBeforeTheAttachIsLeftAlone() {
        struct Failed: Error {}
        let img = image("before")
        let runner = InfoRunner(image: img, device: "/dev/disk44")
        #expect(throws: Failed.self) {
            try ImageLock.attaching(img, runner: runner) { before in
                #expect(before == ["/dev/disk44"])
                _ = try runner.run("/usr/bin/hdiutil", ["attach", "-nomount", img.path], stdin: nil)
                throw Failed()
            }
        }
        #expect(runner.detachedNow.isEmpty, "detached a device that was there before: \(runner.detachedNow)")
    }

    // Given up on the holder, nothing is attached: an attach made without the lock
    // could be taken for the holder's debris and detached under it.
    @Test func aWaitThatRunsOutAttachesNothing() throws {
        let img = image("timeout")
        let runner = InfoRunner(image: img, device: "/dev/disk45", listed: false)
        let holder = try #require(ImageLock.acquire(img))
        defer { holder.release() }
        var ran = false
        #expect(throws: DiskImageInUse.self) {
            try ImageLock.attaching(img, runner: runner, wait: 0.5) { _ in ran = true }
        }
        #expect(!ran, "attached without the lock")
    }

    // Stop ends the wait for the image, for a check run with a teardown runner (no
    // control of its own) as for an attach.
    @Test func stopEndsTheWaitForTheImage() throws {
        let img = image("stop")
        let runner = InfoRunner(image: img, device: "/dev/disk46", listed: false)
        let holder = try #require(ImageLock.acquire(img))
        defer { holder.release() }
        let control = RunControl()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { control.cancel() }
        var start = ProcessInfo.processInfo.systemUptime
        #expect(throws: CancelledError.self) {
            try ImageLock.attaching(img, runner: runner, control: control) { _ in }
        }
        #expect(ProcessInfo.processInfo.systemUptime - start < 10, "Stop didn't end the attach's wait")

        start = ProcessInfo.processInfo.systemUptime
        #expect(MirrorIntegrity.check(img, passphrase: nil, runner: runner, control: control) != .sound)
        #expect(ProcessInfo.processInfo.systemUptime - start < 10, "Stop didn't end the check's wait")
        #expect(!runner.listed, "the check attached the image")
    }

    // MARK: - a crashed Cryoframe process's own attach

    // An attach Cryoframe recorded, left by a process that has died, with nothing
    // mounted: detached as the next attach takes the lock, and the attach goes ahead
    // with the image to itself. A pid that now belongs to a later process counts as
    // dead: it is another process.
    @Test(arguments: ["pid gone", "pid reused"])
    func aDeadOwnersLeftoverIsDetached(_ how: String) throws {
        let img = image("dead-\(how == "pid gone" ? "gone" : "reused")")
        let me = try #require(ProcessIdentity.current)
        let owner = how == "pid gone" ? try exitedProcess() : ProcessIdentity(pid: me.pid, startedAt: me.startedAt - 3600)
        // the test process stands in for the disk-image process serving the attach
        let runner = InfoRunner(image: img, device: "/dev/disk47", helper: me.pid)
        try writeRecord(img, device: "/dev/disk47", helper: me, owner: owner)
        try ImageLock.attaching(img, runner: runner) { before in
            #expect(before.isEmpty, "the leftover was still there when the attach began")
        }
        #expect(runner.detachedNow == ["/dev/disk47"])
    }

    // Recorded by a process that is still running (the app while the agent runs, a
    // restore window): its attach, and it stays, whatever is mounted.
    @Test func aLiveOwnersAttachIsKept() throws {
        let img = image("live")
        let me = try #require(ProcessIdentity.current)
        let runner = InfoRunner(image: img, device: "/dev/disk48", helper: me.pid)
        try writeRecord(img, device: "/dev/disk48", helper: me, owner: me)
        try ImageLock.attaching(img, runner: runner) { before in
            #expect(before == ["/dev/disk48"])
        }
        #expect(runner.detachedNow.isEmpty, "detached a live process's attach: \(runner.detachedNow)")
    }

    // The recorded attach ended and the device name went to a new attach of the same
    // image (macOS hands it out again): the record isn't that attach's, the device
    // stays, and the record goes. So does an unrecorded device, and one recorded for
    // another image.
    @Test func aDeviceTheRecordDoesNotMatchIsKept() throws {
        let me = try #require(ProcessIdentity.current)
        let dead = try exitedProcess()

        let reused = image("reused-device")
        let runner = InfoRunner(image: reused, device: "/dev/disk49", helper: me.pid)
        let record = try writeRecord(reused, device: "/dev/disk49", helper: dead, owner: dead)
        try ImageLock.attaching(reused, runner: runner) { before in #expect(before == ["/dev/disk49"]) }
        #expect(runner.detachedNow.isEmpty, "detached a later attach on a reused device: \(runner.detachedNow)")
        #expect(!FileManager.default.fileExists(atPath: record.path), "the ended attach's record stayed")

        let other = image("other-image")
        let otherRunner = InfoRunner(image: other, device: "/dev/disk50", helper: me.pid)
        try writeRecord(image("recorded-image"), device: "/dev/disk50", helper: me, owner: dead)
        try ImageLock.attaching(other, runner: otherRunner) { before in #expect(before == ["/dev/disk50"]) }
        #expect(otherRunner.detachedNow.isEmpty, "detached another image's device: \(otherRunner.detachedNow)")

        let unrecorded = image("unrecorded")
        let plain = InfoRunner(image: unrecorded, device: "/dev/disk51", helper: me.pid)
        try ImageLock.attaching(unrecorded, runner: plain) { before in #expect(before == ["/dev/disk51"]) }
        #expect(plain.detachedNow.isEmpty, "detached an unrecorded device: \(plain.detachedNow)")
    }
}

/// a process that has run and exited, as it was while it ran
private func exitedProcess() throws -> ProcessIdentity {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sleep")
    p.arguments = ["30"]
    try p.run()
    let who = ProcessIdentity.of(pid: p.processIdentifier)
    p.terminate()
    p.waitUntilExit()
    return try #require(who)
}

@discardableResult
private func writeRecord(_ image: URL, device: String, helper: ProcessIdentity, owner: ProcessIdentity) throws -> URL {
    let dir = AttachRecords.folder(in: MirrorMounts.defaultBase)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("test-\(UUID().uuidString).json")
    let record = AttachRecords.Record(image: AttachRecords.key(image.path), devices: [device], helper: helper, owner: owner)
    try JSONEncoder().encode(record).write(to: file)
    return file
}
