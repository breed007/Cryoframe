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
//  The copy has the library's name, and its own extended attributes (a package's
//  bundle bit among them), so a disk image built from it has the layout a direct
//  build has: a package as one item on the volume root, a plain folder's contents
//  spread over it (see RestoreEngine). The copier is the mirror's (MirrorCopy.sync:
//  attributes, access lists, read-only files, sparse files), plus two things a
//  direct disk image keeps and rsync doesn't, measured:
//
//    - hard links: hdiutil keeps a library's hard links as one file; rsync -a
//      copies each path as a separate file. They are made links again here.
//    - file flags (hidden, locked): hdiutil keeps them; rsync drops them. They are
//      copied last, since a locked file or folder can't be changed after.
//
//  The copy is removed right after the build, and before any build of the library
//  starts, and by the sweep of scratch a crash leaves (it is a plain copy of the
//  library, with nothing else in it worth keeping).
//

import Foundation

enum FilteredCopy {
    static let folderName = "filtered"

    /// flags a direct disk image keeps that a user may set: no-dump, locked,
    /// append-only, opaque, hidden. (The system's flags need root; compression and
    /// tracking belong to the file system.)
    static let copiedFlags: UInt32 = UInt32(UF_NODUMP | UF_IMMUTABLE | UF_APPEND | UF_OPAQUE | UF_HIDDEN)

    /// Copy `source` to `<buildDir>/filtered/<name>`, leaving out the items neither
    /// sealed format can hold. Returns the copy and what was left out, relative to the
    /// library. Honors Stop (the copy is the caller's to remove).
    static func make(of source: URL, name: String, in buildDir: URL, runner: CommandRunner) throws -> (copy: URL, leftOut: [String]) {
        let fm = FileManager.default
        let folder = buildDir.appendingPathComponent(folderName, isDirectory: true)
        remove(in: buildDir, runner: runner.forTeardown)
        let copy = folder.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: copy, withIntermediateDirectories: true)
        // read before the copy: which paths are links to one file
        let links = hardLinks(in: source)
        let leftOut = try MirrorCopy.sync(source, into: copy, runner: runner) { command in
            let r = try runner.runRetryingBusy(command.tool, command.args, stdin: nil)
            guard r.ok else {
                throw ArchiveError.toolFailed(tool: (command.tool as NSString).lastPathComponent, status: r.status, stderr: r.stderr)
            }
        }
        if runner.control?.isCancelled == true { throw CancelledError() }
        relink(links, source: source, copy: copy)
        try restoreFolderDates(from: source, to: copy, control: runner.control)
        try copyFlags(from: source, to: copy, control: runner.control)
        return (copy, leftOut)
    }

    /// Put every folder's dates back as the library has them, deepest first. rsync
    /// sets them, but the passes after it (the read-only files' --files-from pass, a
    /// relinked file) change a folder by adding to it; a direct build reads the
    /// library's.
    static func restoreFolderDates(from source: URL, to copy: URL, control: RunControl?) throws {
        var rels = [""]
        if let walker = FileManager.default.enumerator(atPath: source.path) {
            while let rel = walker.nextObject() as? String {
                if walker.fileAttributes?[.type] as? FileAttributeType == .typeDirectory { rels.append(rel) }
            }
        }
        for (i, rel) in rels.sorted(by: { $0.count > $1.count }).enumerated() {
            if i % 512 == 0, control?.isCancelled == true { throw CancelledError() }
            let from = rel.isEmpty ? source.path : source.appendingPathComponent(rel).path
            let to = rel.isEmpty ? copy.path : copy.appendingPathComponent(rel).path
            var a = stat(), b = stat()
            guard lstat(from, &a) == 0, lstat(to, &b) == 0, b.st_mode & S_IFMT == S_IFDIR,
                  a.st_mtimespec.tv_sec != b.st_mtimespec.tv_sec || a.st_mtimespec.tv_nsec != b.st_mtimespec.tv_nsec else { continue }
            var times = [a.st_atimespec, a.st_mtimespec]
            _ = utimensat(AT_FDCWD, to, &times, AT_SYMLINK_NOFOLLOW)
        }
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

    // MARK: flags

    /// Give every item of the copy the library's flags (see `copiedFlags`), deepest
    /// first, so nothing is locked before what is inside it is set. Setting a flag
    /// changes no date. A flag that can't be set leaves the item as rsync made it.
    static func copyFlags(from source: URL, to copy: URL, control: RunControl?) throws {
        var rels = [""]
        if let walker = FileManager.default.enumerator(atPath: source.path) {
            while let rel = walker.nextObject() as? String { rels.append(rel) }
        }
        for (i, rel) in rels.sorted(by: { $0.count > $1.count }).enumerated() {
            if i % 512 == 0, control?.isCancelled == true { throw CancelledError() }
            let from = rel.isEmpty ? source.path : source.appendingPathComponent(rel).path
            let to = rel.isEmpty ? copy.path : copy.appendingPathComponent(rel).path
            var a = stat(), b = stat()
            guard lstat(from, &a) == 0, lstat(to, &b) == 0, a.st_mode & S_IFMT == b.st_mode & S_IFMT,
                  a.st_flags & copiedFlags != b.st_flags & copiedFlags else { continue }
            _ = lchflags(to, (b.st_flags & ~copiedFlags) | (a.st_flags & copiedFlags))
        }
    }
}
