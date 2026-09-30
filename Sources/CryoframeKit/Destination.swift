//
//  Destination.swift
//  CryoframeKit
//
//  Where backups go, as something a person recognizes and the app can find again.
//
//  A destination used to be a path, a name the user typed and a kind the user had
//  to pick before choosing the folder ("Local folder", "Network or external
//  drive", "Cloud-sync folder"). A path breaks when a drive is renamed or mounts
//  as "T7 1", and it can't tell the drive it was set up with from another drive of
//  the same name. So a destination now also records the volume it is on (its UUID
//  and the folder's place within it), and its kind and friendly name are worked out
//  from the volume itself ("Backups on T7 Backup").
//

import Foundation

/// what kind of place a destination is, from the volume it's on
public enum DestinationKind: String, Codable, Sendable, Equatable {
    case internalDisk, externalDrive, network, cloud

    public var label: String {
        switch self {
        case .internalDisk: return "folder on this Mac"
        case .externalDrive: return "external drive"
        case .network: return "network share"
        case .cloud: return "cloud folder"
        }
    }
}

/// The volume a destination (or a source) is on, and the folder's place within it.
/// The UUID is what identifies the drive: renamed, or mounted somewhere else, it is
/// still this drive; another drive with the same name isn't.
public struct VolumeIdentity: Codable, Sendable, Equatable, Hashable {
    /// the volume's UUID; for a network share, its address (smb://host/share)
    public var uuid: String
    /// the volume's name when last seen, for messages
    public var name: String
    /// the folder within the volume ("" for the volume itself)
    public var relativePath: String
    /// a network share: found by address rather than by UUID
    public var isShare: Bool

    public init(uuid: String, name: String, relativePath: String, isShare: Bool = false) {
        self.uuid = uuid; self.name = name; self.relativePath = relativePath; self.isShare = isShare
    }
}

/// A mounted volume, as far as destinations care.
public struct MountedVolume: Sendable, Equatable {
    public var mountPoint: URL
    public var uuid: String?
    public var name: String
    public var isLocal: Bool
    public var isInternal: Bool
    public var isRemovable: Bool
    public var isEjectable: Bool
    public var isRoot: Bool
    /// a network volume's address
    public var remountURL: URL?

    public init(mountPoint: URL, uuid: String?, name: String, isLocal: Bool = true, isInternal: Bool = true,
                isRemovable: Bool = false, isEjectable: Bool = false, isRoot: Bool = false, remountURL: URL? = nil) {
        self.mountPoint = mountPoint; self.uuid = uuid; self.name = name; self.isLocal = isLocal
        self.isInternal = isInternal; self.isRemovable = isRemovable; self.isEjectable = isEjectable
        self.isRoot = isRoot; self.remountURL = remountURL
    }

    /// what the volume's own properties say it is (a cloud folder is told by its path)
    public var kind: DestinationKind {
        if !isLocal { return .network }
        if isRoot { return .internalDisk }
        return (!isInternal || isRemovable || isEjectable) ? .externalDrive : .internalDisk
    }

    /// how a share is identified: scheme, host and share, lowercased, no user
    var shareKey: String? {
        guard let u = remountURL, let host = u.host else { return nil }
        return "\(u.scheme ?? "smb")://\(host.lowercased())\(u.path.lowercased())"
    }
}

/// The volumes mounted on this Mac. Injectable, so the rules can be tested without
/// real drives.
public protocol VolumeTable: Sendable {
    func mounted() -> [MountedVolume]
    /// the volume holding `url` (which need not exist yet: its nearest existing
    /// ancestor is asked)
    func volume(containing url: URL) -> MountedVolume?
}

public extension VolumeTable {
    func volume(containing url: URL) -> MountedVolume? {
        // the innermost volume whose mount point holds the path
        let path = DestinationRules.canonical(url)
        return mounted()
            .map { (volume: $0, mount: DestinationRules.canonical($0.mountPoint)) }
            .filter { path == $0.mount || path.hasPrefix($0.mount == "/" ? "/" : $0.mount + "/") }
            .max { $0.mount.count < $1.mount.count }?.volume
    }
}

/// the real volumes, from the file system
public struct SystemVolumeTable: VolumeTable {
    public init() {}

