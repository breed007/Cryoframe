//
//  RemovedArchive.swift
//  CryoframeKit
//
//  Dated versions of a library that keeps what is deleted from it (see
//  ContentType.keepsRemoved): every version holds what the library held then, so an
//  item deleted since is still in the versions made before, until retention deletes
//  the last of them. Before it does, the items only those versions hold are saved in
//  a removed-items archive, in the same format and with the same passphrase:
//
//    <library folder>/<yyyy-MM-dd-HHmmss>/                      a version
//    <library folder>/Removed items/<yyyy-MM-dd-HHmmss>/        a removed-items archive
//        <name>.dmg or <name>.zip, its manifest and its file list
//
//  Retention never deletes a removed-items archive; deleting the job's backups does,
//  and so does the person, in Restore. 1.6.0 looks for versions only directly in the
//  library folder, so it neither shows nor prunes them.
//
//  Which items: a file or link whose path is in a version about to go and in no
//  version that stays (the run's own new one among them, which holds what the library
//  holds now), and in no earlier removed-items archive; taken from the newest going
//  version holding it. By path alone: an item that changed wasn't deleted (a changed
//  file is one copy, no history, as in every one-copy format), and one path is one
//  item in an archive. Found from the versions' file lists; a going version
//  without a whole list is opened and looked through. A version that stays without a
//  list counts as holding nothing, so at worst an item is saved twice.
//
//  Fail closed: anything that stops the items being saved (a version that won't
//  open, a missing passphrase, no room to build, Stop) keeps every going version that
//  holds any of them, and the run says so; nothing is lost, and the next run tries
//  again.
//

import Foundation
import CryptoKit

struct RemovedArchive {
    let library: ContentType
    let jobID: String
    let sealed: SealedArchiveEngine.Sealed
    let passphrase: String?
    /// the job's file-list key, for reading and sealing lists (see ContentsCrypto)
    let listKey: SymmetricKey?
    /// how the destination splits what it holds
    let split: SplitPolicy
    /// where the archive is built, and where the items are gathered for it (an
    /// encrypted job's on the startup disk; see JobExecutor.plaintextScratch), each
    /// `<scratch>/<job>/build/<library>`; removed afterward, however it ends
    let buildDir: URL
    let gatherDir: URL
    let runner: CommandRunner
    let now: Date
    /// opens a version (tests give their own)
    var open: (RestorableArchive, String?) throws -> OpenedArchive

    init(library: ContentType, jobID: String, sealed: SealedArchiveEngine.Sealed, passphrase: String?, listKey: SymmetricKey?,
         split: SplitPolicy = .none, buildDir: URL, gatherDir: URL, runner: CommandRunner, now: Date,
         open: ((RestorableArchive, String?) throws -> OpenedArchive)? = nil) {
        self.library = library; self.jobID = jobID; self.sealed = sealed; self.passphrase = passphrase
        self.listKey = listKey; self.split = split; self.buildDir = buildDir; self.gatherDir = gatherDir
        self.runner = runner; self.now = now
        self.open = open ?? { a, p in try ArchiveReader(runner: runner).open(a.archiveResult(), passphrase: p) }
    }

    /// What `keep` did: how many items it saved, the going versions it kept (none
    /// unless it couldn't save them), and why.
    struct Outcome: Sendable, Equatable {
        var kept = 0
        var spared: Set<URL> = []
        var why: String?
    }

    /// an item, as two versions hold the same one: by its path (see the top)
    typealias Item = String

    // MARK: where they are

    /// `folder`'s removed-items archives, oldest first
    static func archives(in folder: URL) -> [RestorableArchive] {
        let removed = folder.appendingPathComponent(PlainCopyLayout.removedFolder, isDirectory: true)
        return PlainCopy.list(removed.path).filter { VersionStamp.date($0) != nil }.sorted()
            .compactMap { RestoreDiscovery.archive(at: removed.appendingPathComponent($0, isDirectory: true)) }
    }

