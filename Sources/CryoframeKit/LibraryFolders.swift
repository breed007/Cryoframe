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
        let entries = listing(destination)
        // each archive as this library's, whatever folder it sits in: a version 1.5.6
        // wrote into a mirror job's folder, checked there, then moved home, is still
        // the one that was checked (see KnownGood)
        func owned(_ found: [RestorableArchive]) -> [RestorableArchive] {
            found.map { var a = $0; a.libraryKey = key; return a }
        }
        var out: [(folder: URL, archives: [RestorableArchive])] = entries.filter { $0.identity?.key == key }
            .sorted { rank($0.url.lastPathComponent, library: library, key: key) < rank($1.url.lastPathComponent, library: library, key: key) }
            .map { ($0.url, owned(RestoreDiscovery.scan($0.url, maxDepth: 1).filter(ofItsKind))) }
        for e in entries where e.identity?.key != key && e.identity?.jobID != job.id
            && LibraryNames.same(e.url.lastPathComponent, library.displayName) {
            // another job's folder only if it's a mirror job's: the one kind of folder
            // 1.5.6 writes another job's versions into. A sealed job's folder, deleted
            // or no longer written to, holds that job's backups, under its key.
            if e.identity != nil, mirror || !holdsMirror(e.url) { continue }
            let found = RestoreDiscovery.scan(e.url, maxDepth: 1)
            let mine = found.filter { ofItsKind($0) && isOf(library, bundle: $0.bundleName) }
            if !mine.isEmpty || (e.identity == nil && found.isEmpty) { out.append((e.url, owned(mine))) }
        }
        return out
    }

    /// Whether `destination` holds backups this very job made, by evidence only it can
    /// have: a folder with the identity of one of its libraries, or a 1.5 folder of one
    /// of their names holding a version made by one of `runs` (the job's recorded runs):
    /// stamped when that run started, and exactly the size it recorded for the library.
    /// A name and a bundle name aren't evidence: another Mac's drive of the same name
    /// (every drive of a make comes with one) can hold the same folder's backups, and
    /// two Macs on the default schedule stamp versions in the same second.
    public static func holdsBackups(of job: BackupJob, in destination: URL, runs: [RunRecord]) -> Bool {
        let entries = listing(destination)
        if entries.contains(where: { $0.identity?.jobID == job.id }) { return true }
        let mine = runs.filter { $0.jobID == job.id }
        guard !mine.isEmpty else { return false }
        for e in entries where e.identity == nil {
            let names = job.libraries.map(\.displayName).filter { LibraryNames.same($0, e.url.lastPathComponent) }
            guard !names.isEmpty else { continue }
            for a in RestoreDiscovery.scan(e.url, maxDepth: 1) {
                guard let made = a.version else { continue }
                if mine.contains(where: { r in
                    abs(made.timeIntervalSince(r.startedAt)) <= 5
                        && r.libraries.contains { o in names.contains(o.library) && o.parts > 0 && o.bytes == a.bytes }
                }) { return true }
            }
        }
        return false
    }

    /// The key a check of `archive`, found by a scan, is recorded under: its folder's,
    /// but none for a sealed version sitting in a folder that holds a mirror (one 1.5.6
    /// wrote into a mirror job's folder, which moves home to its own library's folder
    /// on the next run); a check without a key counts by the library's name.
    public static func checkKey(of archive: RestorableArchive) -> String? {
        archive.version != nil && holdsMirror(archive.libraryFolder) ? nil : archive.libraryKey
    }

    /// whether a folder holds a mirror at its top
    static func holdsMirror(_ folder: URL) -> Bool { RestoreDiscovery.archive(at: folder)?.format == .liveMirror }

    /// Whether an archive whose bundle is named `bundle` can be `library`'s: its folder
    /// on disk has that name, or, for a built-in library kept in a package, the bundle
    /// is a package of the same kind. The Photos library can be one other than the
    /// usual "Photos Library.photoslibrary" (chosen in Cryoframe, or since renamed),
    /// and its older archives carry the name it had; a custom folder "Photos" is still
    /// told from it.
    static func isOf(_ library: ContentType, bundle: String) -> Bool {
        let roots = library.paths.map { $0.liveURL(home: NSHomeDirectory()).lastPathComponent }
        if roots.contains(bundle) { return true }
        guard ContentTypeRegistry.builtIns.contains(where: { $0.id == library.id }) else { return false }
        let kind = (bundle as NSString).pathExtension.lowercased()
        return !kind.isEmpty && roots.contains { ($0 as NSString).pathExtension.lowercased() == kind }
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
        let current = LibraryIdentity.read(in: folder), updated = identity.following(current)
        if current != updated { try updated.write(in: folder) }

        // Its sealed versions in any other folder of its name move in: a 1.5 folder it
        // shared with a mirror job, whichever of the two took it over first, or a
        // folder 1.5.6 wrote them into after a return to it (another job's included).
        // Only versions that can be no other library's, and not one being read. (Not
        // from another library of this job: 1.5.6 doesn't run a job with two
        // libraries of one name, so nothing of this one's is there.)
        let others = listing(destination).filter {
            $0.url.path != folder.path && $0.identity?.key != key && $0.identity?.jobID != job.id
                && LibraryNames.same($0.url.lastPathComponent, library.displayName)
        }
        // Out of another job's folder only when that job is a mirror job writing here:
        // a sealed job's folder, the job deleted (its backups stay) or writing
        // elsewhere, holds its own versions, and this job's retention would delete them.
        let mirrorJobs = Set(jobs.filter { !$0.format.isSealed }.map(\.id))
        for other in others where job.format.isSealed && (other.identity.map { mirrorJobs.contains($0.jobID) } ?? true) {
            let r = moveVersions(from: other.url, to: folder, key: key, in: destination, jobs: jobs + [job], isOpen: isOpen)
            // emptied (a folder only 1.5.6 wrote, say): gone, so nothing looks for it
            if r.moved > 0, other.identity == nil { rmdir(other.url.path) }
            if r.moved > 0 || r.left > 0 || r.busy > 0 {
                notes.append("moved \(r.moved) earlier version\(r.moved == 1 ? "" : "s") of \(library.displayName) from “\(other.url.lastPathComponent)” into “\(folder.lastPathComponent)”"
                             + (r.left > 0 ? "; \(r.left) with the same time as one already there stayed where they were" : "")
                             + (r.busy > 0 ? "; \(r.busy) being read stayed where they were, and move on a later run" : ""))
            }
        }
        // A copy of this library at the top of another folder of its name (a mirror
        // 1.5 or 1.5.6 made there) that no mirror job keeps up: it stays, and is no
        // longer updated. Say so once a run.
        for other in others {
            guard let top = RestoreDiscovery.archive(at: other.url), top.format == .liveMirror, top.version == nil,
                  isOf(library, bundle: top.bundleName) else { continue }
            let mirrors = claimants(named: other.url.lastPathComponent, bundles: [top.bundleName], in: destination, jobs: jobs + [job])
                .filter(\.mirror).map(\.key)
            if let id = other.identity?.key, mirrors.contains(id) { continue }          // another mirror job's own copy
            guard mirrors.isEmpty || mirrors.contains(key) else { continue }             // the mirror job that will take it over
            notes.append("an earlier copy of \(library.displayName) is still in “\(other.url.lastPathComponent)”, and is no longer updated; Restore still finds it. Delete it once you no longer need it.")
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

    struct Claimant: Equatable { let key: String; let mirror: Bool }

    /// the libraries of the jobs writing to `destination` that could have written the
    /// archives of a 1.5 folder: those named like it, and whose source folder has one
    /// of its archives' bundle names (any, when it holds none)
    static func claimants(of legacy: URL, in destination: URL, jobs: [BackupJob]) -> [Claimant] {
        claimants(named: legacy.lastPathComponent, bundles: Set(RestoreDiscovery.scan(legacy, maxDepth: 1).map(\.bundleName)),
                  in: destination, jobs: jobs)
    }

    static func claimants(named name: String, bundles: Set<String>, in destination: URL, jobs: [BackupJob]) -> [Claimant] {
        var seen = Set<String>(), out: [Claimant] = []
        for job in jobs where job.targets.contains(where: { samePlace($0.destinationDir, destination) }) {
            for lib in job.libraries where LibraryNames.same(lib.displayName, name) {
                if !bundles.isEmpty {
                    guard bundles.contains(where: { isOf(lib, bundle: $0) }) else { continue }
                }
                let key = LibraryIdentity.key(job: job, library: lib)
                if seen.insert(key).inserted { out.append(Claimant(key: key, mirror: !job.format.isSealed)) }
            }
        }
        return out
    }

    // MARK: moving versions

    /// Move each version folder (a timestamped folder with a manifest) of `other` that
    /// is the library `key`'s into `folder`, one rename each: a crash leaves each
    /// version in one place or the other, whole. A version is that library's when it
    /// is the only sealed library of the jobs writing to `destination` that could
    /// have written it (by name and bundle name). One whose time is already in
    /// `folder` stays (`left`), and so does one with a disk image attached, a restore
    /// or a drill reading it (`busy`).
    static func moveVersions(from other: URL, to folder: URL, key: String, in destination: URL, jobs: [BackupJob],
                             isOpen: (URL) -> Bool) -> (moved: Int, left: Int, busy: Int) {
        let fm = FileManager.default
        var moved = 0, left = 0, busy = 0
        for e in (try? fm.contentsOfDirectory(at: other, includingPropertiesForKeys: nil)) ?? [] {
            guard VersionStamp.date(e.lastPathComponent) != nil, let a = RestoreDiscovery.archive(at: e), a.format != .liveMirror else { continue }
            let sealed = claimants(named: other.lastPathComponent, bundles: [a.bundleName], in: destination, jobs: jobs).filter { !$0.mirror }
            guard sealed.map(\.key) == [key] else { continue }
            let to = folder.appendingPathComponent(e.lastPathComponent, isDirectory: true)
            if fm.fileExists(atPath: to.path) { left += 1; continue }
            if isOpen(e) { busy += 1; continue }
            if rename(e.path, to.path) == 0 { moved += 1 } else { left += 1 }
        }
        return (moved, left, busy)
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
