//
//  ArchiveOpenerTests.swift
//  CryoframeKitTests
//
//  A version opened to look inside (Find a File's "Show" and "Look inside…"):
//  closing the window mid-open stops the open and closes what it still opens,
//  and a failure says what went wrong, calling only a refused passphrase a
//  passphrase problem.
//

import Testing
import Foundation
@testable import CryoframeKit

/// counts how often an opened archive is closed
private final class Closes: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.lock(); n += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
}

private func fakeOpened(_ closes: Closes) -> OpenedArchive {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("cf-opener-\(UUID().uuidString)")
    return OpenedArchive(root: work.appendingPathComponent("mnt"), work: work, teardownFn: { closes.add() })
}

/// a semaphore waited on off the test's own task
private func block(on s: DispatchSemaphore) { s.wait() }

private let wrongKey = ArchiveError.toolFailed(tool: "/usr/bin/hdiutil", status: 1,
                                               stderr: "hdiutil: attach failed - Authentication error")

@Suite(.serialized) struct ArchiveOpenerTests {

    // The sheet closes while it says "Opening…": the open is told to stop, and the
    // archive it opens anyway is closed the moment it lands, not left mounted.
    @Test func closingMidOpenClosesWhatLandsAfter() async throws {
        let opener = ArchiveOpener()
        let closes = Closes()
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let sawCancel = Closes()
        let task = Task {
            await opener.open(name: "Library.dmg", passphrases: ["pw"]) { _, control in
                started.signal()
                release.wait()
                if control.isCancelled { sawCancel.add() }
                return fakeOpened(closes)
            }
        }
        await Task.detached { block(on: started) }.value
        opener.close()
        release.signal()
        let outcome = await task.value
        guard case .canceled = outcome else { Issue.record("expected canceled, got \(outcome)"); return }
        #expect(sawCancel.count == 1, "the open in flight is told to stop")
        #expect(closes.count == 1, "what it opened is closed once it lands")
        #expect(opener.opened == nil)
    }

    // Opened, then closed: closed exactly once, and a second close does nothing.
    @Test func anOpenedArchiveIsClosedOnceWhenTheWindowGoes() async {
        let opener = ArchiveOpener()
        let closes = Closes()
        let outcome = await opener.open(name: "Library.zip", passphrases: [nil]) { _, _ in fakeOpened(closes) }
        guard case .opened = outcome else { Issue.record("expected opened, got \(outcome)"); return }
        #expect(opener.opened != nil && closes.count == 0)
        opener.close()
        opener.close()
        #expect(closes.count == 1 && opener.opened == nil)
    }

    // A second version opened closes the first.
    @Test func openingAnotherVersionClosesTheFirst() async {
        let opener = ArchiveOpener()
        let first = Closes(), second = Closes()
        _ = await opener.open(name: "A.dmg", passphrases: [nil]) { _, _ in fakeOpened(first) }
        _ = await opener.open(name: "B.dmg", passphrases: [nil]) { _, _ in fakeOpened(second) }
        #expect(first.count == 1 && second.count == 0)
        opener.close()
        #expect(second.count == 1)
    }

    // A refused passphrase moves on to the next one; the right one opens.
    @Test func aRefusedPassphraseTriesTheNext() async {
        let opener = ArchiveOpener()
        let closes = Closes()
        let outcome = await opener.open(name: "Library.dmg", passphrases: ["typed", "saved"]) { pass, _ in
            if pass == "typed" { throw wrongKey }
            return fakeOpened(closes)
        }
        guard case .opened = outcome else { Issue.record("expected opened, got \(outcome)"); return }
        opener.close()
    }

    // Every passphrase refused: a passphrase problem, said as one.
    @Test func everyPassphraseRefusedSaysCheckThePassphrase() async {
        let outcome = await ArchiveOpener().open(name: "Library.dmg", passphrases: ["typed", "saved"]) { _, _ in throw wrongKey }
        guard case .failed(let why) = outcome else { Issue.record("expected failed, got \(outcome)"); return }
        #expect(why.contains("Library.dmg") && why.contains("Check the passphrase"), "\(why)")
    }

    // Anything else is said as itself, and isn't retried with another passphrase:
    // a busy disk-image system isn't a wrong passphrase.
    @Test func anotherFailureSaysWhatItWas() async {
        let tries = Closes()
        let outcome = await ArchiveOpener().open(name: "Library.dmg", passphrases: ["typed", "saved"]) { _, _ in
            tries.add()
            throw ArchiveError.toolFailed(tool: "/usr/bin/hdiutil", status: 1, stderr: "hdiutil: attach failed - Resource busy")
        }
        guard case .failed(let why) = outcome else { Issue.record("expected failed, got \(outcome)"); return }
        #expect(tries.count == 1)
        #expect(why.contains("Resource busy") && !why.contains("passphrase"), "\(why)")
        let missing = ArchiveOpener.failureText(ArchiveError.sourceMissing("Library.dmg.002"), name: "Library.dmg", tried: 1)
        #expect(missing.contains("Library.dmg.002") && !missing.contains("passphrase"), "\(missing)")
        // the restore window's own open: one passphrase tried, and refused
        #expect(ArchiveOpener.failureText(wrongKey, name: "Library.dmg", tried: 1)
                == "Couldn't open Library.dmg: the passphrase didn't unlock it. Check the passphrase.")
    }

    // The window closes (on the main actor) just as the open lands. The open comes
    // back on its caller's actor, so the caller either hears it was canceled or gets
    // an archive that is still open, never one a close() has already closed.
    @MainActor @Test func aCloseAsTheOpenLandsNeverHandsBackAClosedArchive() async {
        let opener = ArchiveOpener()
        let closes = Closes()
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let task = Task { @MainActor () -> (ArchiveOpener.Outcome, Bool) in
            let outcome = await opener.open(name: "Library.dmg", passphrases: [nil]) { _, _ in
                started.signal()
                release.wait()
                return fakeOpened(closes)
            }
            return (outcome, opener.opened != nil)
        }
        await Task.detached { block(on: started) }.value
        release.signal()
        // hold the main actor until the open has landed (or a second, if landing needs it)
        let deadline = Date().addingTimeInterval(1)
        while opener.opened == nil, Date() < deadline { usleep(1_000) }
        opener.close()
        let (outcome, stillOpen) = await task.value
        switch outcome {
        case .opened: #expect(stillOpen && closes.count == 0, "handed back an archive already closed")
        case .canceled: #expect(closes.count == 1)
        case .failed(let why): Issue.record("failed: \(why)")
        }
        opener.close()
    }
}
