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
//  Whatever a crash or a failed run leaves in staging is thrown away when the next
//  run starts, which clones afresh (0.2 s for 30,000 files). It used to be where the
//  next run started, on the grounds that rsync would make it exact; but rsync decides
//  what to copy by size and date, and a staging copy whose writes were lost (a drive
//  that filled, a crash that committed metadata before data) holds files whose size
//  and date are right and whose data isn't. rsync passed them over, the swap put them
//  in place, and the run reported success.
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
    /// `beforeSwap` runs once the new copy is complete and before it goes in place; if
    /// it throws, the staging copy is removed and the previous copy stays.
    static func update(volume: URL, name: String, source: URL, runner: CommandRunner,
                       execute: (Command) throws -> Void, beforeSwap: () throws -> Void = {}) throws {
        let fm = FileManager.default
        let current = volume.appendingPathComponent(name, isDirectory: true)
        let staging = volume.appendingPathComponent(stagingName, isDirectory: true)
        let next = staging.appendingPathComponent(name, isDirectory: true)
        // never start from what a previous run left (see above); a leftover that won't
        // go fails the run rather than being trusted
        if fm.fileExists(atPath: staging.path) {
            removeStaging(staging, runner: runner.forTeardown)
            if fm.fileExists(atPath: staging.path) { throw MirrorCopyError.stagingStuck(staging.path) }
        }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        if fm.fileExists(atPath: current.path) {
            try clone(current, to: next, runner: runner)
        } else {
            try fm.createDirectory(at: next, withIntermediateDirectories: true)   // the first run
        }

        do {
            try sync(source, into: next, runner: runner, execute: execute)
        } catch ArchiveError.toolFailed(_, _, let stderr) where stderr.localizedCaseInsensitiveContains("No space left on device") {
            // Updating beside the previous copy needs room for everything that changed
            // as well as the library. When the drive runs out, the staging copy is what
            // is holding it full: left there, every later run failed the same way even
            // once the library had shrunk. The previous copy is untouched.
            removeStaging(staging, runner: runner.forTeardown)
            throw MirrorCopyError.driveFilled
        }

        do {
            try beforeSwap()
        } catch {
            removeStaging(staging, runner: runner.forTeardown)
            throw error
        }

        // Never swap anywhere but inside the image. If it went away under the run,
        // `volume` is now a plain folder on the startup disk.
        guard MountPoint.isMounted(volume) else { throw MirrorCopyError.imageWentAway(volume.path) }
        try putInPlace(next, current)
        removeStaging(staging, runner: runner)
    }

    /// rsync `source` into `next`, carrying extended attributes, resource forks and
    /// ACLs (-E) for every file, including read-only ones.
    ///
    /// openrsync's -E fails on any file its owner can't write ("openat: Permission
    /// denied") and gives up on the whole run: measured with and without -p, --chmod,
    /// --inplace and -W, from a read-write and a read-only volume. Every git
    /// repository keeps its objects 0444, so a folder holding one never mirrored at
    /// all. There is no other rsync on macOS 26. So when the source holds read-only
    /// files, they are left out of the -E pass, copied by a plain -a pass (which
    /// handles them), and given their attributes and ACL with copyfile(3).
    static func sync(_ source: URL, into next: URL, runner: CommandRunner,
                     execute: (Command) throws -> Void) throws {
        let readOnly = readOnlyFiles(in: source)
        guard !readOnly.isEmpty else {
            try execute(ArchivePlan.rsync(root: source, into: next))
            return
        }
        let fm = FileManager.default
        let lists = fm.temporaryDirectory.appendingPathComponent("cf-rsync-\(UUID().uuidString)")
        try fm.createDirectory(at: lists, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: lists) }
        let exclude = lists.appendingPathComponent("exclude"), files = lists.appendingPathComponent("files")
        // NUL-separated (-0), so no name can break a line; excludes anchored to the
        // top of the transfer, with rsync's pattern characters escaped
        try Data(readOnly.map { "/" + escapedPattern($0) + "\0" }.joined().utf8).write(to: exclude)
        // "./" first: openrsync reads a --files-from line starting with "#" or ";" as a
        // comment, even NUL-separated, and skipped those files without a word
        try Data(readOnly.map { "./" + $0 + "\0" }.joined().utf8).write(to: files)

        if readOnly.contains(where: { $0.contains("\\") }) {
            // openrsync's filters can't match a backslash, escaped or not, so such a
            // file can't be left out of the -E pass. Then no filter at all: a plain -a
            // pass for everything (content, modes, deletions), and -E for everything
            // but the read-only files, named one by one and without recursing (-a's -r,
            // or naming the library folder itself, would reach them again). The
            // library folder's own attributes and ACL go by copyfile, as the read-only
            // files' do. Slower, and only for this.
            let others = lists.appendingPathComponent("others")
            try Data(everythingBut(readOnly, in: source).map { "./" + $0 + "\0" }.joined().utf8).write(to: others)
            try execute(Command("/usr/bin/rsync", ["-a", "--delete", "--partial", source.path + "/", next.path + "/"]))
            try execute(Command("/usr/bin/rsync", ["-lptgoDE", "-0", "--files-from=\(others.path)", source.path + "/", next.path + "/"]))
            try copyAttributes(from: source, to: next)
        } else {
            try execute(ArchivePlan.rsync(root: source, into: next, extra: ["-0", "--exclude-from=\(exclude.path)"]))
            try execute(Command("/usr/bin/rsync", ["-a", "-0", "--files-from=\(files.path)", source.path + "/", next.path + "/"]))
        }
        for (i, rel) in readOnly.enumerated() {
            if i % 256 == 0, runner.control?.isCancelled == true { throw CancelledError() }
            try copyAttributes(from: source.appendingPathComponent(rel), to: next.appendingPathComponent(rel))
        }
    }

    /// regular files under `root` their owner can't write, relative to it.
    static func readOnlyFiles(in root: URL) -> [String] {
        guard let walker = FileManager.default.enumerator(atPath: root.path) else { return [] }
        var out: [String] = []
        while let rel = walker.nextObject() as? String {
            var st = stat()
            guard lstat(root.appendingPathComponent(rel).path, &st) == 0,
                  st.st_mode & S_IFMT == S_IFREG, st.st_mode & S_IWUSR == 0 else { continue }
            out.append(rel)
        }
        return out
    }

    /// every entry under `root` (folders, links, files) except those in `excluded`
    static func everythingBut(_ excluded: [String], in root: URL) -> [String] {
        let skip = Set(excluded)
        guard let walker = FileManager.default.enumerator(atPath: root.path) else { return [] }
        var out: [String] = []
        while let rel = walker.nextObject() as? String { if !skip.contains(rel) { out.append(rel) } }
        return out
    }

    /// `name` as an rsync pattern that matches only itself (no backslash: see sync).
    static func escapedPattern(_ name: String) -> String {
        var out = ""
        for c in name {
            if "*?[]\\".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }

    /// extended attributes (resource fork included) and ACL, onto a copy that is
    /// read-only like its source: made writable for the moment it takes.
    static func copyAttributes(from src: URL, to dst: URL) throws {
        var st = stat()
        guard lstat(dst.path, &st) == 0 else { return }
        chmod(dst.path, (st.st_mode & 0o7777) | S_IWUSR)
        defer { chmod(dst.path, st.st_mode & 0o7777) }
        guard copyfile(src.path, dst.path, nil, copyfile_flags_t(COPYFILE_XATTR | COPYFILE_ACL)) == 0 else {
            throw ArchiveError.toolFailed(tool: "copyfile", status: errno,
                                          stderr: "\(src.lastPathComponent): couldn't copy its attributes (\(String(cString: strerror(errno))))")
        }
    }

    /// push everything written to the image down to its bands on the drive: rsync's
    /// data sits in memory until then, and a drive that fills afterwards loses it
    static func flush(volume: URL) {
        Darwin.sync()
        let fd = open(volume.path, O_RDONLY)
        if fd >= 0 { _ = fcntl(fd, F_FULLFSYNC); close(fd) }
        Darwin.sync()
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
    /// the drive came close to full while the image was being written: another program
    /// was writing to it too. `swapped`: the new copy had already gone in place.
    case driveFilledByAnother(swapped: Bool)
    /// fsck_apfs found the file system inside the image damaged
    case imageDamaged(String)
    /// what a previous run left in the image couldn't be removed
    case stagingStuck(String)
}

extension MirrorCopyError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .imageWentAway(let path):
            return "the mirror's disk image was detached from \(path) during the run; the previous copy is untouched — run again"
        case .driveFilled:
            return "the mirror ran out of room during the run. A mirror is updated beside the previous copy, so it needs room for everything that changed as well as the library. The previous copy is intact; free up space on the drive, or use a bigger one, and run again."
        case .driveFilledByAnother(let swapped):
            let copy = swapped
                ? "The mirror holds the previous copy or the updated one, whichever the drive kept; its file system checked out."
                : "Nothing was updated, and the mirror's file system checked out."
            return "the drive nearly filled while the mirror was being written, because something else was writing to it at the same time. A disk image loses writes when its drive fills, so this run doesn't count. \(copy) Make room on the drive and run again."
        case .imageDamaged(let why):
            return "the drive filled while the mirror was being written, and the mirror's disk image is damaged (\(why)). Don't rely on this copy: run a restore drill, and consider starting this mirror afresh on a drive with room to spare."
        case .stagingStuck(let path):
            return "an unfinished copy a previous run left inside the mirror (\(path)) couldn't be removed, and it can't be trusted, so nothing was updated. The previous copy is intact; run again, and if this repeats, start this mirror afresh."
        case .swapFailed(let why):
            return "couldn't put the updated copy in place (\(why)); the previous copy is untouched — run again"
        }
    }
}
