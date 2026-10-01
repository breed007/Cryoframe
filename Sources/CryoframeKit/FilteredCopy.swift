//
//  FilteredCopy.swift
//  CryoframeKit
//
//  A copy of a library without its named pipes, sockets and devices, for a sealed
//  build to read instead of the library.
//
//  Neither sealed format can hold those items: `hdiutil create -srcfolder` and
//  `ditto -c -k` both open a named pipe and wait for a writer forever, and both
//  refuse a socket. Neither can be told to skip them. They are connections a
//  running program makes and hold no data (see MirrorCopy.isLeftOut), so a folder
//  that holds one (a developer's home, a folder an editor or ssh works in) is
//  copied without them into scratch, and the unchanged build reads the copy:
//
//    <buildDir>/filtered/<name>     the library, less what was left out
//    <buildDir>/<name>.dmg|.zip     the archive, built from it as from the library
//
//  The same copy, with its locks taken off, is what a disk image is built from where
//  macOS's disk image tool can't build from locked items (macOS 15; see
//  SealedReadPlan), and the run says which items lost their lock.
//
//  The copy has the library's name, and its own extended attributes (a package's
//  bundle bit among them), so a disk image built from it has the layout a direct
//  build has: a package as one item on the volume root, a plain folder's contents
//  spread over it (see RestoreEngine). The copier is the mirror's (MirrorCopy.sync:
//  attributes, access lists, read-only files, sparse files, folder dates, and file
//  flags, which hdiutil keeps and rsync drops), plus hard links: hdiutil keeps a
//  library's hard links as one file, and rsync -a copies each path as a separate
//  file, so they are made links again here, before anything is locked.
//
//  The copy is removed right after the build, before any build of the library
//  starts, at the start of every run of its job, and by the sweep of scratch at the
//  app's launch (it is a plain copy of the library, with nothing else in it worth
//  keeping). It is a plaintext copy, an encrypted job's too, so while it exists it is
//  kept out of Time Machine and Spotlight by marks of its own: the default scratch
//  (the system cache) is passed over by both, but a scratch location chosen in
//  Settings may be anywhere. An encrypted job's copy is never made there at all (see
//  JobExecutor.plaintextScratch).
//

import Foundation

enum FilteredCopy {
    static let folderName = "filtered"

    /// the flags the copy carries, as a direct disk image does (see MirrorCopy.copyFlags)
    static let copiedFlags: UInt32 = MirrorCopy.copiedFlags

    /// Copy `source` to `<buildDir>/filtered/<name>`, leaving out the items neither
    /// sealed format can hold. Returns the copy and what was left out, relative to the
    /// library. Honors Stop (the copy is the caller's to remove).
    static func make(of source: URL, name: String, in buildDir: URL, runner: CommandRunner) throws -> (copy: URL, leftOut: [String]) {
        let fm = FileManager.default
        let folder = buildDir.appendingPathComponent(folderName, isDirectory: true)
        remove(in: buildDir, runner: runner.forTeardown)
        let copy = folder.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        markPrivate(folder)
        try fm.createDirectory(at: copy, withIntermediateDirectories: true)
        // read before the copy: which paths are links to one file
        let links = hardLinks(in: source)
        let leftOut: [String]
        do {
            // hard links made again before anything is locked (see MirrorCopy.sync)
            leftOut = try MirrorCopy.sync(source, into: copy, runner: runner, beforeLocking: {
                if runner.control?.isCancelled == true { throw CancelledError() }
                relink(links, source: source, copy: copy)
            }) { command in
                let r = try runner.runRetryingBusy(command.tool, command.args, stdin: nil)
                guard r.ok else {
                    throw ArchiveError.toolFailed(tool: (command.tool as NSString).lastPathComponent, status: r.status, stderr: r.stderr)
                }
            }
        } catch let error where ranOutOfSpace(error, at: buildDir) {
            throw FilteredCopyError.scratchFilled(volume: RestoreRoom.volumeName(for: buildDir), library: name)
        }
        if runner.control?.isCancelled == true { throw CancelledError() }
        return (copy, leftOut)
    }

