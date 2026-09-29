//
//  ArchiveReader.swift
//  CryoframeKit
//
//  Opens a produced archive for reading — mount a dmg/sparsebundle read-only, or
//  extract a zip — reassembling split parts first. Shared by StrongVerifier
//  (mount-and-open check) and RestoreEngine (copy the library back out).
//

import Foundation

public struct OpenedArchive: Sendable {
    public let root: URL                 // the mounted/extracted tree to read from
    let work: URL                        // temp scratch to delete on close
    let teardownFn: @Sendable () -> Void

    /// the file in the work dir naming the process that has the archive open.
    static let ownerFileName = "owner.json"

    static func recordOwner(in work: URL) {
        guard let me = ProcessIdentity.current, let data = try? JSONEncoder().encode(me) else { return }
        try? data.write(to: work.appendingPathComponent(ownerFileName), options: .atomic)
    }

    /// An open archive's work dir may be swept once whoever opened it is gone. The
    /// app, the scheduled agent and a second app instance share one temp folder, and
    /// each has archives open for verifies, drills, rehearsals and browsing. One with
    /// no readable owner was opened by an older version, or caught in the instant
    /// before its owner was written; it waits a day, longer than any of those take.
    static func isAbandoned(_ work: URL, now: Date, isAlive: (ProcessIdentity) -> Bool) -> Bool {
        if let data = try? Data(contentsOf: work.appendingPathComponent(ownerFileName)),
           let owner = try? JSONDecoder().decode(ProcessIdentity.self, from: data) {
            return !isAlive(owner)
        }
        guard let made = (try? work.resourceValues(forKeys: [.creationDateKey]))?.creationDate else { return false }
        return now.timeIntervalSince(made) > 24 * 3600
    }

    /// detach the mount (if any) and remove the scratch dir. Always call this.
    public func close() {
        teardownFn()
        Self.removeWork(work)
    }

    /// the scratch dir holds the mount directory. If the volume would not detach,
    /// removing the scratch dir recursively walks into the mounted archive, so it
    /// stays for the launch sweep instead (see MountPoint).
    static func removeWork(_ work: URL) {
        let mnt = work.appendingPathComponent("mnt")
        guard !MountPoint.isMounted(mnt) else { return }
        try? FileManager.default.removeItem(at: work)
    }
}

public struct ArchiveReader: Sendable {
    let runner: CommandRunner
    let workBase: URL
    let transientSettle: TimeInterval
    public init(runner: CommandRunner = ProcessCommandRunner(),
                workBase: URL = FileManager.default.temporaryDirectory,
                transientSettle: TimeInterval = 5) {
        self.runner = runner; self.workBase = workBase; self.transientSettle = transientSettle
    }

    /// open `result` into a fresh temp work dir. A non-nil `passphrase` mounts an
    /// AES-256 encrypted dmg/sparsebundle (via `hdiutil -stdinpass`). The caller
    /// MUST `close()` the returned handle to detach the mount and clean up.
    ///
    /// A disk-image system that stays busy through every retry of the attach gets one
    /// more attempt, from scratch. The retries all run with whatever the first failed
    /// attach left behind still in place, and a leftover device is exactly what makes
    /// the next attach fail; the failed open has cleared those by the time it throws.
    /// Without this a drill, a rehearsal or a run's verification reported a good
    /// archive as unopenable whenever Time Machine or another job held the disk-image
    /// system for a few seconds too long, and a scheduled check turned that into an
    /// alert. A second failure is reported as before: busy, not broken.
    public func open(_ result: ArchiveResult, passphrase: String? = nil) throws -> OpenedArchive {
        do {
            return try openOnce(result, passphrase: passphrase)
        } catch let error as ArchiveError where Self.isTransient(error) {
            if runner.control?.isCancelled == true { throw CancelledError() }
            Thread.sleep(forTimeInterval: transientSettle)
            return try openOnce(result, passphrase: passphrase)
        }
    }

    /// a tool failure the disk-image system reports while it is saturated, as opposed
    /// to one that says something about the archive.
    static func isTransient(_ error: ArchiveError) -> Bool {
        guard case .toolFailed(_, _, let stderr) = error else { return false }
        return ProcessCommandRunner.isTransient(stderr)
    }

