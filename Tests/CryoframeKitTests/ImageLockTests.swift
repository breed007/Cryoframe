//
//  ImageLockTests.swift
//  CryoframeKitTests
//
//  A device of a disk image with nothing mounted on it is an orphan only when no
//  attach of the image is under way. The orphan cleanup ran after any failed attach
//  and before every mirror run, and force-detached such devices whoever's they were:
//  another attach caught between attaching and mounting, or a check that attaches
//  without mounting, lost its device.
//

import Testing
import Foundation
@testable import CryoframeKit

private final class InfoRunner: CommandRunner, @unchecked Sendable {
    let lock = NSLock()
    var detached: [String] = []
    let info: String
    init(image: URL, device: String) {
        info = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>images</key><array><dict>
        <key>image-path</key><string>\(image.path)</string>
        <key>system-entities</key><array><dict><key>dev-entry</key><string>\(device)</string></dict></array>
        </dict></array></dict></plist>
        """
    }
    func run(_ launchPath: String, _ args: [String], stdin: Data?) throws -> CommandResult {
        lock.lock(); defer { lock.unlock() }
        if args.first == "info" { return CommandResult(status: 0, stdout: info, stderr: "") }
        if args.first == "detach", args.count > 1 { detached.append(args[1]) }
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
        let runner = InfoRunner(image: img, device: "/dev/disk43")
        #expect(throws: Failed.self) {
            try ImageLock.attaching(img, runner: runner) {
                let other = Thread { ArchiveReader.detachOrphans(ofImage: img, runner: runner) }
                other.start()
                while !other.isFinished { Thread.sleep(forTimeInterval: 0.01) }
                #expect(runner.detachedNow.isEmpty, "swept during the attach: \(runner.detachedNow)")
                throw Failed()
            }
        }
        #expect(runner.detachedNow == ["/dev/disk43"])
    }
}
