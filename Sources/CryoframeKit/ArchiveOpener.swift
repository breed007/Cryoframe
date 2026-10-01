//
//  ArchiveOpener.swift
//  CryoframeKit
//
//  One version opened to look inside, for a window that can close at any moment.
//  An open can take a while (a download, an encrypted image's attach, a zip's
//  unpack). Closing the window stops it, and an open that still finishes after
//  that is closed as soon as it does: nothing stays mounted, or unpacked in the
//  temp folder, until the next launch sweeps it.
//

import Foundation

public final class ArchiveOpener: @unchecked Sendable {
    public enum Outcome: Sendable {
        case opened(OpenedArchive)
        /// what to tell the user
        case failed(String)
        /// closed, or replaced by another open, before it finished; anything it
        /// opened has been closed
        case canceled
    }

    /// one try at opening, with a passphrase (nil: not encrypted), watching `control`
    public typealias Attempt = @Sendable (_ passphrase: String?, _ control: RunControl) throws -> OpenedArchive

    private let lock = NSLock()
    /// bumped by every open and every close; an open that lands to find it moved is stale
    private var generation = 0
    private var control: RunControl?
    private var current: OpenedArchive?

    public init() {}

    /// what is open now
    public var opened: OpenedArchive? { lock.lock(); defer { lock.unlock() }; return current }

    /// Open `archive`, trying each passphrase in turn on an encrypted one. A wrong
    /// passphrase moves on to the next; any other failure is the answer.
    public func open(_ archive: RestorableArchive, passphrases: [String]) async -> Outcome {
        let result = archive.archiveResult()
        return await open(name: archive.bundleName, passphrases: archive.encrypted ? passphrases : [nil]) { pass, control in
            try ArchiveReader(runner: ProcessCommandRunner(control: control)).open(result, passphrase: pass)
        }
    }

    public func open(name: String, passphrases: [String?], attempt: @escaping Attempt) async -> Outcome {
        let control = RunControl()
        let mine = begin(control)

        let tried: Result<OpenedArchive, Error> = await Task.detached {
            var last: Error = ArchiveError.passphraseUnavailable
            for pass in passphrases {
                if control.isCancelled { return .failure(CancelledError()) }
                do { return .success(try attempt(pass, control)) } catch {
                    last = error
                    if !KeyCheck.isWrongKey(error) { break }
                }
            }
            return .failure(last)
        }.value

        let (stale, replaced) = land(mine, tried)
        replaced?.close()

        switch tried {
        case .success(let o):
            if stale { o.close(); return .canceled }
            return .opened(o)
        case .failure(let error):
            if stale || error is CancelledError { return .canceled }
            return .failed(Self.failureText(error, name: name, tried: passphrases.compactMap { $0 }.count))
        }
    }

    /// this open's generation; one still running is stopped
    private func begin(_ control: RunControl) -> Int {
        lock.lock(); defer { lock.unlock() }
        self.control?.cancel()
        self.control = control
        generation += 1
        return generation
    }

    /// whether the open came back stale, and what a fresh one replaces
    private func land(_ mine: Int, _ tried: Result<OpenedArchive, Error>) -> (stale: Bool, replaced: OpenedArchive?) {
        lock.lock(); defer { lock.unlock() }
        guard generation == mine else { return (true, nil) }
        control = nil
        guard case .success(let o) = tried else { return (false, nil) }
        defer { current = o }
        return (false, current)
    }

    /// Stop an open still running (what it opens is closed when it finishes) and
    /// close what is open. Always call this when the window goes.
    public func close() {
        lock.lock()
        generation += 1
        let running = control, open = current
        control = nil; current = nil
        lock.unlock()
        running?.cancel()
        open?.close()
    }

    /// Why `name` didn't open. Only a passphrase the image refused is called a
    /// passphrase problem: a busy disk-image system, a missing part or a full disk
    /// says so instead.
    static func failureText(_ error: Error, name: String, tried: Int) -> String {
        if KeyCheck.isWrongKey(error) {
            return "Couldn't open \(name): " + (tried > 1 ? "neither passphrase tried unlocked it." : "the passphrase didn't unlock it.")
                + " Check the passphrase."
        }
        if case .toolFailed(let tool, _, let stderr)? = error as? ArchiveError {
            let detail = ProcessCommandRunner.meaningful(stderr).split(separator: "\n").last.map(String.init) ?? ""
            return "Couldn't open \(name): " + (detail.isEmpty ? "\((tool as NSString).lastPathComponent) failed." : detail)
        }
        return "Couldn't open \(name): \(RestoreFailureText.restoreMessage(error, encrypted: false))"
    }
}
