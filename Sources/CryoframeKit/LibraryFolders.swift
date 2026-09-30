//
//  LibraryFolders.swift
//  CryoframeKit
//
//  Finding, and on a run preparing, a library's folder at a destination (see
//  LibraryFolder.swift for what a library folder is).
//
//  A folder 1.5 wrote (`<destination>/<library name>/`, no identity file) is taken
//  over in place by the first 1.6 run that writes there: the identity file is added
//  and nothing moves. That is one small file written atomically, so a run that dies
//  half way leaves the folder as it was or taken over, and a return to 1.5.6 finds
//  its folder where it left it. A folder is taken over only by the one library it
//  can belong to: every job writing to the destination is asked which libraries
//  carry its name (and, if it holds an archive, the archive's bundle name). One
//  job's mirror and another job's sealed versions shared such a folder; the mirror
//  job takes it over, and the sealed versions move, one version folder at a time,
//  into their own job's folder. What can't be told apart is left where it is, still
//  found by Restore and the recovery wizard, and never written to or pruned again.
//

import Foundation

public enum LibraryFolders {
    /// What a run writes to, and anything worth saying about how it was found.
    public struct Prepared: Sendable, Equatable {
        public var folder: URL
        /// said in the run's warning
        public var notes: [String]
    }

    /// The folders at `destination` holding `library`'s backups for `job`, the one it
    /// writes to first (if there is one yet), then any other folder of its name holding
    /// archives of its (see `holdings`). For reading: drills, checks, retention's view
    /// of what exists, storage.
    public static func folders(job: BackupJob, library: ContentType, in destination: URL) -> [URL] {
        holdings(job: job, library: library, in: destination).map(\.folder)
    }

    /// every archive of `library` for `job` at `destination`, in all its folders, newest
    /// first; of two without a version (mirrors), the one in its own folder first. So
    /// the first is what a latest-only check looks at.
    public static func archives(job: BackupJob, library: ContentType, in destination: URL) -> [RestorableArchive] {
        holdings(job: job, library: library, in: destination).flatMap(\.archives).enumerated()
            .sorted { a, b in
                let (x, y) = (a.element.version ?? .distantPast, b.element.version ?? .distantPast)
                return x != y ? x > y : a.offset < b.offset
            }.map(\.element)
    }

    /// The folders holding `library`'s archives for `job`, and those archives.
    ///
    /// A job's archives are of its own kind: a mirror job's, the mirror at its folder's
    /// top; a sealed job's, its versions. A 1.5 folder a mirror job and a sealed job
    /// shared holds both until the versions have moved out, and the mirror job took
    /// the versions for its own: a latest-only check picked the newest of them and
    /// never looked at the mirror, and passed.
    ///
    /// Its own folders come first, whole. Then the folders of its name (where 1.5 and
    /// 1.5.6 write it) that aren't its own: a 1.5 folder, or another job's folder that
    /// 1.5.6 wrote into after a return to it. From those only archives whose bundle
    /// is this library's are read, as a run tells whose they are before taking a
    /// folder over (a custom folder "Photos" isn't the Photos library). A folder of
    /// another library of this same job is never read: 1.5.6 doesn't run a job with
    /// two libraries of one name. A 1.5 folder holding nothing is listed too.
    static func holdings(job: BackupJob, library: ContentType, in destination: URL) -> [(folder: URL, archives: [RestorableArchive])] {
        let key = LibraryIdentity.key(job: job, library: library)
        let mirror = !job.format.isSealed
        func ofItsKind(_ a: RestorableArchive) -> Bool { mirror ? a.format == .liveMirror && a.version == nil : a.format != .liveMirror }
        let roots = rootNames(of: library)
        let entries = listing(destination)
        var out: [(folder: URL, archives: [RestorableArchive])] = entries.filter { $0.identity?.key == key }
            .sorted { rank($0.url.lastPathComponent, library: library, key: key) < rank($1.url.lastPathComponent, library: library, key: key) }
            .map { ($0.url, RestoreDiscovery.scan($0.url, maxDepth: 1).filter(ofItsKind)) }
        for e in entries where e.identity?.key != key && e.identity?.jobID != job.id
            && LibraryNames.same(e.url.lastPathComponent, library.displayName) {
            let found = RestoreDiscovery.scan(e.url, maxDepth: 1)
            let mine = found.filter { ofItsKind($0) && roots.contains($0.bundleName) }
            if !mine.isEmpty || (e.identity == nil && found.isEmpty) { out.append((e.url, mine)) }
        }
        return out
    }

    /// the names of a library's folders on disk: what its archives' bundles are named
    static func rootNames(of library: ContentType) -> Set<String> {
        Set(library.paths.map { $0.liveURL(home: NSHomeDirectory()).lastPathComponent })
    }