    static let keys: [URLResourceKey] = [.volumeUUIDStringKey, .volumeNameKey, .volumeLocalizedNameKey, .volumeIsLocalKey,
                                         .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
                                         .volumeIsRootFileSystemKey, .volumeURLForRemountingKey]

    public func mounted() -> [MountedVolume] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Self.keys, options: []) ?? []
        var out = urls.compactMap(Self.describe)
        // the startup disk's Data volume, where the home folder is, isn't among them
        // (measured on macOS 26): "/" is the sealed system volume, another UUID
        let data = URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true)
        if !out.contains(where: { $0.mountPoint.path == data.path }), let d = Self.describe(data) { out.append(d) }
        return out
    }

    /// The volume from the kernel (statfs), not from the path's shape: the home
    /// folder is on the Data volume, mounted at /System/Volumes/Data and reached
    /// through "/" by a firmlink.
    public func volume(containing url: URL) -> MountedVolume? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" { probe.deleteLastPathComponent() }
        guard let v = VolumeInspector.volume(for: probe) else { return nil }
        return Self.describe(URL(fileURLWithPath: v.mountPoint, isDirectory: true))
    }

    static func describe(_ mount: URL) -> MountedVolume? {
        guard let v = try? mount.resourceValues(forKeys: Set(keys)) else { return nil }
        return MountedVolume(mountPoint: mount, uuid: v.volumeUUIDString,
                             name: v.volumeLocalizedName ?? v.volumeName ?? mount.lastPathComponent,
                             isLocal: v.volumeIsLocal ?? true, isInternal: v.volumeIsInternal ?? true,
                             isRemovable: v.volumeIsRemovable ?? false, isEjectable: v.volumeIsEjectable ?? false,
                             isRoot: v.volumeIsRootFileSystem ?? false || mount.path == "/System/Volumes/Data",
                             remountURL: v.volumeURLForRemounting)
    }
}

/// a fixed list of volumes, for tests
public struct FixedVolumeTable: VolumeTable {
    public let volumes: [MountedVolume]
    public init(_ volumes: [MountedVolume]) { self.volumes = volumes }
    public func mounted() -> [MountedVolume] { volumes }
}

// MARK: - where a destination is now

/// Where a destination is right now.
public enum DestinationPresence: Sendable, Equatable {
    /// connected, at this folder
    case present(URL)
    /// not connected (a drive that's unplugged, or away if it rotates), and why
    case away(String)
    /// a different drive of its name is connected, not the one it was set up with
    case otherDrive(String)

    public var url: URL? { if case .present(let u) = self { return u }; return nil }
    public var isPresent: Bool { url != nil }
}

public struct DestinationResolver: Sendable {
    let volumes: VolumeTable
    public init(volumes: VolumeTable = SystemVolumeTable()) { self.volumes = volumes }

    /// Where `target` is now. A destination that knows its volume is found by the
    /// volume's UUID (a share by its address), wherever it's mounted and whatever
    /// it's called today. One set up before 1.6 is found by its path.
    public func locate(_ target: Target) -> DestinationPresence {
        guard let id = target.volume else {
            let fm = FileManager.default
            let dir = target.destinationDir
            if fm.fileExists(atPath: dir.path) || fm.fileExists(atPath: dir.deletingLastPathComponent().path) { return .present(dir) }
            return .away("\(target.displayName) isn't connected")
        }
        // still where it was: the recorded path is on the recorded volume (the usual
        // case, and the only sane spelling for the startup disk, reached through
        // firmlinks)
        if let here = volumes.volume(containing: target.destinationDir),
           id.isShare ? here.shareKey == id.uuid.lowercased() : here.uuid == id.uuid {
            return .present(target.destinationDir)
        }
        let all = volumes.mounted()
        let match = id.isShare ? all.first { $0.shareKey == id.uuid.lowercased() } : all.first { $0.uuid == id.uuid }
        if let v = match {
            return .present(id.relativePath.isEmpty ? v.mountPoint : v.mountPoint.appendingPathComponent(id.relativePath, isDirectory: true))
        }
        if !id.isShare, all.contains(where: { LibraryNames.same($0.name, id.name) }) {
            return .otherDrive("a different drive named “\(id.name)” is connected, not the one \(target.displayName) was set up on")
        }
        return .away("\(id.name) isn't connected")
    }

