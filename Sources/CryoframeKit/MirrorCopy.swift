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
import os

enum MirrorCopy {
    static let stagingName = ".cryoframe-staging"

    /// a new copy made in staging, not yet in place
    struct Staged {
        let volume: URL, current: URL, staging: URL, next: URL
    }

    /// Make the new copy of `source` in staging: a fresh clone of the previous copy,
    /// brought up to date. `execute` runs a tool as the run does (honoring Stop,
    /// throwing on failure). The previous copy is untouched.
    static func stage(volume: URL, name: String, source: URL, runner: CommandRunner,
                      execute: (Command) throws -> Void) throws -> Staged {
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
        return Staged(volume: volume, current: current, staging: staging, next: next)
    }

    /// put the new copy in place of the previous one, and remove the previous one
    static func commit(_ s: Staged, runner: CommandRunner) throws {
        // Never swap anywhere but inside the image. If it went away under the run,
        // `volume` is now a plain folder on the startup disk.
        guard MountPoint.isMounted(s.volume) else { throw MirrorCopyError.imageWentAway(s.volume.path) }
        try putInPlace(s.next, s.current)
        removeStaging(s.staging, runner: runner)
    }

    /// give up on the new copy; the previous one stays
    static func abandon(_ s: Staged, runner: CommandRunner) {
        guard MountPoint.isMounted(s.volume) else { return }       // the next run throws it away
        removeStaging(s.staging, runner: runner.forTeardown)
    }

    /// Check the new copy against the library, reading it back from the image.
    ///
    /// A drive that runs out of room for an instant loses the image's writes, and
    /// nothing says so: rsync exits 0, and a file system check can pass while a
    /// file's data is gone. Measured: another program grabbing the drive for 15 to 25
    /// ms at a time, shorter than any free-space watch sees, left 2 runs in 30
    /// reporting success with a file matching neither version. So before the swap the
    /// new copy is read back, and the caller must have detached and attached the image
    /// again first, so the reads come from the drive and not from memory:
    ///   - every path in the library is in the new copy with the same type, size,
    ///     date and link target, and nothing else is;
    ///   - every file this run wrote (its size or date differs from the previous copy,
    ///     or it is new, which is exactly what rsync copies) matches the library byte
    ///     for byte. Files carried over from the previous copy share its blocks.
    ///   - every file and folder carries the library's extended attributes (a resource
    ///     fork, Finder tags) and access list. rsync -E writes those for every item on
    ///     every run, changed or not, and copyAttributes rewrites them on read-only
    ///     files, so they travel through the image the same way and are lost the same
    ///     way. Most items have none, which costs a listing on each side.
    /// A run with nothing changed reads no file data. The library is a frozen snapshot,
    /// so it can't have moved meanwhile (a volume that can't be frozen is read live
    /// with its app closed).
    static func verify(_ s: Staged, against source: URL, control: RunControl?) throws {
        var found = try structure(of: s.next, against: source, previous: s.current, control: control)
        // the bytes of everything this run wrote, several files at a time (opening a
        // file is most of the cost for small ones)
        let mismatched = inParallel(found.written, control: control) { rel, x, y, size in
            byteDifference(source.appendingPathComponent(rel).path, s.next.appendingPathComponent(rel).path, x, y, size)
        }
        let attributes = inParallel(found.present, control: control) { rel, _, _, _ in
            differentAttributes(source.appendingPathComponent(rel).path, s.next.appendingPathComponent(rel).path)
        }
        if control?.isCancelled == true { throw CancelledError() }
        var noted = Set<String>()
        for (rel, what) in mismatched + attributes where noted.insert(rel).inserted {
            found.note(rel.isEmpty ? "the library folder" : rel, what)
        }
        guard found.count == 0 else { throw MirrorCopyError.readBackMismatch(count: found.count, examples: found.examples) }
    }

    /// what differs between a copy and the library, item by item, and which files the
    /// copy holds that `previous` didn't (by size and date: what rsync copies)
    struct Differences {
        var count = 0
        var examples: [String] = []
        var written: [String] = []
        /// the library folder ("") and every file and folder that is in the copy as
        /// the same kind of item (links aside): whose attributes can be compared
        var present: [String] = [""]
        mutating func note(_ rel: String, _ what: String) {
            count += 1
            if examples.count < 3 { examples.append("\(rel) \(what)") }
        }
    }