    /// the folder a library's backups for `job` are written to, if there is one yet
    public static func folder(job: BackupJob, library: ContentType, in destination: URL) -> URL? {
        let key = LibraryIdentity.key(job: job, library: library)
        return listing(destination).first { $0.identity?.key == key }?.url
    }

    /// Get the library's folder ready for a run to write to: find it by its identity,
    /// or take over the 1.5 folder it wrote, or make a new one. Brings the folder's
    /// name and identity up to date with the library's name, and moves in any
    /// sealed versions a 1.5 folder it shares holds for it.
    ///
    /// - Parameters:
    ///   - jobs: every job, to tell whose a 1.5 folder is; `job` counts whether it's
    ///     among them or not
    ///   - isOpen: whether a disk image under a folder is attached (a folder isn't
    ///     renamed from under a reader)
    public static func prepare(job: BackupJob, library: ContentType, in destination: URL, jobs: [BackupJob],
                               isOpen: (URL) -> Bool = { LibraryFolders.anyImageAttached(under: $0) }) throws -> Prepared {
        let fm = FileManager.default
        let key = LibraryIdentity.key(job: job, library: library)
        let identity = LibraryIdentity(job: job, library: library)
        let entries = listing(destination)
        var notes: [String] = []
        let legacy = entries.first { $0.identity == nil && LibraryNames.same($0.url.lastPathComponent, library.displayName) }
        var folder = entries.filter { $0.identity?.key == key }
            .sorted { rank($0.url.lastPathComponent, library: library, key: key) < rank($1.url.lastPathComponent, library: library, key: key) }
            .first?.url

        if folder == nil, let legacy, owner(of: legacy.url, in: destination, jobs: jobs + [job]).map({ $0 == key }) == true {
            try identity.write(in: legacy.url)                    // taken over in place
            folder = legacy.url
        }
        if folder == nil {
            // a run that died between making a suffixed folder and writing its identity
            // left it without one; it is this library's by its name
            let suffixed = destination.appendingPathComponent(LibraryFolderName.make(job: job, library: library), isDirectory: true)
            let made = fm.fileExists(atPath: suffixed.path) && LibraryIdentity.read(in: suffixed) == nil ? suffixed
                : destination.appendingPathComponent(LibraryFolderName.choose(job: job, library: library, in: destination), isDirectory: true)
            try fm.createDirectory(at: made, withIntermediateDirectories: true)
            if let other = LibraryIdentity.read(in: made), other.key != key {
                throw LibraryFolderError.nameTaken(made.lastPathComponent)
            }
            try identity.write(in: made)
            folder = made
        }
        guard var folder else { throw LibraryFolderError.nameTaken(library.displayName) }

        // the name follows the library's; the identity says whose it is either way
        if !LibraryFolderName.fits(folder.lastPathComponent, name: library.displayName, key: key) {
            let renamed = destination.appendingPathComponent(LibraryFolderName.choose(job: job, library: library, in: destination), isDirectory: true)
            if !fm.fileExists(atPath: renamed.path), !isOpen(folder), rename(folder.path, renamed.path) == 0 {
                folder = renamed
            }
        }
        if LibraryIdentity.read(in: folder) != identity { try identity.write(in: folder) }

        // a 1.5 folder it shares with a mirror job (or one 1.5.6 wrote again after a
        // return to it): its sealed versions for this library move in
        if let legacy, legacy.url != folder,
           versionMover(of: legacy.url, in: destination, jobs: jobs + [job]) == key {
            let (moved, left) = moveVersions(from: legacy.url, to: folder)
            // emptied (a folder only 1.5.6 wrote, say): gone, so nothing looks for it
            if moved > 0 { rmdir(legacy.url.path) }
            if moved > 0 || left > 0 {
                notes.append("moved \(moved) earlier version\(moved == 1 ? "" : "s") of \(library.displayName) from “\(legacy.url.lastPathComponent)” into “\(folder.lastPathComponent)”"
                             + (left > 0 ? "; \(left) with the same time as one already there stayed where they were" : ""))
            }
        }
        // a copy at its top (a mirror) that is this library's, or can't be told whose,
        // stays, and is no longer updated: say so once a run
        if let legacy, legacy.url != folder, RestoreDiscovery.archive(at: legacy.url) != nil,
           claimants(of: legacy.url, in: destination, jobs: jobs + [job]).contains(where: { $0.key == key }),
           [nil, key].contains(owner(of: legacy.url, in: destination, jobs: jobs + [job])) {
            notes.append("an earlier copy of \(library.displayName) is still in “\(legacy.url.lastPathComponent)”, and is no longer updated; Restore still finds it. Delete it once you no longer need it.")
        }
        return Prepared(folder: folder, notes: notes)
    }

    // MARK: whose a 1.5 folder is

