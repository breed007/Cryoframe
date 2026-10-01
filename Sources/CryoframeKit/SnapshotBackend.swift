//
//  SnapshotBackend.swift
//  CryoframeKit
//
//  The swappable snapshot-create backend (the "hybrid" decision in code).
//  The root helper holds exactly one of these behind the PrivilegedHelper XPC
//  contract. M0/M1 de-risk established:
//    - fs_snapshot_create needs the Apple-restricted com.apple.developer.vfs.snapshot
//      entitlement; plain root => EPERM. So FSSnapshotBackend is gated on Apple.
//    - tmutil localsnapshot + mount_apfs work as root with no entitlement.
//  => TMUtilSnapshotBackend ships now; FSSnapshotBackend drops in unchanged
//     behind this protocol if the entitlement is granted.
//

import Foundation
import os
import CryoframeShared

/// Per-operation privileged snapshot primitives. All calls assume the caller is
/// root (the helper). The XPC contract above this never changes between backends.
public protocol SnapshotBackend: Sendable {
    /// freeze: take a point-in-time snapshot of `volume`.
    func create(on volume: VolumeRef) throws -> SnapshotRef
    /// mount read-only at a helper-chosen mountpoint; `ownerUID` must be able to
    /// traverse it (the FDA reader runs as that user). Proven in the split-read spike.
    func mount(_ snapshot: SnapshotRef, ownerUID: uid_t) throws -> MountRef
    func unmount(_ mount: MountRef) throws
    /// delete: backends MUST refuse anything they didn't create (no foreign/TM snapshots).
    func delete(_ snapshot: SnapshotRef) throws
    func list(on volume: VolumeRef) throws -> [SnapshotRef]
}

// MARK: - Command execution (injectable so backends are unit-testable)

public struct CommandResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public var ok: Bool { status == 0 }
    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status; self.stdout = stdout; self.stderr = stderr
    }
}

public protocol CommandRunner: Sendable {
    /// `stdin`, when non-nil, is written to the process and the pipe closed — used
    /// to feed `hdiutil -stdinpass` an encryption passphrase without exposing it in
    /// argv or on disk.
    func run(_ launchPath: String, _ args: [String], stdin: Data?) throws -> CommandResult
    /// the run this runner belongs to, for work done in-process between commands
    /// (a file walk, say) that must honor Stop and Pause the way a command does.
    var control: RunControl? { get }
    /// a runner for cleanup after the run: detaching, unmounting. It must still work
    /// once the run is stopped, which is exactly when cleanup matters most; the run's
    /// own runner refuses to launch anything after Stop.
    var forTeardown: CommandRunner { get }
}

extension CommandRunner {
    public var control: RunControl? { nil }
    public var forTeardown: CommandRunner { self }
}

public extension CommandRunner {
    func run(_ launchPath: String, _ args: [String]) throws -> CommandResult {
        try run(launchPath, args, stdin: nil)
    }

    /// run, retrying briefly while the disk-image system says it is busy.
    ///
    /// `hdiutil attach` reports saturation of `diskimages-helper` as EAGAIN —
    /// "Resource temporarily unavailable" — and a busy volume on detach as EBUSY.
    /// Waiting those out matters: a verification that gave up on the first one called
    /// a perfectly good archive bad, the worst false alarm a backup tool can raise.
    ///
    /// Only those are retried. Anything that says something about the image, the
    /// passphrase or the permissions fails at once: retrying a refusal took up to 13
    /// seconds to report the same refusal, and made a real problem look like a slow
    /// one. See `isTransient` for which is which.
    func runRetryingBusy(_ launchPath: String, _ args: [String], stdin: Data? = nil, attempts: Int = 8) throws -> CommandResult {
        var result = try run(launchPath, args, stdin: stdin)
        var tries = 1
        while !result.ok, tries < attempts, Self.isTransient(result.stderr) {
            // On current macOS, attaching an image that is already attached fails
            // "Resource busy", every time: it is open elsewhere, and waiting won't
            // change that. Retrying it held the caller up and then reported busy.
            if Self.isAttach(launchPath, args), !Self.isWaitable(result.stderr),
               Self.attachedImagePaths(runner: self).contains(where: { args.contains($0) }) { break }
            Thread.sleep(forTimeInterval: min(0.5 * Double(tries), 3.0))
            result = try run(launchPath, args, stdin: stdin)
            tries += 1
        }
        return result
    }

    /// What a failed tool's stderr says about trying again: true only when the disk-
    /// image system (or a volume) was momentarily busy.
    ///
    ///   - EAGAIN, "Resource temporarily unavailable": diskimages-helper saturated
    ///     (Time Machine, another job, Spotlight). Transient.
    ///   - EBUSY, "Resource busy": a volume still in use on detach; or, on attach, an
    ///     image attached elsewhere (runRetryingBusy tells that apart and stops).
    ///   - Never: a refused permission (EACCES, EPERM), something missing (ENOENT),
    ///     a wrong passphrase or failed authentication, a full or read-only volume, an
    ///     image that isn't one. These win when both kinds appear in the output.
    /// "Operation not permitted" used to count as transient, for brief races with
    /// privacy controls during an attach; it is also how a missing Full Disk Access
    /// grant reads, which no wait fixes.
    static func isTransient(_ stderr: String) -> Bool {
        guard !permanentToolErrors.contains(where: { stderr.localizedCaseInsensitiveContains($0) }) else { return false }
        return transientToolErrors.contains { stderr.localizedCaseInsensitiveContains($0) }
    }

