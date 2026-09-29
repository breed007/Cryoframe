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

    /// EAGAIN: the disk-image system itself is saturated, whatever is attached
    static func isWaitable(_ stderr: String) -> Bool {
        stderr.localizedCaseInsensitiveContains("resource temporarily unavailable")
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
/// `RunControl` is attached, a cancel terminates the in-flight process.
public struct ProcessCommandRunner: CommandRunner {
    public let control: RunControl?
    public init(control: RunControl? = nil) { self.control = control }
    public var forTeardown: CommandRunner { ProcessCommandRunner() }

    public func run(_ launchPath: String, _ args: [String], stdin: Data? = nil) throws -> CommandResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let inPipe: Pipe? = stdin != nil ? Pipe() : nil
        if let inPipe { p.standardInput = inPipe }
        control?.waitWhilePaused()                  // don't launch the next command while paused
        if let control, !control.attach(p) { throw CancelledError() }
        try p.run()
        if let inPipe, let stdin {                  // feed the passphrase, then EOF
            inPipe.fileHandleForWriting.write(stdin)
            try? inPipe.fileHandleForWriting.close()
        }
        // Drain both pipes at once, and before waitUntilExit. Reading stdout to EOF
        // and only then stderr deadlocks as soon as a tool fills stderr's 64 KB
        // buffer first: it blocks writing, we block reading, forever. rsync writes a
        // line per file it could not read, so a library with a few hundred of them
        // hung a mirror run with the snapshot held.
        nonisolated(unsafe) var errData = Data()
        let errDrained = DispatchSemaphore(value: 0)
        let errHandle = err.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            errData = errHandle.readDataToEndOfFile()
            errDrained.signal()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        errDrained.wait()
        let status = p.waitForExit()           // not waitUntilExit: see ProcessWait
        control?.detach()
        if control?.isCancelled == true { throw CancelledError() }
        return CommandResult(
            status: status,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }
}

public enum SnapshotBackendError: Error, Equatable {
    case commandFailed(tool: String, status: Int32, stderr: String)
    case couldNotIdentifyNewSnapshot
    case refusedForeignSnapshot(name: String)
    case malformedSnapshotName(String)
    case dataVolumeNotFound
}
