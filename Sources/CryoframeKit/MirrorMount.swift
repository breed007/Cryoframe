//
//  MirrorMount.swift
//  CryoframeKit
//
//  Where a live mirror's image is attached while a run updates it.
//
//  It used to be attached inside the destination, at `<dest>/.<name>.mirror-mnt`.
//  macOS refuses a mount point on a volume whose ownership is ignored ("Owners:
//  Disabled"), and that is how external drives are set up out of the box, so every
//  mirror run to one failed with "hdiutil: attach failed - Permission denied".
//
//  So each run attaches at a directory of its own in the per-user temp folder, on
//  the boot volume: `cf-mirror-<id>/mnt`, with the run's process recorded beside it
//  the same way ArchiveReader records who has an archive open. That record is what
//  lets cleanup tell a crashed run's attach from a live one:
//    - the next run of the job detaches its image wherever a dead run left it;
//    - the launch sweep (ArchiveReader.sweepStaleOpens) does the same for every
//      dead run, so a restore can open the mirror before the job runs again;
//    - neither touches an attach whose owner is alive.
//  The directories follow MountPoint's rules: removed only once nothing is mounted.
//

import Foundation

public enum MirrorMounts {
    /// names the per-run directories, beside ArchiveReader's `cf-open-` ones.
    public static let prefix = "cf-mirror-"

    /// the per-user temp folder: on the boot volume, which honors ownership, shared
    /// by the app and the scheduled agent, and swept at launch.
    public static var defaultBase: URL { FileManager.default.temporaryDirectory }

    /// a fresh per-run directory with this process named as its owner. A run that
    /// can't record its owner doesn't attach: the launch sweep treats an unowned
    /// directory as abandoned after a day, and a first mirror run can outlast that.
    static func makeWork(in base: URL) throws -> URL {
        let fm = FileManager.default
        let work = base.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        guard let me = ProcessIdentity.current else {
            try? fm.removeItem(at: work)
            throw MirrorMountError.ownerUnrecorded(work.path)
        }
        do {
            try JSONEncoder().encode(me).write(to: work.appendingPathComponent(OpenedArchive.ownerFileName), options: .atomic)
        } catch {
            try? fm.removeItem(at: work)
            throw MirrorMountError.ownerUnrecorded(work.path)
        }
        return work
    }

    /// every place `image` is mounted on this Mac, from `hdiutil info`. Empty when it
    /// isn't attached, or when hdiutil couldn't be asked.
    public static func mountPoints(of image: URL, runner: CommandRunner) -> [String] {
        guard let r = try? runner.run("/usr/bin/hdiutil", ["info", "-plist"], stdin: nil), r.ok,
              let data = r.stdout.data(using: .utf8),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = root["images"] as? [[String: Any]] else { return [] }
        let target = image.resolvingSymlinksInPath().path
        var out: [String] = []
        for img in images {
            guard let path = img["image-path"] as? String,
                  URL(fileURLWithPath: path).resolvingSymlinksInPath().path == target,
                  let entities = img["system-entities"] as? [[String: Any]] else { continue }
            out += entities.compactMap { $0["mount-point"] as? String }
        }
        return out
    }

    /// detach `image` from wherever a run that no longer exists left it attached, and
    /// tidy that run's directory. Attachments with a live owner, and ones that aren't
    /// a mirror run's at all (a restore browsing it, Finder), are left alone; the run
    /// then refuses to write, as it always has, rather than yank someone's open copy.
    static func releaseAbandoned(_ image: URL, runner: CommandRunner, now: Date = Date(),
                                 isAlive: (ProcessIdentity) -> Bool = { $0.isAlive }) {
        for mp in mountPoints(of: image, runner: runner) {
            let mnt = URL(fileURLWithPath: mp, isDirectory: true)
            let work = mnt.deletingLastPathComponent()
            guard mnt.lastPathComponent == "mnt", work.lastPathComponent.hasPrefix(prefix),
                  OpenedArchive.isAbandoned(work, now: now, isAlive: isAlive) else { continue }
            MountPoint.detach(mnt, runner: runner)
            OpenedArchive.removeWork(work)
        }
    }
}

public enum MirrorMountError: Error, Equatable {
    case ownerUnrecorded(String)
}

extension MirrorMountError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .ownerUnrecorded(let path):
            return "couldn't prepare a place to open the mirror (\(path)) — check that the startup disk has free space, then run again"
        }
    }
}