    static var transientToolErrors: [String] {
        ["resource temporarily unavailable", "resource busy", "device busy"]
    }

    /// failures that say something true about the image, the key or the permissions
    static var permanentToolErrors: [String] {
        ["permission denied", "operation not permitted", "no such file", "not found", "authentication error",
         "incorrect passphrase", "no space left", "read-only file system", "image not recognized",
         "not recognized", "file exists", "corrupt"]
    }

    /// A tool's stderr without hdiutil's deprecation notice. On macOS 27 hdiutil
    /// prints a warning that it is deprecated in favor of `diskutil image` ahead of
    /// its real error, and that line is no use to someone reading the message.
    /// Every other line is kept, in order. If nothing but the notice is there, the
    /// text is returned as it came: the error is never dropped.
    static func meaningful(_ stderr: String) -> String {
        let lines = stderr.split(separator: "\n", omittingEmptySubsequences: true)
        let kept = lines.filter { l in
            !(l.localizedCaseInsensitiveContains("diskutil image") || l.localizedCaseInsensitiveContains("deprecated"))
        }
        guard !kept.isEmpty else { return stderr.trimmingCharacters(in: .whitespacesAndNewlines) }
        return kept.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
    }

    /// EAGAIN: the disk-image system itself is saturated, whatever is attached
    static func isWaitable(_ stderr: String) -> Bool {
        stderr.localizedCaseInsensitiveContains("resource temporarily unavailable")
    }

    /// Steps that Stop and the watchdog never signal. Stop lets one finish (for up to
    /// ToolWatchdog.finishAfterStop) and the run then stops, handing back what it
    /// printed (CancelledError.finished), so whatever it attached is recorded and then
    /// detached by the caller's cleanup. A stalled one is only given up on.
    ///
    ///   - An attach. Its work is done by a diskimages-helper that ending hdiutil
    ///     doesn't end (measured on macOS 26.7): on SIGTERM hdiutil finishes the attach,
    ///     and on SIGKILL the image is attached and mounted anyway a moment later. That
    ///     attach is nobody's on record, and blocks the next run of the mirror.
    ///   - The making of an empty image (a mirror's first run). Stopped in its first
    ///     half second, by SIGTERM or SIGKILL, it leaves an image with no file system,
    ///     which every later run then failed to attach (measured). It takes about a
    ///     second.
    ///
    /// Making an image from a folder (create -srcfolder) is still stopped, as it can
    /// take an hour: on SIGTERM hdiutil cancels it and removes what it wrote, and a
    /// SIGKILL leaves a partial file that won't open, in a folder with no manifest, which
    /// the next run sweeps (measured, no device left attached either way). So is a
    /// resize: killed part way, the image was left at either size, attachable, with
    /// nothing attached.
    static func letsFinish(_ launchPath: String, _ args: [String]) -> Bool {
        guard (launchPath as NSString).lastPathComponent == "hdiutil" else { return false }
        switch args.first {
        case "attach": return true
        case "create": return !args.contains("-srcfolder")
        default: return false
        }
    }

    static func isAttach(_ launchPath: String, _ args: [String]) -> Bool {
        (launchPath as NSString).lastPathComponent == "hdiutil" && args.first == "attach"
    }

    /// every image attached right now, by the path it was attached from (as given
    /// and with symlinks resolved), from `hdiutil info`
    static func attachedImagePaths(runner: CommandRunner) -> Set<String> {
        guard let r = try? runner.run("/usr/bin/hdiutil", ["info", "-plist"], stdin: nil), r.ok,
              let data = r.stdout.data(using: .utf8),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = root["images"] as? [[String: Any]] else { return [] }
        var out = Set<String>()
        for img in images {
            guard let path = img["image-path"] as? String else { continue }
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            out.formUnion([path, resolved, path.hasPrefix("/private/") ? String(path.dropFirst(8)) : "/private" + path])
        }
        return out
    }
}

/// Real runner over Foundation `Process`. Used by the helper at runtime. When a
/// `RunControl` is attached, a cancel terminates the in-flight process. Every tool is
/// watched, and stopped if it makes no progress for `quietLimit` seconds (see
/// ToolWatchdog): the run's, from its RunControl; the default otherwise.
public struct ProcessCommandRunner: CommandRunner {
    public let control: RunControl?
    public let quietLimit: TimeInterval
    public init(control: RunControl? = nil, quietLimit: TimeInterval? = nil) {
        self.control = control
        self.quietLimit = quietLimit ?? control?.quietLimit ?? ToolWatchdog.defaultQuietLimit
    }
    /// no Stop (teardown must work after one), the same watchdog: a detach that hangs
    /// on a dead drive is as stuck as anything else
    public var forTeardown: CommandRunner { ProcessCommandRunner(quietLimit: quietLimit) }