    /// Compare `copy` with the library by structure: every path there with the same
    /// type, size, date and link target, and nothing else. No file data is read.
    static func structure(of copy: URL, against source: URL, previous: URL?, control: RunControl?) throws -> Differences {
        let fm = FileManager.default
        var found = Differences()
        var inLibrary = Set<String>()
        guard let walker = fm.enumerator(atPath: source.path) else { return found }
        var seen = 0
        while let rel = walker.nextObject() as? String {
            seen += 1
            if seen % 512 == 0, control?.isCancelled == true { throw CancelledError() }
            inLibrary.insert(rel)
            var a = stat(), b = stat(), c = stat()
            guard lstat(source.appendingPathComponent(rel).path, &a) == 0 else { continue }
            if isLeftOut(a.st_mode) { inLibrary.remove(rel); continue }       // not mirrored (see isLeftOut)
            guard lstat(copy.appendingPathComponent(rel).path, &b) == 0 else { found.note(rel, "is missing"); continue }
            let type = a.st_mode & S_IFMT
            guard type == b.st_mode & S_IFMT else { found.note(rel, "is the wrong kind of item"); continue }
            if type == S_IFLNK {
                let t1 = try? fm.destinationOfSymbolicLink(atPath: source.appendingPathComponent(rel).path)
                let t2 = try? fm.destinationOfSymbolicLink(atPath: copy.appendingPathComponent(rel).path)
                if t1 != t2 { found.note(rel, "points somewhere else") }
                continue
            }
            if type == S_IFDIR { found.present.append(rel) }
            guard type == S_IFREG else { continue }
            guard a.st_size == b.st_size, a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec else {
                found.note(rel, "has the wrong size or date"); continue
            }
            found.present.append(rel)
            let carried = previous.map { lstat($0.appendingPathComponent(rel).path, &c) == 0 } == true
                && c.st_size == a.st_size && c.st_mtimespec.tv_sec == a.st_mtimespec.tv_sec
            if !carried { found.written.append(rel) }
        }
        if let extra = fm.enumerator(atPath: copy.path) {
            while found.count < 1000, let rel = extra.nextObject() as? String {
                if !inLibrary.contains(rel) { found.note(rel, "isn't in the library") }
            }
        }
        return found
    }

    /// `check` for each of `rels`, eight at a time; what it found wrong, by item. Each
    /// worker gets two buffers of `size` bytes to read into.
    static func inParallel(_ rels: [String], control: RunControl?,
                           _ check: @Sendable (String, UnsafeMutableRawPointer, UnsafeMutableRawPointer, Int) -> String?) -> [(String, String)] {
        guard !rels.isEmpty else { return [] }
        let workers = min(8, rels.count)
        let bad = OSAllocatedUnfairLock(initialState: [(String, String)]())
        DispatchQueue.concurrentPerform(iterations: workers) { w in
            let size = 1 << 20
            let x = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
            let y = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
            defer { x.deallocate(); y.deallocate() }
            var i = w
            while i < rels.count {
                if control?.isCancelled == true { return }
                if let what = check(rels[i], x, y, size) {
                    let item = (rels[i], what)
                    bad.withLock { $0.append(item) }
                }
                i += workers
            }
        }
        return bad.withLock { $0 }.sorted { $0.0 < $1.0 }
    }

    /// Extended attributes a copy isn't expected to carry: macOS keeps them itself and
    /// won't let a copier write them (the app that wrote the file, privacy grants,
    /// System Integrity Protection, Spotlight's private labels), or, for compression,
    /// doesn't list them at all.
    static func managedBySystem(_ name: String) -> Bool {
        ["com.apple.provenance", "com.apple.macl", "com.apple.rootless", "com.apple.decmpfs"].contains(name)
            || name.hasPrefix("com.apple.system.") || name.hasPrefix("com.apple.metadata:kMDLabel_")
    }