    /// `job` with each connected destination's folder where it is now, and where
    /// each destination is, by target id
    public func resolve(_ job: BackupJob) -> (job: BackupJob, presence: [String: DestinationPresence]) {
        var presence: [String: DestinationPresence] = [:]
        var copy = job
        copy.targets = job.targets.map { t in
            let p = locate(t)
            presence[t.id] = p
            guard let url = p.url, url != t.destinationDir else { return t }
            return t.at(url)
        }
        return (copy, presence)
    }

    /// The identity to record for a folder chosen as a destination: its volume and its
    /// place within it (nil for the startup disk's own volume's folders is not a
    /// special case: they're recorded too, and never go away).
    public func identity(for folder: URL) -> VolumeIdentity? {
        guard let v = volumes.volume(containing: folder) else { return nil }
        let rel = DestinationRules.relative(folder, to: v.mountPoint)
        if !v.isLocal, let key = v.shareKey { return VolumeIdentity(uuid: key, name: v.name, relativePath: rel, isShare: true) }
        guard let uuid = v.uuid else { return nil }
        return VolumeIdentity(uuid: uuid, name: v.name, relativePath: rel)
    }

    /// what kind of place `folder` is: a cloud provider's folder by its path, else by
    /// the volume it's on
    public func kind(of folder: URL, home: String = NSHomeDirectory()) -> DestinationKind {
        if DestinationRules.isCloudFolder(folder, home: home) { return .cloud }
        return volumes.volume(containing: folder)?.kind ?? .internalDisk
    }

    /// "Backups on T7 Backup", "Backups on this Mac", "Backups in iCloud Drive", "T7
    /// Backup" (the drive itself)
    public func friendlyName(for folder: URL, home: String = NSHomeDirectory()) -> String {
        let name = folder.lastPathComponent
        if DestinationRules.isCloudFolder(folder, home: home) {
            let provider = CloudProvider.identify(folder).displayName
            return DestinationRules.isCloudRoot(folder, home: home) ? provider : "\(name) in \(provider)"
        }
        guard let v = volumes.volume(containing: folder) else { return name }
        let atRoot = DestinationRules.canonical(folder) == DestinationRules.canonical(v.mountPoint)
        switch v.kind {
        case .internalDisk: return atRoot ? "this Mac's startup disk" : "\(name) on this Mac"
        case .externalDrive: return atRoot ? v.name : "\(name) on \(v.name)"
        case .network:
            let share = v.remountURL.map { u in u.host.map { "\(u.lastPathComponent) (\($0))" } ?? u.lastPathComponent } ?? v.name
            return atRoot ? share : "\(name) on \(share)"
        case .cloud: return name
        }
    }

    /// A destination for `folder`: its kind, friendly name and identity worked out from
    /// the folder itself, so nobody has to say what kind of place it is first.
    /// `cloudCap`: a single-file limit to use in place of the cloud provider's own.
    public func target(for folder: URL, id: String? = nil, cloudCap: UInt64? = nil, home: String = NSHomeDirectory()) -> Target {
        let name = friendlyName(for: folder, home: home)
        let id = id ?? folder.path
        var t: Target
        switch kind(of: folder, home: home) {
        case .internalDisk: t = .localVolume(id: id, name: name, dir: folder)
        case .externalDrive: t = .externalDrive(id: id, name: name, dir: folder)
        case .cloud: t = .cloudSyncFolder(id: id, name: name, dir: folder, provider: CloudProvider.identify(folder), maxFileBytes: cloudCap)
        case .network:
            let mount = volumes.volume(containing: folder)
            t = .networkShare(id: id, name: name, dir: folder,
                              mount: NetworkMountSpec(url: mount?.remountURL ?? folder, mountpoint: mount?.mountPoint.path ?? folder.path))
        }
        t.volume = identity(for: folder)
        return t
    }
}

// MARK: - checking a folder before it becomes a destination or a source

/// What's wrong, or worth knowing, about a folder chosen as a destination or source.
public struct PlaceIssue: Sendable, Equatable {
    public enum Severity: Sendable, Equatable { case refusal, warning }
    public var severity: Severity
    public var message: String
    public init(_ severity: Severity, _ message: String) { self.severity = severity; self.message = message }
}