    /// the quality of service every tool is launched at
    static let toolQuality: QualityOfService = .utility

    public func run(_ launchPath: String, _ args: [String], stdin: Data? = nil) throws -> CommandResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        // Never at background priority, whatever launched the run: a tool there gets
        // almost no CPU while the Mac is busy (about 10 ms in five minutes, measured),
        // which looks like no progress to the watchdog. Utility is the class for long
        // work no one is waiting on; a tool's priority comes from this, not from the
        // thread that launches it (measured).
        p.qualityOfService = Self.toolQuality
        let inPipe: Pipe? = stdin != nil ? Pipe() : nil
        if let inPipe { p.standardInput = inPipe }
        control?.waitWhilePaused()                  // don't launch the next command while paused
        if let control, !control.attach(p) { throw CancelledError() }
        try p.run()
        let letFinish = Self.letsFinish(launchPath, args)
        let watch = ToolWatch(p, limit: quietLimit, control: control, letFinish: letFinish)
        watch.start()
        if let control, !control.watching(watch) { watch.stopForCancel() }     // Stop came as it launched
        if let inPipe, let stdin {                  // feed the passphrase, then EOF
            inPipe.fileHandleForWriting.write(stdin)
            try? inPipe.fileHandleForWriting.close()
        }
        // Drain both pipes at once, and before waiting for the exit. Reading stdout to
        // EOF and only then stderr deadlocks as soon as a tool fills stderr's 64 KB
        // buffer first: it blocks writing, we block reading, forever. rsync writes a
        // line per file it could not read, so a library with a few hundred of them
        // hung a mirror run with the snapshot held. Each read also tells the watchdog
        // the tool is alive.
        let outData = Drained(), errData = Drained()
        let drained = DispatchGroup()
        for (handle, sink) in [(out.fileHandleForReading, outData), (err.fileHandleForReading, errData)] {
            drained.enter()
            Thread.detachNewThread {
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    sink.append(chunk)
                    watch.printed(chunk.count)
                }
                // Close it here, once it has ended: releasing the Pipe doesn't (on
                // macOS 26 its read end stays open), and a process that leaked two
                // descriptors per tool ran out after about a hundred of them and could
                // launch nothing more. The reader closes it, not the caller, which may
                // give up on a tool stuck in the kernel while this read still waits.
                try? handle.close()
                drained.leave()
            }
        }
        // Wait for the output to end, as long as the tool runs. Once the watchdog has
        // stopped it, not much longer: a process stuck inside the kernel on a share
        // that stopped answering can't be killed until the kernel lets go, and the run
        // has cleanup to do.
        // A step Stop lets finish is waited for, up to a bound (a drive gone dead under
        // it never lets it finish).
        let patience = ToolWatchdog.termGrace + ToolWatchdog.abandonAfter
        var gaveUp = false
        while drained.wait(timeout: .now() + 1) == .timedOut {
            let now = ProcessInfo.processInfo.systemUptime
            if let stoppedAt = watch.stoppedAt, now - stoppedAt > patience { break }
            if let asked = watch.stopAskedAt, now - asked > ToolWatchdog.finishAfterStop { gaveUp = true; break }
        }
        watch.finish()
        // not waitUntilExit: see ProcessWait
        let status = gaveUp ? p.waitForExit(giveUpAfter: 0)
            : watch.stoppedAt == nil ? p.waitForExit() : p.waitForExit(giveUpAfter: patience)
        control?.detach()
        if control?.isCancelled == true {
            guard letFinish, !gaveUp, watch.stoppedAt == nil else { throw CancelledError() }
            throw CancelledError(finished: CommandResult(status: status, stdout: String(decoding: outData.data, as: UTF8.self),
                                                         stderr: String(decoding: errData.data, as: UTF8.self)))
        }
        if let quiet = watch.stalledAfter { throw ToolStalled(tool: (launchPath as NSString).lastPathComponent, quiet: quiet) }
        return CommandResult(
            status: status,
            stdout: String(decoding: outData.data, as: UTF8.self),
            stderr: String(decoding: errData.data, as: UTF8.self)
        )
    }
}

/// what one pipe of a tool printed, gathered by its reader thread
final class Drained: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: Data())
    func append(_ d: Data) { lock.withLock { $0.append(d) } }
    var data: Data { lock.withLock { $0 } }
}

public enum SnapshotBackendError: Error, Equatable {
    case commandFailed(tool: String, status: Int32, stderr: String)
    case couldNotIdentifyNewSnapshot
    case refusedForeignSnapshot(name: String)
    case malformedSnapshotName(String)
    case dataVolumeNotFound
}