    /// what differs between the extended attributes (names and values) and access
    /// lists of `a` in the library and `b` in the copy, or nil if nothing does. An
    /// item whose attributes can't be read in the library isn't judged on them.
    static func differentAttributes(_ a: String, _ b: String) -> String? {
        guard let names = attributeNames(a) else { return nil }
        guard let copied = attributeNames(b) else { return "has extended attributes that can't be read back" }
        func called(_ n: String) -> String { n == "com.apple.ResourceFork" ? "resource fork" : n }
        var found: [String] = []
        let missing = names.filter { !copied.contains($0) }, extra = copied.filter { !names.contains($0) }
        if !missing.isEmpty { found.append("is missing extended attribute \(missing.map(called).joined(separator: ", "))") }
        if !extra.isEmpty { found.append("has extended attribute \(extra.map(called).joined(separator: ", ")) the library doesn't") }
        let changed = names.filter { copied.contains($0) && attributeValue(a, $0) != attributeValue(b, $0) }
        if !changed.isEmpty {
            found.append(changed == ["com.apple.ResourceFork"] ? "has a different resource fork"
                         : "has a different value for extended attribute \(changed.map(called).joined(separator: ", "))")
        }
        if accessList(a) != accessList(b) {
            found.append(accessList(b) == nil ? "is missing its access list"
                         : accessList(a) == nil ? "has an access list the library doesn't" : "has a different access list")
        }
        return found.isEmpty ? nil : found.joined(separator: "; ")
    }