    private func openOnce(_ result: ArchiveResult, passphrase: String?) throws -> OpenedArchive {
        let fm = FileManager.default
        let work = workBase.appendingPathComponent("cf-open-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        OpenedArchive.recordOwner(in: work)       // so another process's launch sweep leaves it be
        let runner = self.runner
        let teardown = runner.forTeardown      // still works after Stop, when cleanup matters most
        let enc = passphrase != nil
        let stdin = passphrase.map { Data($0.utf8) }

        // Anything that throws below has already created `work`, and may have got as
        // far as attaching a device. Left alone that debris compounds: a failed attach
        // makes the NEXT attach likelier to fail, until nothing will mount at all.
        var mountPoint: URL?
        var attemptedImage: URL?          // so a device left behind by a failed attach can be found
        do {
            switch result.format {
            case .sealedDMG:
                let dmg = try singleFile(result.artifacts, work: work, name: "reassembled.dmg", fm: fm)
                let mnt = work.appendingPathComponent("mnt"); try fm.createDirectory(at: mnt, withIntermediateDirectories: true)
                mountPoint = mnt; attemptedImage = dmg
                try attach(dmg, at: mnt, encrypted: enc, stdin: stdin)
                return OpenedArchive(root: mnt, work: work) { Self.detach(mnt, runner: teardown) }

            case .liveMirror:
                let mnt = work.appendingPathComponent("mnt"); try fm.createDirectory(at: mnt, withIntermediateDirectories: true)
                mountPoint = mnt; attemptedImage = result.artifacts[0]
                try attach(result.artifacts[0], at: mnt, encrypted: enc, stdin: stdin)
                return OpenedArchive(root: mnt, work: work) { Self.detach(mnt, runner: teardown) }

            case .sealedZip:
                let zip = try singleFile(result.artifacts, work: work, name: "reassembled.zip", fm: fm)
                let ex = work.appendingPathComponent("extract"); try fm.createDirectory(at: ex, withIntermediateDirectories: true)
                try exec(Command("/usr/bin/ditto", ["-x", "-k", zip.path, ex.path]))
                return OpenedArchive(root: ex, work: work) {}
            }
        } catch {
            if let mnt = mountPoint { Self.detach(mnt, runner: teardown) }   // may be a no-op; cheap either way
            if let image = attemptedImage { Self.detachOrphans(ofImage: image, runner: teardown) }
            OpenedArchive.removeWork(work)
            throw error
        }
    }

    /// attach `image` read-only at `mnt`, or say plainly that it is already open.
    ///
    /// A second attach of an image that is already attached fails "Resource busy"
    /// (measured on macOS 26, every combination of format, read-only or not, and
    /// passphrase), which the busy retries then repeated for 13 seconds before the
    /// failure's cleanup detached every device of the image: another reader's mount,
    /// or a mirror run's read-write attach in the middle of its rsync. Older macOS
    /// has been seen answering 0 without mounting anything, so that is caught too.
    private func attach(_ image: URL, at mnt: URL, encrypted: Bool, stdin: Data?) throws {
        let look = runner.forTeardown
        MirrorMounts.releaseAbandoned(image, runner: look)       // a crashed process's attach
        try MirrorMounts.refuseIfOpen(image, runner: look)
        do {
            try DiskImageGate.serialized {
                try exec(ArchivePlan.attach(image: image, mountpoint: mnt, readonly: true, encrypted: encrypted), stdin: stdin)
            }
        } catch {
            try MirrorMounts.refuseIfOpen(image, except: mnt, runner: look)   // opened by someone else meanwhile
            throw error
        }
        guard MountPoint.isMounted(mnt) else {
            throw DiskImageInUse(image: image.path, mountedAt: MirrorMounts.mountPoints(of: image, runner: look))
        }
    }

    /// a single file to operate on — the artifact itself, or split parts reassembled.
    private func singleFile(_ artifacts: [URL], work: URL, name: String, fm: FileManager) throws -> URL {
        if artifacts.count == 1 { return artifacts[0] }
        let out = work.appendingPathComponent(name)
        fm.createFile(atPath: out.path, contents: nil)
        let w = try FileHandle(forWritingTo: out); defer { try? w.close() }
        for part in artifacts.sorted(by: { $0.path < $1.path }) {
            let r = try FileHandle(forReadingFrom: part); defer { try? r.close() }
            while true {
                let chunk = try r.read(upToCount: 1 << 20) ?? Data()
                if chunk.isEmpty { break }
                try w.write(contentsOf: chunk)
            }
        }
        return out
    }

    private func exec(_ command: Command, stdin: Data? = nil) throws {
        let r = try runner.runRetryingBusy(command.tool, command.args, stdin: stdin)
        guard r.ok else {
            throw ArchiveError.toolFailed(tool: (command.tool as NSString).lastPathComponent,
                                          status: r.status, stderr: r.stderr)
        }
    }

    /// Force-detach the devices a failed attach of `image` left behind with nothing
    /// mounted on them.
    ///
    /// A failed attach can leave a device behind with NO mount point. Detaching by
    /// path cannot find those, so they accumulate, and each orphan makes the next
    /// attach likelier to fail with EAGAIN until nothing on the Mac will mount. Only
    /// a reboot or a manual detach clears them, which is not a thing to ask of someone
    /// whose backup just failed.
    ///
    /// Only those: this used to detach every device of the image, and the image being
    /// open elsewhere is the commonest reason an attach fails, so it unmounted a
    /// restore in the middle of its copy, or a mirror run in the middle of its rsync.
    @Sendable static func detachOrphans(ofImage image: URL, runner: CommandRunner) {
        guard let r = try? runner.run("/usr/bin/hdiutil", ["info", "-plist"]), r.ok,
              let data = r.stdout.data(using: .utf8),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = root["images"] as? [[String: Any]] else { return }
        let target = image.resolvingSymlinksInPath().path
        for img in images {
            guard let path = img["image-path"] as? String,
                  URL(fileURLWithPath: path).resolvingSymlinksInPath().path == target,
                  let entities = img["system-entities"] as? [[String: Any]],
                  !entities.contains(where: { $0["mount-point"] != nil }) else { continue }
            // whole-disk entries first: detaching one takes its partitions with it.
            let devices = entities.compactMap { $0["dev-entry"] as? String }
                .sorted { $0.count < $1.count }
            // A detach issued during the contention that caused the failed attach is
            // itself likely to come back EAGAIN. Firing it once and discarding the
            // result leaves the orphan exactly where it was.
            for dev in devices { _ = try? runner.runRetryingBusy("/usr/bin/hdiutil", ["detach", dev, "-force"]) }
        }
    }

    /// Returns at once when nothing is mounted there: a failed open cleaned up by
    /// retrying a detach that could only fail, five times with backoff, 6 s in all.
    @Sendable static func detach(_ mnt: URL, runner: CommandRunner) {
        for i in 0..<5 {
            if !MountPoint.isMounted(mnt) { return }
            if let r = try? runner.run("/usr/bin/hdiutil", ["detach", mnt.path]), r.ok { return }
            Thread.sleep(forTimeInterval: 0.4 * Double(i + 1))
        }
        if MountPoint.isMounted(mnt) { _ = try? runner.runRetryingBusy("/usr/bin/hdiutil", ["detach", "-force", mnt.path]) }
    }

    /// on launch, force-detach and remove any archive a crashed process left open,
    /// and any mirror a crashed run left attached. Only those: an archive a live
    /// process has open (the agent verifying a run, a drill, a rehearsal, another
    /// window browsing, a mirror run) is still in use.
    public static func sweepStaleOpens(in directory: URL = FileManager.default.temporaryDirectory,
                                       runner: CommandRunner = ProcessCommandRunner(), now: Date = Date(),
                                       isAlive: (ProcessIdentity) -> Bool = { $0.isAlive }) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        // a mirror run's attach (MirrorMounts) follows the same rules as an open archive
        for e in entries where e.lastPathComponent.hasPrefix("cf-open-") || e.lastPathComponent.hasPrefix(MirrorMounts.prefix) {
            guard OpenedArchive.isAbandoned(e, now: now, isAlive: isAlive) else { continue }
            let mnt = e.appendingPathComponent("mnt")
            if MountPoint.isMounted(mnt) { _ = try? runner.run("/usr/bin/hdiutil", ["detach", "-force", mnt.path]) }
            OpenedArchive.removeWork(e)
        }
    }
}
