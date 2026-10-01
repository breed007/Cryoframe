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
//  It also finds what neither sealed format can hold (named pipes, sockets, devices).
//  Those don't fail the run: a sealed build of such a folder reads a copy of it
//  without them (see FilteredCopy), and the run says what was left out.
//

import Foundation

public struct DMGBlockers: Sendable, Equatable {
    /// `special`: a named pipe, a socket or a device, which neither sealed format can
    /// hold. Measured: `hdiutil create -srcfolder` and `ditto -c -k` both open a named
    /// pipe and wait for a writer forever, and both refuse a socket ("Operation not
    /// supported on socket"). Devices can't be made without root to measure; neither
    /// tool can recreate one as the user. These are left out of a sealed build (see
    /// FilteredCopy), not refused; the other kinds refuse it.
    public enum Kind: Sendable, CaseIterable { case unreadable, foreign, setgid, special }

    /// how many examples of each kind are kept to name
    public static let examplesKept = 5

    public private(set) var counts: [Kind: Int] = [:]
    public private(set) var examples: [Kind: [String]] = [:]

    public init() {}

    public var isEmpty: Bool { counts.isEmpty }
    public var total: Int { counts.values.reduce(0, +) }

    /// what stops a sealed build: everything but the items it leaves out
    public var refusing: DMGBlockers {
        var out = self
        out.counts[.special] = nil; out.examples[.special] = nil
        return out
    }

    mutating func note(_ kind: Kind, _ rel: String) {
        counts[kind, default: 0] += 1
        if examples[kind, default: []].count < Self.examplesKept { examples[kind, default: []].append(rel) }
    }

    /// Look at one item of the library. A symbolic link is copied as a link, so only
    /// its owner matters; a folder must be listable as well as readable. `forDMG`
    /// adds what makes hdiutil ask for a password to what neither sealed format can
    /// hold (`special`).
    mutating func inspect(_ path: String, relative rel: String, groups: inout Membership,
                          uid: uid_t = geteuid(), forDMG: Bool = true) {
        var st = stat()
        guard lstat(path, &st) == 0 else { if forDMG { note(.unreadable, rel) }; return }
        let type = st.st_mode & S_IFMT
        if type == S_IFIFO || type == S_IFSOCK || type == S_IFBLK || type == S_IFCHR { note(.special, rel); return }
        guard forDMG else { return }
        if st.st_uid != uid { note(.foreign, rel); return }
        switch type {
        case S_IFREG:
            if access(path, R_OK) != 0 { note(.unreadable, rel); return }
            if st.st_mode & S_ISGID != 0, !groups.contains(st.st_gid) { note(.setgid, rel) }
        case S_IFDIR:
            if access(path, R_OK | X_OK) != 0 { note(.unreadable, rel) }
        default:
            break
        }
    }

    static func relative(_ path: String, to root: String) -> String {
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        guard p.hasPrefix(root + "/") else { return (path as NSString).lastPathComponent }
        return String(p.dropFirst(root.count + 1))
    }

    /// Whether the user is in a group. getgrouplist(3) asks directory services, so
    /// it answers for groups getgroups(2) leaves out; asked once per walk.
    struct Membership {
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
        let found = [list(.unreadable, "item you can't read", "items you can't read"),
                     list(.foreign, "item owned by another user", "items owned by another user"),
                     list(.setgid, "file set to run as a group you're not in", "files set to run as a group you're not in")]
            .compactMap { $0 }
        if !found.isEmpty {
            said.append("\(library) can't be sealed into a disk image unattended: the disk image tool would stop and wait for an administrator's password because of "
                        + found.joined(separator: ", and ") + ".")
        }
        var fix = "Nothing was backed up."
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
