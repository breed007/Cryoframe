//
//  DMGSourceCheck.swift
//  CryoframeKit
//
//  What in a library would stop a sealed DMG's build to ask for a password.
//
//  `hdiutil create -srcfolder` keeps the owners and modes it copies, and "prompts for
//  authentication if it detects an unreadable file, a file owned by someone other than
//  the user creating the image, or a SGID file in a group that the copying user is not
//  in" (hdiutil(1)). A scheduled run has nobody to answer that prompt, so it waited
//  on it all night, with its snapshot held. The run's walk of the library for its size
//  looks for all three, and the run fails up front naming them.
//
//  And it looks for access lists hdiutil can't build past: an entry denying this user
//  the right to delete a file, or to read an item's attributes or its access list,
//  makes `create -srcfolder` fail outright ("could not access <file> - Permission
//  denied"), whether the library is read live or from a read-only snapshot. Those
//  fail the run up front too, naming the items, and the sealed zip format archives
//  them.
//
//  It also finds what neither sealed format can hold (named pipes, sockets, devices).
//  Those don't fail the run: a sealed build of such a folder reads a copy of it
//  without them (see FilteredCopy), and the run says what was left out.
//
//  And it finds locked items (Finder's Locked, the uchg and uappnd flags). A zip
//  can't keep the lock, and macOS 15's disk image tool can't build from a folder
//  holding one at all ("could not access <file> - Operation not permitted", direct
//  builds included). Neither fails the run: a disk image built where the tool can't
//  take them reads an unlocked copy (see SealedReadPlan), and the run says which
//  items lost their lock.
//

import Foundation

public struct DMGBlockers: Sendable, Equatable {
    /// `special`: a named pipe, a socket or a device, which neither sealed format can
    /// hold. Measured: `hdiutil create -srcfolder` and `ditto -c -k` both open a named
    /// pipe and wait for a writer forever, and both refuse a socket ("Operation not
    /// supported on socket"). Devices can't be made without root to measure; neither
    /// tool can recreate one as the user. These are left out of a sealed build (see
    /// FilteredCopy), not refused; the other kinds refuse it. `accessList`: an access
    /// list hdiutil fails on (see `accessListStopsDiskImage`). `locked`: an item
    /// carrying a lock (see MirrorCopy.lockingFlags), which a zip drops and macOS 15's
    /// disk image tool can't build from; it never refuses a build.
    public enum Kind: Sendable, CaseIterable { case unreadable, foreign, setgid, special, accessList, locked }

    /// how many examples of each kind are kept to name
    public static let examplesKept = 5

    public private(set) var counts: [Kind: Int] = [:]
    public private(set) var examples: [Kind: [String]] = [:]
    /// how many of the `locked` items are append-only (uappnd), which no macOS's disk
    /// image tool builds from (see SealedReadPlan)
    public private(set) var appendOnly = 0

    public init() {}

    public var isEmpty: Bool { counts.isEmpty }
    public var total: Int { counts.values.reduce(0, +) }

    /// what stops a sealed build: everything but the items it leaves out and the
    /// locks it can't keep
    public var refusing: DMGBlockers {
        var out = self
        for kind in [Kind.special, .locked] { out.counts[kind] = nil; out.examples[kind] = nil }
        out.appendOnly = 0
        return out
    }

    /// how many of `kind` were found
    public func count(_ kind: Kind) -> Int { counts[kind] ?? 0 }

    mutating func note(_ kind: Kind, _ rel: String) {
        counts[kind, default: 0] += 1
        if examples[kind, default: []].count < Self.examplesKept { examples[kind, default: []].append(rel) }
    }

    /// Look at one item of the library. A symbolic link is copied as a link, so only
    /// its owner matters; a folder must be listable as well as readable. `forDMG`
    /// adds what makes hdiutil ask for a password to what neither sealed format can
    /// hold (`special`). `locks`: note locked items too (a sealed walk's).
    mutating func inspect(_ path: String, relative rel: String, groups: inout Membership,
                          uid: uid_t = geteuid(), forDMG: Bool = true, locks: Bool = false) {
        var st = stat()
        guard lstat(path, &st) == 0 else { if forDMG { note(.unreadable, rel) }; return }
        let type = st.st_mode & S_IFMT
        if type == S_IFIFO || type == S_IFSOCK || type == S_IFBLK || type == S_IFCHR { note(.special, rel); return }
        if locks, st.st_flags & MirrorCopy.lockingFlags != 0 {
            note(.locked, rel)
            if st.st_flags & UInt32(UF_APPEND) != 0 { appendOnly += 1 }
        }
        guard forDMG else { return }
        if st.st_uid != uid { note(.foreign, rel); return }
        switch type {
        case S_IFREG:
            if access(path, R_OK) != 0 { note(.unreadable, rel); return }
            if st.st_mode & S_ISGID != 0, !groups.contains(st.st_gid) { note(.setgid, rel); return }
        case S_IFDIR:
            if access(path, R_OK | X_OK) != 0 { note(.unreadable, rel); return }
        default:
            break
        }
        if Self.accessListStopsDiskImage(path, isFolder: type == S_IFDIR, uid: uid) { note(.accessList, rel) }
    }