    /// What a run cut off while copying a removed-items archive to the drive (a crash,
    /// Force Quit, a restart) left in `folder`'s Removed items: a folder named for a
    /// version, with no manifest (written last, so a whole copy always has one), named
    /// and last changed before `started`, the start of the run that removes them, so
    /// never the archive a run is copying now. Restore doesn't show these, and nothing
    /// else would ever remove them.
    static func husks(in folder: URL, before started: Date) -> [URL] {
        let removed = folder.appendingPathComponent(PlainCopyLayout.removedFolder, isDirectory: true)
        return PlainCopy.list(removed.path).sorted().compactMap { name -> URL? in
            guard let date = VersionStamp.date(name), date < started else { return nil }
            let dir = removed.appendingPathComponent(name, isDirectory: true)
            var st = stat()
            guard lstat(dir.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR,
                  Double(st.st_mtimespec.tv_sec) < started.timeIntervalSince1970,
                  lstat(dir.appendingPathComponent(ArchiveManifest.sidecarName).path, &st) != 0 else { return nil }
            return dir
        }
    }

    /// `folder`'s complete versions (those with a manifest)
    static func versions(in folder: URL) -> [RestorableArchive] {
        PlainCopy.list(folder.path).filter { VersionStamp.date($0) != nil }.sorted()
            .compactMap { RestoreDiscovery.archive(at: folder.appendingPathComponent($0, isDirectory: true)) }
    }

    // MARK: keeping

    /// Save what only `going` (version folders in `folder`, about to be deleted) hold
    /// (see the top).
    func keep(goingFrom going: [URL], in folder: URL) -> Outcome {
        let control = runner.control
        let goingNames = Set(going.map(\.lastPathComponent))
        let all = Self.versions(in: folder)
        let leaving = all.filter { goingNames.contains($0.dir.lastPathComponent) }.sorted { ($0.version ?? .distantPast) > ($1.version ?? .distantPast) }
        guard !leaving.isEmpty else { return Outcome() }
        let spareAll = Set(going)
        if control?.isCancelled == true { return Outcome(spared: spareAll, why: "the backup was stopped") }

        // what stays: the versions that aren't going, and the removed-items archives
        control?.begin("Looking for deleted items in older versions", stage: .finishing)
        var held = Set<Item>()
        for a in all where !goingNames.contains(a.dir.lastPathComponent) {
            _ = listed(a) { held.insert($0) }
        }
        for a in Self.archives(in: folder) { _ = listed(a) { held.insert($0) } }

        // what each going version holds alone, newest first
        var taken = Set<Item>()
        var plan: [(version: RestorableArchive, items: [Item])] = []
        for v in leaving {
            if control?.isCancelled == true { return Outcome(spared: spareAll, why: "the backup was stopped") }
            var items: [Item] = []
            let whole = listed(v, wholeOnly: true) { if !held.contains($0), taken.insert($0).inserted { items.append($0) } }
            if !whole {
                // no whole list: looked through (it is opened again to gather from)
                do {
                    let opened = try open(v, passphrase)
                    defer { opened.close() }
                    for item in Self.walk(ArchiveLayout.libraryRoot(in: opened.root, for: v), atTop: opened.root, control: control)
                    where !held.contains(item) && taken.insert(item).inserted { items.append(item) }
                } catch is CancelledError {
                    return Outcome(spared: spareAll, why: "the backup was stopped")
                } catch {
                    return Outcome(spared: spareAll, why: "\(v.dir.lastPathComponent) couldn't be opened: \(error.localizedDescription)")
                }
            }
            if !items.isEmpty { plan.append((v, items)) }
        }
        guard !plan.isEmpty else { return Outcome() }
        let spared = Set(plan.map { $0.version.dir })
            .reduce(into: Set<URL>()) { out, dir in out.formUnion(going.filter { $0.lastPathComponent == dir.lastPathComponent }) }

        defer {
            FilteredCopy.remove(in: gatherDir, runner: runner.forTeardown)
            try? FileManager.default.removeItem(at: buildDir.appendingPathComponent("removed", isDirectory: true))
            FilteredCopy.removeEmpty(gatherDir)
            if buildDir.path != gatherDir.path { FilteredCopy.removeEmpty(buildDir) }
        }
        do {
            let count = try build(plan, in: folder)
            return Outcome(kept: count)
        } catch is CancelledError {
            return Outcome(spared: spared, why: "the backup was stopped")
        } catch {
            return Outcome(spared: spared, why: error.localizedDescription)
        }
    }

    /// Hand each file and link `a`'s list names to `visit`; whether the list was read
    /// (and, with `wholeOnly`, didn't stop short). Items handed over from a list that
    /// turns out not to count are only ever extra (see the top).
    private func listed(_ a: RestorableArchive, wholeOnly: Bool = false, visit: (Item) -> Void) -> Bool {
        let key = listKey
        var items: [Item] = []
        let outcome = ContentsListing.read(a, master: { _ in key.map { [$0] } ?? [] }, control: runner.control) { e in
            guard e.kind != .folder else { return }
            items.append(e.path)
        }
        guard case .read(_, let partial) = outcome, !(wholeOnly && partial) else { return false }
        items.forEach(visit)
        return true
    }

    /// the files and links under `root`, as a list names them
    static func walk(_ root: URL, atTop top: URL, control: RunControl?) -> [Item] {
        var out: [Item] = []
        guard let e = FileManager.default.enumerator(atPath: root.path) else { return out }
        while let rel = e.nextObject() as? String {
            if root.standardizedFileURL == top.standardizedFileURL, !rel.contains("/"),
               ArchiveBookkeeping.isHidden(rel, atRoot: true) { e.skipDescendants(); continue }
            var st = stat()
            guard lstat(root.appendingPathComponent(rel).path, &st) == 0 else { continue }
            let type = st.st_mode & S_IFMT
            guard type == S_IFREG || type == S_IFLNK else { continue }
            out.append(rel)
        }
        return out
    }

    /// Gather `plan`'s items from their versions, build the archive and put it in
    /// place in `folder`'s Removed items. Returns how many items it holds.
    private func build(_ plan: [(version: RestorableArchive, items: [Item])], in folder: URL) throws -> Int {
        let fm = FileManager.default
        let control = runner.control
        let name = plan[0].version.bundleName
        try ScratchLayout.claim(libraryDir: buildDir)
        try ScratchLayout.claim(libraryDir: gatherDir)
        FilteredCopy.remove(in: gatherDir, runner: runner.forTeardown)
        let gatherFolder = gatherDir.appendingPathComponent(FilteredCopy.folderName, isDirectory: true)
        let gathered = gatherFolder.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: gathered, withIntermediateDirectories: true)
        FilteredCopy.markPrivate(gatherFolder)

        let total = plan.reduce(0) { $0 + $1.items.count }
        control?.begin("Saving items deleted from \(library.displayName)", stage: .finishing, total: UInt64(total))
        for (version, items) in plan {
            if control?.isCancelled == true { throw CancelledError() }
            let opened = try open(version, passphrase)
            defer { opened.close() }
            let root = ArchiveLayout.libraryRoot(in: opened.root, for: version)
            for item in items {
                if control?.isCancelled == true { throw CancelledError() }
                control?.advance()
                let to = gathered.appendingPathComponent(item)
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard copyfile(root.appendingPathComponent(item).path, to.path, nil,
                               copyfile_flags_t(COPYFILE_ALL | COPYFILE_NOFOLLOW)) == 0 else {
                    throw RemovedArchiveError.couldNotGather(item, version.dir.lastPathComponent, String(cString: strerror(errno)))
                }
            }
        }

        // a name no version or earlier archive has
        let removed = folder.appendingPathComponent(PlainCopyLayout.removedFolder, isDirectory: true)
        var date = now
        while fm.fileExists(atPath: removed.appendingPathComponent(VersionStamp.string(date)).path) { date += 1 }
        let stamp = VersionStamp.string(date)
        let listing = ContentsListing.Collector(binding: ContentsCrypto.Binding(jobID: jobID, libraryID: library.id, version: stamp))
        _ = JobExecutor.directoryStats(gathered, listing: listing)

        let out = buildDir.appendingPathComponent("removed", isDirectory: true)
        try? fm.removeItem(at: out)
        control?.begin("Building the archive of deleted items", stage: .finishing)
        let built = try SealedArchiveEngine(sealed, split: .none, runner: runner, passphrase: passphrase)
            .archive(ArchiveSource(name: name, root: gathered), to: out)
        guard let file = built.artifacts.first else { throw ArchiveError.noArtifactProduced(out) }
        let digest = try Checksum.sha256(of: file)
        let contents = ContentsListing.write(listing, master: listKey, encrypted: passphrase != nil, into: out)
        if control?.isCancelled == true { throw CancelledError() }

        control?.begin("Copying the archive of deleted items", stage: .finishing)
        let dest = removed.appendingPathComponent(stamp, isDirectory: true)
        do {
            let result = try SealedArchiveEngine(sealed, split: split, runner: runner)
                .distribute(builtFile: file, into: dest, encrypted: passphrase != nil, contents: contents)
            let size = ((try? fm.attributesOfItem(atPath: file.path))?[.size] as? UInt64) ?? 0
            guard JobExecutor.copyMatches(result, expectedDigest: digest, expectedBytes: size) else {
                throw RemovedArchiveError.copyDiffers
            }
        } catch {
            try? fm.removeItem(at: dest)
            throw error
        }
        return total
    }
}

enum RemovedArchiveError: Error, LocalizedError, Equatable {
    case couldNotGather(String, String, String)
    case copyDiffers

    var errorDescription: String? {
        switch self {
        case .couldNotGather(let item, let version, let why):
            return "“\(item)” couldn't be copied out of the version of \(version): \(why)"
        case .copyDiffers:
            return "the archive of deleted items, copied to the drive, didn't match the one built"
        }
    }
}