    /// Whether a failed copy failed for want of room. rsync's own word for it is
    /// "No space left on device", but a copy that fills its volume can end with
    /// something else entirely (measured: "rsync failed — unexpected end of file",
    /// its receiving side having died of it); the volume, nearly full with the copy
    /// still on it, tells.
    static func ranOutOfSpace(_ error: Error, at dir: URL) -> Bool {
        if case ArchiveError.toolFailed(_, let status, let stderr)? = error as? ArchiveError,
           status == ENOSPC || stderr.localizedCaseInsensitiveContains("No space left on device") { return true }
        guard error is ArchiveError, let free = JobExecutor.freeNow(for: dir) else { return false }
        return free < nearlyFull
    }

    /// Whether this Mac's disk image tool builds from locked items (and keeps their
    /// locks). Measured: macOS 26 and 27 do; macOS 15 refuses any folder holding one
    /// ("could not access /Volumes/<library>/locked.txt - Operation not permitted"), a
    /// direct build included (CI's runner, 2026-10-01). macOS 26 reports itself as 16
    /// to a program built with an older SDK, so anything from 16 on counts as 26.
    static var diskImageKeepsLocks: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 16
    }

    /// Build `source`'s sealed archive in `buildDir`, reading it the way `plan` says:
    /// directly, or from a copy made in `copyDir` (removed however the build ends,
    /// Stop included). `found` is what the run's walk of the library found. A disk
    /// image the tool refuses to build directly from a library holding locked items
    /// is built from an unlocked copy instead, whatever this macOS. Returns the
    /// archive and what the run says about how it was built.
    static func sealedArchive(_ engine: SealedArchiveEngine, source: ArchiveSource, found: DMGBlockers, plan: SealedReadPlan,
                              buildDir: URL, copyDir: URL, library: String,
                              runner: CommandRunner) throws -> (archive: ArchiveResult, notes: [String]) {
        let zip = engine.sealed == .zip
        var plan = plan
        if !plan.fromCopy {
            do {
                let archive = try engine.archive(source, to: buildDir)
                return (archive, zip ? [found.unlockedInSealed(library: library, zip: true)].compactMap { $0 } : [])
            } catch let ArchiveError.toolFailed(tool, _, stderr)
                        where tool == "hdiutil" && refusedOutright(stderr) && found.count(.locked) > 0 {
                if runner.control?.isCancelled == true { throw CancelledError() }
                plan = SealedReadPlan(fromCopy: true, unlocked: true)
            }
        }
        // removed however the build ends, Stop included, before anything reads the archive
        defer {
            remove(in: copyDir, runner: runner.forTeardown)
            if copyDir.path != buildDir.path { removeEmpty(copyDir) }
        }
        try ScratchLayout.claim(libraryDir: copyDir)
        let copy: URL
        do {
            copy = try make(of: source.root, name: source.name, in: copyDir, runner: runner).copy
        } catch FilteredCopyError.scratchFilled(let volume, let library, _) where engine.passphrase != nil {
            throw FilteredCopyError.scratchFilled(volume: volume, library: library, encrypted: true)
        }
        if plan.unlocked { MirrorCopy.unlock(copy) }
        let built = try build(engine, from: ArchiveSource(name: source.name, root: copy, sizeHint: source.sizeHint),
                              to: buildDir, library: library)
        var notes: [String] = []
        if let note = found.leftOutOfSealed(library: library, zip: zip) { notes.append(note) }
        if zip || plan.unlocked || built.note != nil,
           let note = found.unlockedInSealed(library: library, zip: zip) ?? built.note { notes.append(note) }
        return (built.archive, notes)
    }

    /// Build the archive from the copy (`from`). A disk image hdiutil refuses outright
    /// (see `refusedOutright`) is tried once more with nothing in the copy locked, and
    /// says so in `note`; refused again, the build fails saying why.
    static func build(_ engine: SealedArchiveEngine, from: ArchiveSource, to dir: URL,
                      library: String) throws -> (archive: ArchiveResult, note: String?) {
        do {
            return (try engine.archive(from, to: dir), nil)
        } catch let ArchiveError.toolFailed(tool, _, stderr) where tool == "hdiutil" && refusedOutright(stderr) {
            MirrorCopy.unlock(from.root)
            do {
                return (try engine.archive(from, to: dir), unlockedNote(library: library))
            } catch let ArchiveError.toolFailed(tool, status, stderr) where tool == "hdiutil" && refusedOutright(stderr) {
                throw FilteredCopyError.diskImageRefused(
                    library: library, detail: ArchiveError.toolFailed(tool: tool, status: status, stderr: stderr).localizedDescription)
            }
        }
    }

    /// Whether hdiutil refused to build from the copy with "Operation not permitted".
    ///
    /// On macOS 15 (CI's runner, 2026-10-01) every disk image built from a copy of a
    /// library holding locked and hidden items, an access list and hard links failed
    /// "create failed - Operation not permitted", while a direct build of the same
    /// library, and a filtered one of a library without them, succeeded; macOS 26 and
    /// 27 build both. The likeliest difference is the locked flags the copy is given
    /// (see MirrorCopy.copyFlags), set by a different process than the library's, so
    /// the build is tried once more with nothing in the copy locked (unmeasured: no
    /// macOS 15 here). If that is refused too, the run says so plainly; either way the
    /// copy is removed.
    static func refusedOutright(_ stderr: String) -> Bool {
        stderr.localizedCaseInsensitiveContains("Operation not permitted")
    }

    /// what the run says when the disk image was built from a copy with nothing locked
    static func unlockedNote(library: String) -> String {
        "\(library): the disk image tool wouldn't build from a copy holding locked items, so they are in the disk image unlocked. Everything else is as in the folder."
    }

    /// free bytes under which a volume a copy failed on counts as having filled
    static let nearlyFull: UInt64 = 32 << 20

    /// Keep the folder holding the copy out of Time Machine (the sticky exclusion
    /// attribute, which travels with the folder) and Spotlight. Best effort: a volume
    /// that can't take either mark still holds the copy only for the build.
    static func markPrivate(_ folder: URL) {
        var folder = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        FileManager.default.createFile(atPath: folder.appendingPathComponent(".metadata_never_index").path, contents: Data())
    }

    /// Remove every copy a run of `jobID` left in each of `bases` (`<base>/<job>/build/<library>/filtered`),
    /// and the folders that held only that. Only in a job folder that is provably
    /// Cryoframe's (see ScratchLayout), and only for a job whose run lock is held.
    static func removeLeftovers(jobID: String, under bases: [URL]) {
        let fm = FileManager.default
        var seen = Set<String>()
        for base in bases where seen.insert(base.standardizedFileURL.path).inserted {
            let jobDir = base.appendingPathComponent(jobID, isDirectory: true)
            guard ScratchLayout.isOurs(jobDir, jobID: jobID) else { continue }
            let build = jobDir.appendingPathComponent("build", isDirectory: true)
            guard ScratchLayout.isRealFolder(build) else { continue }
            for lib in (try? fm.contentsOfDirectory(at: build, includingPropertiesForKeys: nil)) ?? [] {
                var st = stat()
                guard ScratchLayout.isRealFolder(lib), lstat(lib.appendingPathComponent(folderName).path, &st) == 0 else { continue }
                remove(in: lib, runner: ProcessCommandRunner())
                removeEmpty(lib)
            }
        }
    }

    /// `<base>/<job>/build/<library>` and `build`, each only if empty, then the job's
    /// folder if it holds nothing but its mark (see ScratchLayout.tidy)
    static func removeEmpty(_ libDir: URL) {
        guard rmdir(libDir.path) == 0 else { return }
        ScratchLayout.tidy(jobDir: libDir.deletingLastPathComponent().deletingLastPathComponent())
    }

    /// Remove the filtered copy in `buildDir`, if there is one. A locked file, a
    /// read-only folder or a deny-delete access list, all kept by the copy, are what
    /// stops a plain remove.
    static func remove(in buildDir: URL, runner: CommandRunner) {
        let fm = FileManager.default
        let folder = buildDir.appendingPathComponent(folderName, isDirectory: true)
        var st = stat()
        guard lstat(folder.path, &st) == 0 else { return }
        try? fm.removeItem(at: folder)
        guard lstat(folder.path, &st) == 0 else { return }
        _ = try? runner.run("/usr/bin/chflags", ["-R", "0", folder.path], stdin: nil)
        _ = try? runner.run("/bin/chmod", ["-R", "-N", folder.path], stdin: nil)
        _ = try? runner.run("/bin/chmod", ["-R", "u+w", folder.path], stdin: nil)
        try? fm.removeItem(at: folder)
    }

    // MARK: hard links

    /// The library's regular files that are hard links to one another, as groups of
    /// paths relative to `root` (two or more each, sorted). A file whose other links
    /// are outside the library is copied as the one file it is there.
    static func hardLinks(in root: URL) -> [[String]] {
        guard let walker = FileManager.default.enumerator(atPath: root.path) else { return [] }
        struct Inode: Hashable { let dev: dev_t; let ino: ino_t }
        var byInode: [Inode: [String]] = [:]
        while let rel = walker.nextObject() as? String {
            var st = stat()
            guard lstat(root.appendingPathComponent(rel).path, &st) == 0,
                  st.st_mode & S_IFMT == S_IFREG, st.st_nlink > 1 else { continue }
            byInode[Inode(dev: st.st_dev, ino: st.st_ino), default: []].append(rel)
        }
        return byInode.values.filter { $0.count > 1 }.map { $0.sorted() }.sorted { $0[0] < $1[0] }
    }

    /// Make each group's later paths in `copy` hard links to its first, as they are
    /// in `source`. Only where it is plainly safe, so a path that isn't relinked
    /// stays the identical copy rsync made:
    ///   - the copy is on APFS or HFS+ (whose links a disk image build keeps);
    ///   - every folder on the way to either path, in the library and in the copy, is
    ///     a folder and not a link to one;
    ///   - both paths are still one file in the library (a library read live, off a
    ///     drive that can't be frozen, can change under the run);
    ///   - both paths in the copy are files of the library file's size and date.
    /// The link is made beside the path under a temporary name and renamed over it,
    /// and the folder's mode and dates are put back. Returns how many were relinked.
    @discardableResult
    static func relink(_ groups: [[String]], source: URL, copy: URL) -> Int {
        guard !groups.isEmpty, keepsHardLinks(copy) else { return 0 }
        var made = 0
        for group in groups {
            guard let first = group.first else { continue }
            for rel in group.dropFirst() where relinkOne(rel, to: first, source: source, copy: copy) { made += 1 }
        }
        return made
    }

    /// whether the copy's file system is one whose hard links a disk image build keeps
    static func keepsHardLinks(_ url: URL) -> Bool {
        var fs = statfs()
        guard statfs(url.path, &fs) == 0 else { return false }
        let type = withUnsafeBytes(of: fs.f_fstypename) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        return type == "apfs" || type == "hfs"
    }

    private static func relinkOne(_ rel: String, to first: String, source: URL, copy: URL) -> Bool {
        guard foldersAreReal(rel, under: source), foldersAreReal(first, under: source),
              foldersAreReal(rel, under: copy), foldersAreReal(first, under: copy) else { return false }
        var a = stat(), b = stat(), anchor = stat(), target = stat()
        guard lstat(source.appendingPathComponent(first).path, &a) == 0, lstat(source.appendingPathComponent(rel).path, &b) == 0,
              a.st_mode & S_IFMT == S_IFREG, b.st_mode & S_IFMT == S_IFREG,
              a.st_dev == b.st_dev, a.st_ino == b.st_ino else { return false }
        let anchorPath = copy.appendingPathComponent(first).path, targetPath = copy.appendingPathComponent(rel).path
        guard lstat(anchorPath, &anchor) == 0, lstat(targetPath, &target) == 0,
              anchor.st_mode & S_IFMT == S_IFREG, target.st_mode & S_IFMT == S_IFREG,
              anchor.st_ino != target.st_ino,
              sameSizeAndDate(anchor, a), sameSizeAndDate(target, a) else { return false }
        let parent = (targetPath as NSString).deletingLastPathComponent
        var folder = stat()
        guard lstat(parent, &folder) == 0, folder.st_mode & S_IFMT == S_IFDIR else { return false }
        // a read-only folder, kept read-only by the copy: writable for the moment
        let writable = folder.st_mode & S_IWUSR != 0
        if !writable, chmod(parent, (folder.st_mode & 0o7777) | S_IWUSR) != 0 { return false }
        defer {
            if !writable { chmod(parent, folder.st_mode & 0o7777) }
            var times = [folder.st_atimespec, folder.st_mtimespec]
            _ = utimensat(AT_FDCWD, parent, &times, AT_SYMLINK_NOFOLLOW)
        }
        let temporary = (parent as NSString).appendingPathComponent(".cf-link-\(UUID().uuidString)")
        guard linkat(AT_FDCWD, anchorPath, AT_FDCWD, temporary, 0) == 0 else { return false }
        guard rename(temporary, targetPath) == 0 else { unlink(temporary); return false }
        return true
    }

    /// every folder from `root` down to the one holding `rel` is a folder, not a link
    private static func foldersAreReal(_ rel: String, under root: URL) -> Bool {
        var path = root.path
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { return false }
        for component in rel.split(separator: "/").dropLast() {
            path += "/" + component
            guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { return false }
        }
        return true
    }

    private static func sameSizeAndDate(_ x: stat, _ y: stat) -> Bool {
        x.st_size == y.st_size && x.st_mtimespec.tv_sec == y.st_mtimespec.tv_sec && x.st_mtimespec.tv_nsec == y.st_mtimespec.tv_nsec
    }
}