    /// the item's extended attribute names, sorted, less those the system manages
    static func attributeNames(_ path: String) -> [String]? {
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { return nil }
        guard size > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: size)
        let got = listxattr(path, &buffer, size, XATTR_NOFOLLOW)
        guard got >= 0 else { return nil }
        return buffer[..<got].split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
            .filter { !managedBySystem($0) }.sorted()
    }

    static func attributeValue(_ path: String, _ name: String) -> [UInt8]? {
        let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { return nil }
        var value = [UInt8](repeating: 0, count: size)
        let got = getxattr(path, name, &value, size, 0, XATTR_NOFOLLOW)
        return got >= 0 ? Array(value[..<got]) : nil
    }

    /// the item's access list as text, or nil if it has none
    static func accessList(_ path: String) -> String? {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return nil }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard let text = acl_to_text(acl, nil) else { return nil }
        defer { acl_free(UnsafeMutableRawPointer(text)) }
        return String(cString: text)
    }

    /// What differs between the bytes of `a` in the library and `b` in the copy, or
    /// nil if nothing does. A file that can't be read on either side says so rather
    /// than reading as different data: the one is lost data, the other may not be. The
    /// image was attached afresh for this, and detaching drops what the mount had in
    /// memory, so reads of the new copy come from the drive.
    static func byteDifference(_ a: String, _ b: String, _ x: UnsafeMutableRawPointer, _ y: UnsafeMutableRawPointer,
                               _ size: Int) -> String? {
        func failed(_ what: String) -> String { "\(what) (\(String(cString: strerror(errno))))" }
        let fa = open(a, O_RDONLY)
        guard fa >= 0 else { return failed("couldn't be read in the library") }
        defer { close(fa) }
        let fb = open(b, O_RDONLY)
        guard fb >= 0 else { return failed("couldn't be read back") }
        defer { close(fb) }
        func readSome(_ fd: Int32, _ into: UnsafeMutableRawPointer, _ n: Int) -> Int {
            while true {
                let got = read(fd, into, n)
                if got >= 0 || errno != EINTR { return got }
            }
        }
        while true {
            let n = readSome(fa, x, size)
            guard n >= 0 else { return failed("couldn't be read in the library") }
            if n == 0 {
                let more = readSome(fb, y, 1)
                return more == 0 ? nil : more < 0 ? failed("couldn't be read back") : "doesn't match the library"
            }
            var got = 0
            while got < n {
                let m = readSome(fb, y + got, n - got)
                guard m >= 0 else { return failed("couldn't be read back") }
                guard m > 0 else { return "doesn't match the library" }
                got += m
            }
            if memcmp(x, y, n) != 0 { return "doesn't match the library" }
        }
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
    ///
    /// Named pipes, sockets and devices are left out (see `leftOut(in:)`), and any a
    /// copy made before this holds are taken out of it. Returns the ones left out.
    @discardableResult
    static func sync(_ source: URL, into next: URL, runner: CommandRunner,
                     execute: (Command) throws -> Void) throws -> [String] {
        let survey = survey(source)
        let readOnly = survey.readOnly, leftOut = survey.leftOut
        defer { removeLeftOut(in: next) }
        guard !readOnly.isEmpty || !leftOut.isEmpty else {
            try execute(ArchivePlan.rsync(root: source, into: next))
            try matchSizesAndDates(from: source, to: next, control: runner.control)
            try matchAttributes(from: source, to: next, control: runner.control)
            return []
        }
        let fm = FileManager.default
        let lists = fm.temporaryDirectory.appendingPathComponent("cf-rsync-\(UUID().uuidString)")
        try fm.createDirectory(at: lists, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: lists) }
        let exclude = lists.appendingPathComponent("exclude"), files = lists.appendingPathComponent("files")
        // NUL-separated (-0), so no name can break a line; excludes anchored to the
        // top of the transfer, with rsync's pattern characters escaped
        try Data((readOnly + leftOut).map { "/" + escapedPattern($0) + "\0" }.joined().utf8).write(to: exclude)
        // "./" first: openrsync reads a --files-from line starting with "#" or ";" as a
        // comment, even NUL-separated, and skipped those files without a word
        try Data(readOnly.map { "./" + $0 + "\0" }.joined().utf8).write(to: files)

        if (readOnly + leftOut).contains(where: { $0.contains("\\") }) {
            // openrsync's filters can't match a backslash, escaped or not, so such a
            // file can't be left out of the -E pass. Then no filter at all: a plain
            // pass for everything (content, modes, deletions; without -D, so it passes
            // over pipes and sockets), and -E for everything but the read-only files
            // and those, named one by one and without recursing (-a's -r, or naming the
            // library folder itself, would reach them again). The library folder's own
            // attributes and ACL go by copyfile, as the read-only files' do. Slower,
            // and only for this.
            let others = lists.appendingPathComponent("others")
            try Data(everythingBut(readOnly + leftOut, in: source).map { "./" + $0 + "\0" }.joined().utf8).write(to: others)
            try execute(Command("/usr/bin/rsync", ["-rlptgo", "-S", "--delete", "--partial", source.path + "/", next.path + "/"]))
            try execute(Command("/usr/bin/rsync", ["-lptgoDE", "-S", "-0", "--files-from=\(others.path)", source.path + "/", next.path + "/"]))
            try copyAttributes(from: source, to: next)
        } else {
            try execute(ArchivePlan.rsync(root: source, into: next, extra: ["-0", "--exclude-from=\(exclude.path)"]))
            if !readOnly.isEmpty {
                try execute(Command("/usr/bin/rsync", ["-a", "-S", "-0", "--files-from=\(files.path)", source.path + "/", next.path + "/"]))
            }
        }
        try matchSizesAndDates(from: source, to: next, control: runner.control)
        for (i, rel) in readOnly.enumerated() {
            if i % 256 == 0, runner.control?.isCancelled == true { throw CancelledError() }
            try copyAttributes(from: source.appendingPathComponent(rel), to: next.appendingPathComponent(rel))
        }
        try matchAttributes(from: source, to: next, control: runner.control)
        restoreFolderModes(from: source, to: next)
        return leftOut
    }

    /// Whether an item of this type is left out of the mirror: a named pipe, a
    /// socket or a device. They are connections a running program makes (an editor,
    /// ssh, gpg, a build server) or device nodes, and hold no data, so a restore
    /// never needs them. openrsync can't copy them faithfully here: it can't make a
    /// socket at all ("mkstempsock: Invalid argument": the staging path is already
    /// past the 104 bytes a socket's path may have), and with -E it fails on a pipe
    /// carrying any attribute ("copyfile: Operation not supported"), which on a Mac
    /// in use is every pipe (provenance). Either failed every run of a mirror of a
    /// home or developer folder.
    static func isLeftOut(_ mode: mode_t) -> Bool {
        let type = mode & S_IFMT
        return type == S_IFIFO || type == S_IFSOCK || type == S_IFBLK || type == S_IFCHR
    }

    /// the library's read-only regular files and the items left out of the mirror,
    /// relative to it, in one walk
    static func survey(_ root: URL) -> (readOnly: [String], leftOut: [String]) {
        guard let walker = FileManager.default.enumerator(atPath: root.path) else { return ([], []) }
        var readOnly: [String] = [], leftOut: [String] = []
        while let rel = walker.nextObject() as? String {
            var st = stat()
            guard lstat(root.appendingPathComponent(rel).path, &st) == 0 else { continue }
            if isLeftOut(st.st_mode) { leftOut.append(rel); continue }
            if st.st_mode & S_IFMT == S_IFREG, st.st_mode & S_IWUSR == 0 { readOnly.append(rel) }
        }
        return (readOnly, leftOut)
    }

    /// items left out of the mirror, relative to `root`
    static func leftOut(in root: URL) -> [String] { survey(root).leftOut }

    /// take out of a copy any pipe, socket or device it holds: a copy made before they
    /// were left out (a pipe with no attributes did copy) or one rsync's delete passes
    /// over because it is excluded
    static func removeLeftOut(in copy: URL) {
        guard let walker = FileManager.default.enumerator(atPath: copy.path) else { return }
        while let rel = walker.nextObject() as? String {
            var st = stat()
            let path = copy.appendingPathComponent(rel).path
            guard lstat(path, &st) == 0, isLeftOut(st.st_mode), unlink(path) != 0, errno == EACCES || errno == EPERM else { continue }
            // a read-only folder, kept read-only by the clone: writable for the moment
            let parent = (path as NSString).deletingLastPathComponent
            var p = stat()
            guard lstat(parent, &p) == 0, chmod(parent, (p.st_mode & 0o7777) | S_IWUSR) == 0 else { continue }
            unlink(path)
            chmod(parent, p.st_mode & 0o7777)
        }
    }

    /// Give every file and folder of the copy the library's extended attributes and
    /// access list where rsync left them different.
    ///
    /// openrsync's -E sends a file's attributes as an AppleDouble ("._") file, and a
    /// file with no attributes at all has none to send. So when a file's last
    /// attribute or its access list is removed from the library (a Finder tag taken
    /// off, say), nothing tells the copy, and the copy kept it on every run after.
    /// It went unseen on this Mac only because macOS gives every file this session's
    /// processes write a provenance attribute, so every file had something to send;
    /// files written by other processes (older files, files from another Mac, the
    /// CI runners') have none. The read-back then failed every run.
    static func matchAttributes(from source: URL, to next: URL, control: RunControl?) throws {
        var rels = [""]
        if let walker = FileManager.default.enumerator(atPath: source.path) {
            while let rel = walker.nextObject() as? String { rels.append(rel) }
        }
        for (i, rel) in rels.enumerated() {
            if i % 512 == 0, control?.isCancelled == true { throw CancelledError() }
            let from = rel.isEmpty ? source : source.appendingPathComponent(rel)
            let to = rel.isEmpty ? next : next.appendingPathComponent(rel)
            var a = stat(), b = stat()
            guard lstat(from.path, &a) == 0, lstat(to.path, &b) == 0 else { continue }
            let type = a.st_mode & S_IFMT
            guard type == b.st_mode & S_IFMT, type == S_IFREG || type == S_IFDIR else { continue }
            if differentAttributes(from.path, to.path) != nil { try copyAttributes(from: from, to: to) }
        }
    }

    /// Give every file of the copy the library's size and date where rsync left them
    /// different.
    ///
    /// rsync -S writes a run of zeros as a hole: it skips over it instead of writing
    /// it. When the zeros run to the end of the file, skipping doesn't make the file
    /// any longer, so the copier has to extend it to its size once it's done. The
    /// openrsync of macOS 15 doesn't (CI's macOS 15 runner: every file of zeros, and
    /// every file ending in them, read back "has the wrong size or date", while files
    /// with holes inside and data at the end were fine; macOS 26's openrsync gets it
    /// right). So a mirror of any library holding such a file failed every run on
    /// macOS 15. Extending the file here makes its missing tail a hole, which reads
    /// back as the zeros it is, and the library's dates go back on.
    ///
    /// This can't pass a bad copy off as a good one. The copy starts as a clone of the
    /// previous one, and rsync only writes a file whose size or date differs from the
    /// library's; so a file fixed here differs from the previous copy in size or date,
    /// and the read-back compares its bytes with the library's (see `verify`).
    static func matchSizesAndDates(from source: URL, to next: URL, control: RunControl?) throws {
        guard let walker = FileManager.default.enumerator(atPath: source.path) else { return }
        var seen = 0
        while let rel = walker.nextObject() as? String {
            seen += 1
            if seen % 512 == 0, control?.isCancelled == true { throw CancelledError() }
            let to = next.appendingPathComponent(rel).path
            var a = stat(), b = stat()
            guard lstat(source.appendingPathComponent(rel).path, &a) == 0, a.st_mode & S_IFMT == S_IFREG,
                  lstat(to, &b) == 0, b.st_mode & S_IFMT == S_IFREG else { continue }
            if b.st_size < a.st_size {
                // read-only like its source: writable for the moment it takes
                chmod(to, (b.st_mode & 0o7777) | S_IWUSR)
                let extended = truncate(to, a.st_size)
                chmod(to, b.st_mode & 0o7777)
                guard extended == 0 else { continue }                 // the read-back names it
            } else if b.st_size != a.st_size
                        || (a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec) {
                continue
            }
            var times = [a.st_atimespec, a.st_mtimespec]
            _ = utimensat(AT_FDCWD, to, &times, AT_SYMLINK_NOFOLLOW)
        }
    }

    /// Put every folder's mode back as the library has it. A --files-from pass makes
    /// the folders on the way to each file it names writable so it can create the
    /// file there, and leaves them so: a read-only folder holding a read-only file
    /// came back 755 (plain rsync does the same: 555 after -aE, 755 after
    /// --files-from). --no-implied-dirs keeps the mode but then can't create the file.
    static func restoreFolderModes(from source: URL, to next: URL) {
        var rels = [""]
        if let walker = FileManager.default.enumerator(atPath: source.path) {
            while let rel = walker.nextObject() as? String {
                if walker.fileAttributes?[.type] as? FileAttributeType == .typeDirectory { rels.append(rel) }
            }
        }
        // deepest first, so a folder is made read-only only after everything in it is set
        for rel in rels.sorted(by: { $0.count > $1.count }) {
            let from = rel.isEmpty ? source.path : source.appendingPathComponent(rel).path
            let to = rel.isEmpty ? next.path : next.appendingPathComponent(rel).path
            var a = stat(), b = stat()
            guard lstat(from, &a) == 0, lstat(to, &b) == 0, a.st_mode & 0o7777 != b.st_mode & 0o7777 else { continue }
            chmod(to, a.st_mode & 0o7777)
        }
    }

    /// regular files under `root` their owner can't write, relative to it.
    static func readOnlyFiles(in root: URL) -> [String] { survey(root).readOnly }

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
    /// read-only like its source: made writable for the moment it takes. Attributes
    /// and an access list the source no longer has are taken off the copy.
    ///
    /// Writing a resource fork updates the file's modification date, so the library's
    /// dates go back on afterwards: without that the copy's date drifted (the read-back
    /// caught it), and rsync sent the file again on every run.
    static func copyAttributes(from src: URL, to dst: URL) throws {
        var st = stat(), times = stat()
        guard lstat(dst.path, &st) == 0, lstat(src.path, &times) == 0 else { return }
        chmod(dst.path, (st.st_mode & 0o7777) | S_IWUSR)
        defer {
            var ts = [times.st_atimespec, times.st_mtimespec]
            _ = utimensat(AT_FDCWD, dst.path, &ts, AT_SYMLINK_NOFOLLOW)
            chmod(dst.path, st.st_mode & 0o7777)
        }
        guard copyfile(src.path, dst.path, nil, copyfile_flags_t(COPYFILE_XATTR | COPYFILE_ACL)) == 0 else {
            throw ArchiveError.toolFailed(tool: "copyfile", status: errno,
                                          stderr: "\(src.lastPathComponent): couldn't copy its attributes (\(String(cString: strerror(errno))))")
        }
        if let names = attributeNames(src.path) {                    // unreadable: leave the copy's alone
            let kept = Set(names)
            for name in attributeNames(dst.path) ?? [] where !kept.contains(name) {
                _ = removexattr(dst.path, name, XATTR_NOFOLLOW)
            }
            // copyfile doesn't copy every attribute as it is. It re-stamps
            // com.apple.quarantine on every copy (measured: "0083;66f9a1b2;Safari;<id>"
            // arrives as "0283;<time of the copy>;;<id>"), so every downloaded file read
            // back different on every run. The library's own bytes, written as they
            // are, stay so through the image (measured across a detach and attach).
            for name in names {
                guard let value = attributeValue(src.path, name), attributeValue(dst.path, name) != value else { continue }
                guard setxattr(dst.path, name, value, value.count, 0, XATTR_NOFOLLOW) == 0 else {
                    throw ArchiveError.toolFailed(tool: "setxattr", status: errno,
                                                  stderr: "\(src.lastPathComponent): couldn't copy its \(name) attribute (\(String(cString: strerror(errno))))")
                }
            }
        }
        if accessList(src.path) == nil, accessList(dst.path) != nil { clearACL(dst.path) }
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
        // The paths have traded places: `current` now names the new copy. Its access
        // list goes back on; if it won't, the run says so rather than leave the top
        // folder without it unseen (the read-back was before this).
        if let nextACL, acl_set_file(current.path, ACL_TYPE_EXTENDED, nextACL) != 0 {
            throw MirrorCopyError.topFolderNotRestored("its access list couldn't be put back: \(String(cString: strerror(errno)))")
        }
    }

    private static func clearACL(_ path: String) {
        guard let empty = acl_init(0) else { return }
        acl_set_file(path, ACL_TYPE_EXTENDED, empty)
        acl_free(UnsafeMutableRawPointer(empty))
    }

    /// remove the previous copy. Deny-delete ACLs and read-only folders inside it are
    /// dealt with if the plain remove is refused. Whatever still won't go is left for
    /// the next run, which removes it before it starts (and fails if it can't).
    static func removeStaging(_ staging: URL, runner: CommandRunner) {
        let fm = FileManager.default
        try? fm.removeItem(at: staging)
        guard fm.fileExists(atPath: staging.path) else { return }
        // deny-delete ACLs, and read-only folders (whose modes the copy keeps), are
        // what stops a plain remove
        _ = try? runner.run("/bin/chmod", ["-R", "-N", staging.path], stdin: nil)
        _ = try? runner.run("/bin/chmod", ["-R", "u+w", staging.path], stdin: nil)
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
    /// an earlier run found the image damaged, and it still isn't sound
    case imageRecordedDamaged(image: String, why: String)
    /// the new copy, read back from the image, didn't match the library
    case readBackMismatch(count: Int, examples: [String])
    /// after the swap, the image didn't hold the new copy
    case updateNotConfirmed(count: Int, examples: [String])
    /// after the swap, the image couldn't be checked
    case couldNotConfirm(String)
    /// the new copy is in place, but its top folder's attributes or access list,
    /// written after the read-back, didn't come through
    case topFolderNotRestored(String)
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
        case .readBackMismatch(let count, let examples):
            let list = examples.joined(separator: "; ")
            return "the new copy of the mirror didn't read back the same as the library (\(count) item\(count == 1 ? "" : "s"): \(list)). Data was lost on its way to the drive, so it wasn't put in place: nothing was updated and the previous copy is intact. Run again; if this repeats, check the drive."
        case .imageRecordedDamaged(let image, let why):
            return "the mirror's disk image (\(image)) was found damaged after an earlier run whose drive filled (\(why)), and it still is. Its backup can't be trusted and may not open. To start this mirror afresh, move that image out of the way (keep it until the new mirror is complete) and run again."
        case .updateNotConfirmed(let count, let examples):
            return "the mirror's update didn't reach the drive intact: checked afterwards, its copy differs from the library (\(count) item\(count == 1 ? "" : "s"): \(examples.joined(separator: "; "))). The mirror's disk image checked out and holds a complete copy, most likely the previous one. Run again; if this repeats, check the drive."
        case .couldNotConfirm(let why):
            return "the mirror was updated, but its disk image couldn't be checked afterwards (\(why)), so this run doesn't count as a success. Run again."
        case .stagingStuck(let path):
            return "an unfinished copy a previous run left inside the mirror (\(path)) couldn't be removed, and it can't be trusted, so nothing was updated. The previous copy is intact; run again, and if this repeats, start this mirror afresh."
        case .topFolderNotRestored(let why):
            return "the mirror was updated, but its top folder didn't come through as the library has it (\(why)), so this run doesn't count. Everything inside it is in place; the next run puts it right."
        case .swapFailed(let why):
            return "couldn't put the updated copy in place (\(why)); the previous copy is untouched — run again"
        }
    }
}
