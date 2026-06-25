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
}

public extension CommandRunner {
    func run(_ launchPath: String, _ args: [String]) throws -> CommandResult {
        try run(launchPath, args, stdin: nil)
    }

    /// run, retrying briefly on the transient "Resource busy" the disk-image
    /// subsystem returns when concurrent jobs hit hdiutil at once.
    func runRetryingBusy(_ launchPath: String, _ args: [String], stdin: Data? = nil, attempts: Int = 4) throws -> CommandResult {
        var result = try run(launchPath, args, stdin: stdin)
        var tries = 1
        while !result.ok, tries < attempts, result.stderr.localizedCaseInsensitiveContains("resource busy") {
            Thread.sleep(forTimeInterval: 0.5 * Double(tries))
            result = try run(launchPath, args, stdin: stdin)
            tries += 1
        }
        return result
    }
}

/// Real runner over Foundation `Process`. Used by the helper at runtime. When a
/// `RunControl` is attached, a cancel terminates the in-flight process.
public struct ProcessCommandRunner: CommandRunner {
    let control: RunControl?
    public init(control: RunControl? = nil) { self.control = control }

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
        // read before waitUntilExit to avoid pipe-buffer deadlock on large output
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        control?.detach()
        if control?.isCancelled == true { throw CancelledError() }
        return CommandResult(
            status: p.terminationStatus,
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