/// How a sealed build reads its library: directly, or from a copy (see FilteredCopy),
/// and whether that copy has its locks taken off.
struct SealedReadPlan: Equatable, Sendable {
    var fromCopy: Bool
    var unlocked: Bool

    static let direct = SealedReadPlan(fromCopy: false, unlocked: false)

    /// A copy when the library holds what neither format can (named pipes, sockets,
    /// devices), or locked items a disk image can't be built from on this Mac (see
    /// FilteredCopy.diskImageKeepsLocks), taken off in the copy. Where the tool keeps
    /// locks a direct build keeps them, so the copy would cost room and lose them for
    /// nothing; a zip drops them either way.
    static func of(_ found: DMGBlockers, _ kind: SealedArchiveEngine.Sealed,
                   diskImageKeepsLocks: Bool = FilteredCopy.diskImageKeepsLocks) -> SealedReadPlan {
        let unlock = kind == .dmg && found.count(.locked) > 0 && !diskImageKeepsLocks
        return SealedReadPlan(fromCopy: found.count(.special) > 0 || unlock, unlocked: unlock)
    }
}

/// What goes wrong making the copy (MirrorCopyError is the mirror's).
public enum FilteredCopyError: Error, Equatable, LocalizedError {
    /// the scratch volume filled while the copy was made; `encrypted`: an encrypted
    /// job's, which is always made on the startup disk (see JobExecutor.plaintextScratch)
    case scratchFilled(volume: String, library: String, encrypted: Bool = false)
    /// hdiutil refused to build from the copy, even with nothing in it locked
    case diskImageRefused(library: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .scratchFilled(let volume, let library, let encrypted):
            let said = "\(volume) ran out of space while a copy of \(library) was being made to build the archive from. Nothing was backed up, and the copy was removed."
            guard encrypted else {
                return said + " Free up space on \(volume), or choose a scratch location with more room in Settings, and run again."
            }
            // the scratch location in Settings has no say in where this copy goes
            return said + " An encrypted job's copy is always made on the startup disk, whatever scratch location Settings names, so choosing another one won't help. Free up at least as much space on \(volume) as \(library) takes, and run again."
        case .diskImageRefused(let library, let detail):
            return "\(library)'s disk image is built from a copy of it (without its named pipes and sockets, or with its locks taken off), and macOS's disk image tool refused to build from that copy (\(detail)). Nothing was backed up, and the copy was removed. The sealed zip format archives this folder."
        }
    }
}
