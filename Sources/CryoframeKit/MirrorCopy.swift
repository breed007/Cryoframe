//
//  MirrorCopy.swift
//  CryoframeKit
//
//  Updates the library copy inside a mounted mirror image without ever leaving it
//  half-updated.
//
//  The mirror used to be rewritten in place by `rsync --delete`, so a crash, a Stop
//  or a failure mid-run left the only copy part old and part new. Now, inside the
//  image:
//
//    <volume>/<name>                       the last complete copy; restore reads this
//    <volume>/.cryoframe-staging/<name>    the copy being brought up to date
//
//  The staging copy starts as an APFS clone of the complete one, which costs
//  metadata, not space. rsync brings it up to date; only once rsync has succeeded
//  are the two swapped, in one atomic rename, and the previous copy is removed.
//  At every instant <volume>/<name> is a complete copy: the old one until the swap,
//  the new one after it.
//
//  Whatever a crash leaves in staging (a half-updated copy, or the previous copy the
//  swap moved aside) is where the next run starts: rsync makes it match the source
//  exactly either way, and usually has less to do than from a fresh clone.
//
//  The staging folder sits one level below the volume root on purpose. Restore,
//  drills and rehearsals look for <volume>/<name>, and anything searching the root
//  for a library (a database probe, say) never mistakes the staging copy for it.
//

import Foundation

enum MirrorCopy {
    static let stagingName = ".cryoframe-staging"

    /// bring `<volume>/<name>` up to date with `source`. `execute` runs a tool as the
    /// run does (honoring Stop, throwing on failure).
    static func update(volume: URL, name: String, source: URL, runner: CommandRunner,
                       execute: (Command) throws -> Void) throws {
        let fm = FileManager.default
        let current = volume.appendingPathComponent(name, isDirectory: true)
        let staging = volume.appendingPathComponent(stagingName, isDirectory: true)
        let next = staging.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        if !fm.fileExists(atPath: next.path) {
            if fm.fileExists(atPath: current.path) {
                try clone(current, to: next, runner: runner)
            } else {
                try fm.createDirectory(at: next, withIntermediateDirectories: true)   // the first run
            }
        }

        do {
            try execute(ArchivePlan.rsync(root: source, into: next))
        } catch ArchiveError.toolFailed(_, _, let stderr) where stderr.localizedCaseInsensitiveContains("No space left on device") {
            // Updating beside the previous copy needs room for everything that changed
            // as well as the library. When the drive runs out, the staging copy is what
            // is holding it full: left there, every later run failed the same way even
            // once the library had shrunk. The previous copy is untouched.
            removeStaging(staging, runner: runner.forTeardown)
            throw MirrorCopyError.driveFilled
        }

        // Never swap anywhere but inside the image. If it went away under the run,
        // `volume` is now a plain folder on the startup disk.
        guard MountPoint.isMounted(volume) else { throw MirrorCopyError.imageWentAway(volume.path) }
        try putInPlace(next, current)
        removeStaging(staging, runner: runner)
    }

    /// An APFS clone of the whole tree. clonefile(2) on a directory is atomic (all of
    /// it or none) and, measured on 30,000 files, took 0.2 s where cloning file by file
    /// took 8 s. Apple steers directory copies to copyfile(3) instead; the reasons
    /// (a long uninterruptible call holding up other users of the volume) don't apply
    /// to a volume only this run has mounted. It doesn't carry directory times or
    /// nested ACLs, and doesn't need to: the rsync that always follows restores both,
    /// measured by an rsync dry run finding nothing left to change. If the clone is
    /// refused, `cp -c` clones file by file.
    static func clone(_ from: URL, to: URL, runner: CommandRunner) throws {
        if clonefile(from.path, to.path, UInt32(CLONE_NOFOLLOW | CLONE_ACL)) == 0 { return }
        let r = try runner.run("/bin/cp", ["-c", "-R", "-p", from.path, to.path], stdin: nil)
        guard r.ok else {
            throw ArchiveError.toolFailed(tool: "cp", status: r.status, stderr: r.stderr)
        }
    }

    /// exchange the two copies in one step (or, on the first run, move the new one
    /// into place).
    ///
    /// A deny-delete ACL on either top folder forbids renaming it, and every standard
    /// home folder carries one (Documents, Music, Pictures and the rest) which rsync -E
    /// faithfully copies. So a mirror of one of those would fail every run here. The
    /// ACLs are lifted from both top folders for the rename and put back after it.
    static func putInPlace(_ next: URL, _ current: URL) throws {
        let exchange = FileManager.default.fileExists(atPath: current.path)
        let flags = UInt32(exchange ? RENAME_SWAP : RENAME_EXCL)
        if renamex_np(next.path, current.path, flags) == 0 { return }
        let first = errno
        guard first == EPERM || first == EACCES else { throw MirrorCopyError.swapFailed(String(cString: strerror(first))) }

        let nextACL = acl_get_file(next.path, ACL_TYPE_EXTENDED)          // nil when there is none
        let currentACL = exchange ? acl_get_file(current.path, ACL_TYPE_EXTENDED) : nil
        defer {
            if let nextACL { acl_free(UnsafeMutableRawPointer(nextACL)) }
            if let currentACL { acl_free(UnsafeMutableRawPointer(currentACL)) }
        }
        clearACL(next.path)
        if exchange { clearACL(current.path) }
        guard renamex_np(next.path, current.path, flags) == 0 else {
            let e = errno
            if let nextACL { acl_set_file(next.path, ACL_TYPE_EXTENDED, nextACL) }
            if let currentACL { acl_set_file(current.path, ACL_TYPE_EXTENDED, currentACL) }
            throw MirrorCopyError.swapFailed(String(cString: strerror(e)))
        }
        // the paths have traded places: `current` now names the new copy
        if let nextACL { acl_set_file(current.path, ACL_TYPE_EXTENDED, nextACL) }
    }

    private static func clearACL(_ path: String) {
        guard let empty = acl_init(0) else { return }
        acl_set_file(path, ACL_TYPE_EXTENDED, empty)
        acl_free(UnsafeMutableRawPointer(empty))
    }

    /// remove the previous copy. Deny-delete ACLs inside it are lifted first if the
    /// plain remove is refused. Whatever still won't go is left for the next run,
    /// which starts from it rather than cloning again.
    static func removeStaging(_ staging: URL, runner: CommandRunner) {
        let fm = FileManager.default
        try? fm.removeItem(at: staging)
        guard fm.fileExists(atPath: staging.path) else { return }
        _ = try? runner.run("/bin/chmod", ["-R", "-N", staging.path], stdin: nil)
        try? fm.removeItem(at: staging)
    }
}

/// What goes wrong while a run is updating the mirror (MirrorSpaceError is what
/// refuses a run before it starts).
public enum MirrorCopyError: Error, Equatable {
    case imageWentAway(String)
    case swapFailed(String)
    case driveFilled
}

extension MirrorCopyError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .imageWentAway(let path):
            return "the mirror's disk image was detached from \(path) during the run; the previous copy is untouched — run again"
        case .driveFilled:
            return "the mirror ran out of room during the run. A mirror is updated beside the previous copy, so it needs room for everything that changed as well as the library. The previous copy is intact; free up space on the drive, or use a bigger one, and run again."
        case .swapFailed(let why):
            return "couldn't put the updated copy in place (\(why)); the previous copy is untouched — run again"
        }
    }
}