    /// Whether the item's access list makes `hdiutil create -srcfolder` fail. Measured
    /// on macOS 27 (2026-10-01), each entry alone, denying the user building the image:
    ///   - a file (or a link): delete, read attributes, read extended attributes, or
    ///     read security (the access list itself) all fail it;
    ///   - a folder: read attributes, read extended attributes and read security fail
    ///     it; delete and delete-child don't (every home folder denies delete);
    ///   - an entry for another user, an "allow" entry, or one that is only inherited
    ///     by items made later doesn't.
    /// The same file on a read-only volume (as a snapshot is) fails the same way, so
    /// this reads the entries rather than asking the kernel, which answers "read-only
    /// file system" there.
    static func accessListStopsDiskImage(_ path: String, isFolder: Bool, uid: uid_t = geteuid()) -> Bool {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return errno == EACCES }   // can't read it: denied
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        let stopping: [acl_perm_t] = isFolder ? [ACL_READ_ATTRIBUTES, ACL_READ_EXTATTRIBUTES, ACL_READ_SECURITY]
                                              : [ACL_DELETE, ACL_READ_ATTRIBUTES, ACL_READ_EXTATTRIBUTES, ACL_READ_SECURITY]
        var entry: acl_entry_t?
        var which = ACL_FIRST_ENTRY.rawValue
        while acl_get_entry(acl, which, &entry) == 0, let e = entry {
            which = ACL_NEXT_ENTRY.rawValue
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(e, &tag) == 0, tag == ACL_EXTENDED_DENY else { continue }
            var flags: acl_flagset_t?
            if acl_get_flagset_np(UnsafeMutableRawPointer(e), &flags) == 0, let flags,
               acl_get_flag_np(flags, ACL_ENTRY_ONLY_INHERIT) == 1 { continue }
            var perms: acl_permset_t?
            guard acl_get_permset(e, &perms) == 0, let perms, stopping.contains(where: { acl_get_perm_np(perms, $0) == 1 }),
                  let qualifier = acl_get_qualifier(e) else { continue }
            defer { acl_free(qualifier) }
            if Membership.applies(qualifier.assumingMemoryBound(to: UInt8.self), to: uid) { return true }
        }
        return false
    }

    static func relative(_ path: String, to root: String) -> String {
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        guard p.hasPrefix(root + "/") else { return (path as NSString).lastPathComponent }
        return String(p.dropFirst(root.count + 1))
    }

    /// Whether the user is in a group. getgrouplist(3) asks directory services, so
    /// it answers for groups getgroups(2) leaves out; asked once per walk.
    struct Membership {
        /// Whether an access list entry's qualifier (a user's or a group's UUID, 16
        /// bytes) names `uid` or a group it is in ("everyone" included). The
        /// membership calls aren't visible to Swift, so they are looked up by name;
        /// if they can't be, an entry is taken to apply, which only ever refuses.
        static func applies(_ qualifier: UnsafePointer<UInt8>, to uid: uid_t) -> Bool {
            guard let calls = Self.calls else { return true }
            var me = [UInt8](repeating: 0, count: 16)
            guard calls.uidToUUID(uid, &me) == 0 else { return true }
            if me.withUnsafeBufferPointer({ memcmp($0.baseAddress!, qualifier, 16) == 0 }) { return true }
            var member: Int32 = 0
            guard me.withUnsafeBufferPointer({ calls.check($0.baseAddress!, qualifier, &member) }) == 0 else { return false }
            return member != 0
        }

        private typealias UIDToUUID = @convention(c) (uid_t, UnsafeMutablePointer<UInt8>) -> Int32
        private typealias CheckMembership = @convention(c) (UnsafePointer<UInt8>, UnsafePointer<UInt8>, UnsafeMutablePointer<Int32>) -> Int32
        private static let calls: (uidToUUID: UIDToUUID, check: CheckMembership)? = {
            let handle = dlopen(nil, RTLD_NOW)
            guard let u = dlsym(handle, "mbr_uid_to_uuid"), let c = dlsym(handle, "mbr_check_membership") else { return nil }
            return (unsafeBitCast(u, to: UIDToUUID.self), unsafeBitCast(c, to: CheckMembership.self))
        }()

        private var known: [gid_t: Bool]
        private var groups: Set<gid_t>?
        init(known: [gid_t: Bool] = [:]) { self.known = known }
        mutating func contains(_ gid: gid_t) -> Bool {
            if let k = known[gid] { return k }
            if groups == nil { groups = Self.userGroups() }
            let isIn = getegid() == gid || groups?.contains(gid) == true
            known[gid] = isIn
            return isIn
        }
        private static func userGroups() -> Set<gid_t> {
            guard let pw = getpwuid(geteuid()) else { return [] }
            var n: Int32 = 64
            var list = [Int32](repeating: 0, count: Int(n))
            while getgrouplist(pw.pointee.pw_name, Int32(bitPattern: pw.pointee.pw_gid), &list, &n) == -1, n < 4096 {
                n *= 2; list = [Int32](repeating: 0, count: Int(n))
            }
            return Set(list.prefix(Int(max(n, 0))).map { gid_t(bitPattern: $0) })
        }
    }

    /// What a live mirror run says about the named pipes, sockets and devices it
    /// left out (MirrorCopy.isLeftOut), or nil if there were none. Not a failure:
    /// they hold no data.
    public func leftOutOfMirror(library: String) -> String? { leftOut(library: library, of: "the mirror") }

    /// The same for a sealed run, which builds from a copy without them (see
    /// FilteredCopy).
    public func leftOutOfSealed(library: String, zip: Bool) -> String? {
        leftOut(library: library, of: zip ? "the zip" : "the disk image")
    }

    /// What a sealed run says about the locked items whose lock the archive doesn't
    /// keep, or nil if there were none: a zip never keeps one, and a disk image built
    /// from an unlocked copy (see SealedReadPlan) doesn't. Not a failure: what they
    /// hold is all there.
    public func unlockedInSealed(library: String, zip: Bool) -> String? {
        guard let n = counts[.locked], n > 0 else { return nil }
        let shown = examples[.locked] ?? []
        let why = zip ? "A zip can't keep an item's lock."
                      : appendOnly > 0
                      ? "macOS's disk image tool can't build from append-only items, so the disk image was built from a copy with the locks taken off."
                      : "macOS's disk image tool on this Mac can't build from locked items, so the disk image was built from a copy with the locks taken off."
        return "\(library): left the lock off \(n) locked item\(n == 1 ? "" : "s") in \(zip ? "the zip" : "the disk image") (\(shown.joined(separator: ", "))\(n > shown.count ? ", …" : "")). \(why) What they hold is all there; lock them again after a restore if you need to."
    }

    private func leftOut(library: String, of what: String) -> String? {
        guard let n = counts[.special], n > 0 else { return nil }
        let shown = examples[.special] ?? []
        return "\(library): left \(n) named pipe\(n == 1 ? "" : "s"), socket\(n == 1 ? "" : "s") or device\(n == 1 ? "" : "s") out of \(what) (\(shown.joined(separator: ", "))\(n > shown.count ? ", …" : "")). These are connections a running program makes and hold no data; a restore doesn't need them."
    }

    /// What the run reports when a sealed disk image can't be built unattended:
    /// which items, and what to do about them. Named pipes, sockets and devices
    /// aren't among them: a sealed build leaves them out (see `leftOutOfSealed`).
    /// A sealed zip is stopped by none of these.
    public func explanation(library: String) -> String {
        func list(_ kind: Kind, _ one: String, _ many: String) -> String? {
            guard let n = counts[kind], n > 0 else { return nil }
            let shown = examples[kind] ?? []
            return "\(n) \(n == 1 ? one : many) (\(shown.joined(separator: ", "))\(n > shown.count ? ", …" : ""))"
        }
        var said: [String] = []
        let refused = list(.accessList, "item whose access list it can't copy", "items whose access lists it can't copy")
        let found = [list(.unreadable, "item you can't read", "items you can't read"),
                     list(.foreign, "item owned by another user", "items owned by another user"),
                     list(.setgid, "file set to run as a group you're not in", "files set to run as a group you're not in")]
            .compactMap { $0 }
        if !found.isEmpty {
            said.append("\(library) can't be sealed into a disk image unattended: the disk image tool would stop and wait for an administrator's password because of "
                        + found.joined(separator: ", and ") + ".")
        }
        if let refused {
            said.append("\(library) can't be sealed into a disk image: the disk image tool fails on \(refused): an entry in it denies you deleting the item or reading its details.")
        }
        var fix = "Nothing was backed up."
        if refused != nil {
            fix += " Remove those entries (in Terminal, chmod -N on each item takes its access list off), or switch this job to the sealed zip format, which archives them."
        }
        if !found.isEmpty {
            fix += " Make these items yours and readable (in Finder, Get Info, then Sharing & Permissions), or move them out of the folder"
            if counts[.foreign] != nil || counts[.setgid] != nil {
                fix += (counts[.unreadable] == nil ? ", or switch this job to the sealed zip format, which archives them without asking."
                                                   : "; the sealed zip format archives items owned by others, but not ones you can't read.")
            } else {
                fix += "."
            }
        }
        return said.joined(separator: " ") + " " + fix
    }
}