public enum DestinationRules {
    /// Check `folder` as a destination for backups of `sources` (the job's library
    /// folders). Refused: not a folder; the source or inside it, or holding it; not
    /// writable; a system location; inside a Cryoframe backup. Warned: on the same
    /// disk as a source.
    public static func check(_ folder: URL, sources: [URL], volumes: VolumeTable = SystemVolumeTable(),
                             home: String = NSHomeDirectory(), systemRoots: [String] = DestinationRules.systemRoots) -> [PlaceIssue] {
        var out: [PlaceIssue] = []
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDir) else {
            return [PlaceIssue(.refusal, "\(folder.lastPathComponent) doesn't exist, or can't be reached")]
        }
        guard isDir.boolValue, !isPackage(folder) else {
            return [PlaceIssue(.refusal, "\(folder.lastPathComponent) is a file, not a folder. Choose the folder the backups should go in.")]
        }
        for s in sources {
            if contains(s, folder) {
                out.append(PlaceIssue(.refusal, samePath(s, folder)
                    ? "\(folder.lastPathComponent) is the folder being backed up. Backups have to go somewhere else."
                    : "\(folder.lastPathComponent) is inside \(s.lastPathComponent), which is being backed up: each backup would copy the ones before it."))
            } else if contains(folder, s) {
                out.append(PlaceIssue(.refusal, "\(s.lastPathComponent), which is being backed up, is inside \(folder.lastPathComponent): choose a folder outside it."))
            }
        }
        if let why = systemLocation(folder, home: home, roots: systemRoots) { out.append(PlaceIssue(.refusal, why)) }
        if let inside = insideBackup(folder) {
            out.append(PlaceIssue(.refusal, "\(folder.lastPathComponent) is inside a Cryoframe backup (\(inside.lastPathComponent)). Choose the folder that holds your backups, or another one."))
        }
        if access(folder.path, W_OK) != 0 {
            out.append(PlaceIssue(.refusal, "Cryoframe can't write to \(folder.lastPathComponent). Choose a folder you can write to, or change its permissions in Finder's Get Info."))
        }
        if out.isEmpty {
            let dest = volumes.volume(containing: folder)
            let shared = sources.filter { s in
                guard let dest, let v = volumes.volume(containing: s) else { return false }
                if let a = dest.uuid, let b = v.uuid { return a == b }
                return canonical(dest.mountPoint) == canonical(v.mountPoint)
            }
            if let s = shared.first, let d = dest {
                out.append(PlaceIssue(.warning, "\(folder.lastPathComponent) is on the same disk as \(s.lastPathComponent) (\(d.name)). If that disk fails, the backup goes with it; a backup on another drive is safer."))
            }
        }
        return out
    }

    /// What a run will make in `folder` for `job`: one folder per library, found again
    /// by its identity if it already exists.
    public static func preview(_ folder: URL, job: BackupJob) -> [String] {
        var planned: [String] = []          // names the libraries before this one will take
        return job.libraries.map { lib in
            if let existing = LibraryFolders.folder(job: job, library: lib, in: folder) {
                return "\(lib.displayName): keeps using \(existing.path)"
            }
            var name = LibraryFolderName.choose(job: job, library: lib, in: folder)
            if planned.contains(where: { LibraryNames.same($0, name) }) { name = LibraryFolderName.make(job: job, library: lib) }
            planned.append(name)
            let what = job.format.isSealed ? "a dated folder for each backup inside it" : "a disk image holding the copy"
            return "\(lib.displayName): creates \(folder.appendingPathComponent(name).path), with \(what)"
        }
    }

    // MARK: rules shared with sources

    /// folders macOS keeps for itself (temporary folders among them: macOS empties them)
    public static let systemRoots = ["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/private",
                                     "/var", "/tmp", "/etc", "/cores", "/dev", "/opt"]

    /// Places macOS keeps for itself, and the folder that holds mounted drives.
    static func systemLocation(_ folder: URL, home: String, roots: [String] = systemRoots) -> String? {
        let p = canonical(folder)
        let h = canonical(URL(fileURLWithPath: home))
        if p == "/" { return "The top of the startup disk is reserved for macOS. Choose a folder inside it, or another drive." }
        if p == "/Volumes" { return "This is the folder that holds your drives. Choose a drive, or a folder on one." }
        for root in roots where p == root || p.hasPrefix(root + "/") {
            return "\(folder.lastPathComponent) is a folder macOS keeps for itself (\(root)). Choose one of your own folders, or a drive."
        }
        for mine in ["Library", ".Trash"] where p == h + "/" + mine || p.hasPrefix(h + "/" + mine + "/") {
            if mine == "Library", isCloudFolder(folder, home: home) { continue }     // cloud folders live in ~/Library
            return "\(folder.lastPathComponent) is inside your \(mine == "Library" ? "Library" : "Trash") folder, which macOS and apps manage. Choose another folder."
        }
        return nil
    }

    /// the Cryoframe backup `url` is in (or is), if any: a library folder (it has an
    /// identity file), an archive folder (it has a manifest), a disk image
    static func insideBackup(_ url: URL) -> URL? {
        let fm = FileManager.default
        var dir = url
        for _ in 0..<64 {
            if fm.fileExists(atPath: dir.appendingPathComponent(LibraryIdentity.fileName).path)
                || fm.fileExists(atPath: dir.appendingPathComponent(ArchiveManifest.sidecarName).path)
                || ["sparsebundle", "dmg"].contains(dir.pathExtension.lowercased()) { return dir }
            let up = dir.deletingLastPathComponent()
            if up.path == dir.path { break }
            dir = up
        }
        return nil
    }

    static func isCloudFolder(_ url: URL, home: String) -> Bool {
        let p = canonical(url), h = canonical(URL(fileURLWithPath: home))
        return p.hasPrefix(h + "/Library/CloudStorage/") || p.hasPrefix(h + "/Library/Mobile Documents/")
    }

    static func isCloudRoot(_ url: URL, home: String) -> Bool {
        let p = canonical(url), h = canonical(URL(fileURLWithPath: home))
        let rel = p.hasPrefix(h + "/Library/CloudStorage/") ? String(p.dropFirst((h + "/Library/CloudStorage/").count))
            : p.hasPrefix(h + "/Library/Mobile Documents/") ? String(p.dropFirst((h + "/Library/Mobile Documents/").count)) : "x/x"
        return !rel.contains("/")
    }

    static func isPackage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
    }

    /// `inner` is `outer` or inside it
    static func contains(_ outer: URL, _ inner: URL) -> Bool {
        let o = canonical(outer), i = canonical(inner)
        return i == o || i.hasPrefix(o == "/" ? "/" : o + "/")
    }

    static func samePath(_ a: URL, _ b: URL) -> Bool { canonical(a) == canonical(b) }

    /// one spelling of a path: symlinks resolved, /private/var and /var the same, no
    /// trailing slash. Resolved through the nearest existing ancestor, because
    /// resolving a path that doesn't exist yet leaves its symlinks in place.
    static func canonical(_ url: URL) -> String {
        var tail: [String] = []
        var probe = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" {
            tail.insert(probe.lastPathComponent, at: 0); probe.deleteLastPathComponent()
        }
        var p = TMUtilSnapshotBackend.canonicalPath(probe.resolvingSymlinksInPath().path)
        for t in tail { p = (p == "/" ? "" : p) + "/" + t }
        if p.count > 1, p.hasSuffix("/") { p.removeLast() }
        // the startup disk's Data volume is reached through "/" by firmlinks, and
        // resolving a path under it drops the prefix: fold it the same way here
        let data = "/System/Volumes/Data"
        if p == data { return "/" }
        if p.hasPrefix(data + "/") { p.removeFirst(data.count) }
        return p
    }

    /// `folder`'s path within the volume mounted at `mount` ("" for the volume itself)
    static func relative(_ folder: URL, to mount: URL) -> String {
        let f = canonical(folder), m = canonical(mount)
        if f == m { return "" }
        let base = m == "/" ? "/" : m + "/"
        // the Data volume: a home folder path is reached through "/" by a firmlink
        if f.hasPrefix(base) { return String(f.dropFirst(base.count)) }
        if m == "/System/Volumes/Data" { return String(f.drop(while: { $0 == "/" })) }
        return String(f.drop(while: { $0 == "/" }))
    }
}