    /// The library (by identity key) a 1.5 folder at `destination` belongs to, if it
    /// can belong to only one. The libraries that could have written it are those of
    /// the jobs writing to `destination` that carry its name, and, when it holds an
    /// archive, whose source folder has the archive's bundle name. When it holds a
    /// mirror, only a mirror job's library can own it: a sealed job that took it over
    /// would sit on a full copy nothing updates, and say nothing of it.
    public static func owner(of legacy: URL, in destination: URL, jobs: [BackupJob]) -> String? {
        let all = claimants(of: legacy, in: destination, jobs: jobs)
        let holdsMirror = RestoreDiscovery.archive(at: legacy)?.format == .liveMirror
        let mirrors = all.filter { $0.mirror }, sealed = all.filter { !$0.mirror }
        if holdsMirror { return mirrors.count == 1 ? mirrors[0].key : nil }
        if sealed.count == 1 && mirrors.isEmpty { return sealed[0].key }
        return all.count == 1 ? all[0].key : nil
    }

    /// The library (by identity key) whose sealed versions in a 1.5 folder move into
    /// its own folder: the one sealed library that could have written them, when the
    /// folder is someone else's (a mirror job's) or nobody's.
    static func versionMover(of legacy: URL, in destination: URL, jobs: [BackupJob]) -> String? {
        let sealed = claimants(of: legacy, in: destination, jobs: jobs).filter { !$0.mirror }
        return sealed.count == 1 ? sealed[0].key : nil
    }

    struct Claimant: Equatable { let key: String; let mirror: Bool }

    static func claimants(of legacy: URL, in destination: URL, jobs: [BackupJob]) -> [Claimant] {
        let name = legacy.lastPathComponent
        let bundles = Set(RestoreDiscovery.scan(legacy, maxDepth: 1).map(\.bundleName))
        var seen = Set<String>(), out: [Claimant] = []
        for job in jobs where job.targets.contains(where: { samePlace($0.destinationDir, destination) }) {
            for lib in job.libraries where LibraryNames.same(lib.displayName, name) {
                if !bundles.isEmpty {
                    guard !rootNames(of: lib).isDisjoint(with: bundles) else { continue }
                }
                let key = LibraryIdentity.key(job: job, library: lib)
                if seen.insert(key).inserted { out.append(Claimant(key: key, mirror: !job.format.isSealed)) }
            }
        }
        return out
    }

    // MARK: moving versions

    /// move each version folder (a timestamped folder with a manifest) of `legacy`
    /// into `folder`, one rename each: a crash leaves each version in one place or the
    /// other, whole. A version whose time is already in `folder` stays.
    static func moveVersions(from legacy: URL, to folder: URL) -> (moved: Int, left: Int) {
        let fm = FileManager.default
        var moved = 0, left = 0
        for e in (try? fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)) ?? [] {
            guard VersionStamp.date(e.lastPathComponent) != nil,
                  fm.fileExists(atPath: e.appendingPathComponent(ArchiveManifest.sidecarName).path) else { continue }
            let to = folder.appendingPathComponent(e.lastPathComponent, isDirectory: true)
            if fm.fileExists(atPath: to.path) { left += 1; continue }
            if rename(e.path, to.path) == 0 { moved += 1 } else { left += 1 }
        }
        return (moved, left)
    }

    // MARK: helpers

    struct Entry { let url: URL; let identity: LibraryIdentity? }

    /// the folders directly in `destination`, with their identities
    static func listing(_ destination: URL) -> [Entry] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: destination, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return items.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { u in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            return Entry(url: u, identity: LibraryIdentity.read(in: u))
        }
    }

    /// among folders with the library's identity (a copy made by hand, say), the one
    /// named as it should be first
    private static func rank(_ name: String, library: ContentType, key: String) -> Int {
        if LibraryNames.same(name, LibraryFolderName.make(name: library.displayName, key: key)) { return 0 }
        return LibraryNames.same(name, library.displayName) ? 1 : 2
    }

    /// two spellings of one folder
    static func samePlace(_ a: URL, _ b: URL) -> Bool {
        func canon(_ u: URL) -> String { TMUtilSnapshotBackend.canonicalPath(u.standardizedFileURL.resolvingSymlinksInPath().path) }
        return canon(a) == canon(b)
    }

    /// whether a disk image under `folder` is attached on this Mac
    public static func anyImageAttached(under folder: URL, runner: CommandRunner = ProcessCommandRunner()) -> Bool {
        let base = TMUtilSnapshotBackend.canonicalPath(folder.resolvingSymlinksInPath().path) + "/"
        return MirrorMounts.attachedImages(runner: runner).contains {
            TMUtilSnapshotBackend.canonicalPath(URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path).hasPrefix(base)
        }
    }
}

public enum LibraryFolderError: Error, Equatable, LocalizedError {
    /// a folder of the name a new library folder would take holds another library's
    case nameTaken(String)

    public var errorDescription: String? {
        switch self {
        case .nameTaken(let name):
            return "the folder “\(name)” at the destination belongs to another library, so this library's backups can't be kept there"
        }
    }
}
