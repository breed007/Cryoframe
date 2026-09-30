//
//  DriveRename.swift
//  CryoframeKit
//
//  Rename this drive: two drives that took turns under one name become two drives
//  with names of their own, taking turns as a rotation.
//
//  Through 1.5 the only way to rotate two drives was to give them one name. Two
//  drives of one name can't be told apart by anyone looking at them in Finder, a
//  notice about one ("hasn't had a copy in 19 days") can't say which to bring home,
//  and a name can only lead to one of them. So the drive connected now is renamed
//  ("T7" to "T7 B"), and the job is changed to match: its destination keeps the
//  other drive, and a new destination on this one takes turns with it.
//
//  Renaming is `diskutil rename <volume UUID> <name>`, as the user: the UUID says
//  which drive, whatever it's called. Measured on disk images: no administrator
//  needed; APFS, HFS+, exFAT and FAT32 are renamed while mounted and in use; the
//  UUID, the device, every inode and every date stay as they were. Renaming it in
//  Finder instead was rejected: with both drives called "T7", the wrong one is
//  easily picked.
//
//  Renaming changes the drive's name only, but the drive then becomes the job's:
//  the next backup takes over the job's 1.5 folders on it, as pairing would (see
//  DrivePairing), and its Keep rule may delete dated versions there or replace an
//  up-to-date copy. So a rename goes through the same look: a drive holding
//  anything of another job's (of this Mac or another) is refused, and one whose
//  backups the next run changes is renamed only when the caller passes the look the
//  person confirmed, and it still says the same.
//
//  Nothing is renamed while anything of Cryoframe's uses the drive (a run, a check,
//  an interrupted transfer to finish on it, a disk image attached from it), or when
//  it's a Time Machine destination. The job's folder on the drive is looked at
//  before and after (every entry's inode, size and date; no file is read): a rename
//  that changed anything, or that can't be confirmed, is put back and the job is
//  left as it was. The job files are written once, after that.
//

import Foundation

public enum DriveRename {
    /// A mounted volume, as diskutil describes it.
    public struct Drive: Sendable, Equatable {
        public var uuid: String
        public var name: String
        public var mountPoint: URL
        /// "apfs", "hfs", "exfat", "msdos"
        public var fileSystem: String
        public var isInternal: Bool
        public var isWritable: Bool
    }

    public enum Refusal: Error, Equatable, LocalizedError {
        case notConnected(String)
        case notExternal(String)
        case readOnly(String)
        case inUse(String)
        case transferPending(String)
        case imageAttached(String)
        case timeMachine(String)
        case invalidName(String)
        case nameTaken(String)
        /// diskutil couldn't rename it: nothing changed
        case failed(String)
        /// renamed, but the rename couldn't be confirmed: put back (or not, said why)
        case notConfirmed(String)
        /// renamed and confirmed, but the job was changed meanwhile and wasn't updated
        case renamedJobNotUpdated(String)
        case unchecked(String)
        /// it holds backups that aren't this job's (see DrivePairing): why, in words
        case notThisJobsDrive(String)
        /// what the next backup does to the drive's backups wasn't confirmed, or has
        /// changed since it was shown
        case effectNotConfirmed

        public var errorDescription: String? {
            switch self {
            case .notConnected(let n): "\(n) isn't connected."
            case .notExternal(let n): "\(n) is part of this Mac, not a drive that comes and goes."
            case .readOnly(let n): "\(n) can't be written to, so it can't be renamed."
            case .inUse(let why): "It wasn't renamed: \(why). Try again once that's done."
            case .transferPending(let n): "It wasn't renamed: an interrupted upload is still to finish on \(n)."
            case .imageAttached(let n): "It wasn't renamed: a disk image on \(n) is open, or whether one is can't be told. Close what's reading it, or eject it in Disk Utility, then try again."
            case .timeMachine(let n): "\(n) is a Time Machine drive. Rename it in Time Machine's settings, not here."
            case .invalidName(let why): why
            case .nameTaken(let n): "A drive named “\(n)” is already connected or known to your backups. Choose another name."
            case .failed(let why): "The drive wasn't renamed: \(why)"
            case .notConfirmed(let why): "The rename couldn't be confirmed, so it was undone and the job was left as it was: \(why)"
            case .renamedJobNotUpdated(let n): "The drive is now called “\(n)”, but the job was changed meanwhile, so it wasn't updated. Add the drive to it as a destination."
            case .unchecked(let why): "It wasn't renamed: \(why)"
            case .notThisJobsDrive(let why): "It wasn't renamed. \(why)"
            case .effectNotConfirmed: "It wasn't renamed: what the next backup does to the backups on it has changed since it was shown. Look again, and confirm what it now says."
            }
        }
    }

    // MARK: the name

    /// "T7 B" for a drive named "T7", or the next letter free among `taken`
    public static func suggestedName(for name: String, taken: [String]) -> String {
        for letter in "BCDEFGHIJKLMNOPQRSTUVWXYZ" {
            let candidate = "\(name) \(letter)"
            if !taken.contains(where: { LibraryNames.same($0, candidate) }) { return candidate }
        }
        return "\(name) 2"
    }

    /// Why `name` can't be a volume name on `fileSystem`, or nil. FAT32 and exFAT
    /// take 11 characters (a 12th is refused, measured), FAT32 plain ASCII.
    public static func nameProblem(_ name: String, fileSystem: String) -> String? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { return "Give the drive a name." }
        if n != name { return "A drive name can't start or end with a space." }
        if n.hasPrefix(".") { return "A drive name can't start with a dot: the drive would be hidden." }
        if n.contains("/") || n.contains(":") { return "A drive name can't contain “/” or “:”." }
        if n.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return "A drive name can't contain control characters." }
        switch fileSystem.lowercased() {
        case "msdos":
            if n.count > 11 { return "This drive's format (FAT) allows 11 characters at most." }
            if !n.unicodeScalars.allSatisfy({ $0.isASCII }) || n.contains(where: { "\"*+,.;<=>?[\\]|".contains($0) }) {
                return "This drive's format (FAT) allows letters, digits, spaces and a few marks only."
            }
        case "exfat":
            if n.utf16.count > 11 { return "This drive's format (exFAT) allows 11 characters at most." }
            if n.contains(where: { "\"*<>?\\|".contains($0) }) { return "This drive's format (exFAT) doesn't allow \" * < > ? \\ or |." }
        default:
            if n.utf8.count > 255 { return "That name is too long." }
        }
        return nil
    }

    // MARK: looking

    /// What diskutil says of the volume `uuid`; nil when it isn't mounted.
    public static func drive(_ uuid: String, runner: CommandRunner = ProcessCommandRunner()) -> Drive? {
        guard let r = try? runner.run("/usr/sbin/diskutil", ["info", "-plist", uuid], stdin: nil), r.ok,
              let plist = try? PropertyListSerialization.propertyList(from: Data(r.stdout.utf8), format: nil) as? [String: Any],
              let found = plist["VolumeUUID"] as? String, found.caseInsensitiveCompare(uuid) == .orderedSame,
              let mount = plist["MountPoint"] as? String, !mount.isEmpty,
              let name = plist["VolumeName"] as? String else { return nil }
        return Drive(uuid: found, name: name, mountPoint: URL(fileURLWithPath: mount, isDirectory: true),
                     fileSystem: (plist["FilesystemType"] as? String) ?? "",
                     isInternal: (plist["Internal"] as? Bool) ?? true,
                     isWritable: (plist["WritableVolume"] as? Bool) ?? false)
    }

    /// Whether `drive` is a Time Machine destination: an APFS volume with the Backup
    /// role, or a local destination Time Machine lists (at its mount point, or by its
    /// name when it isn't mounted there). nil when it can't be told.
    static func isTimeMachine(_ drive: Drive, runner: CommandRunner) -> Bool? {
        if drive.fileSystem == "apfs" {
            guard let r = try? runner.run("/usr/sbin/diskutil", ["apfs", "list", "-plist"], stdin: nil), r.ok,
                  let plist = try? PropertyListSerialization.propertyList(from: Data(r.stdout.utf8), format: nil) as? [String: Any]
            else { return nil }
            for c in plist["Containers"] as? [[String: Any]] ?? [] {
                for v in c["Volumes"] as? [[String: Any]] ?? []
                    where (v["APFSVolumeUUID"] as? String)?.caseInsensitiveCompare(drive.uuid) == .orderedSame {
                    if (v["Roles"] as? [String] ?? []).contains("Backup") { return true }
                }
            }
        }
        guard let r = try? runner.run("/usr/bin/tmutil", ["destinationinfo"], stdin: nil) else { return nil }
        // none set up: tmutil says so and fails
        guard r.ok else { return r.stdout.contains("No destinations") || r.stderr.contains("No destinations") ? false : nil }
        for block in r.stdout.components(separatedBy: "====") {
            var fields: [String: String] = [:]
            for line in block.split(separator: "\n") {
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2 { fields[parts[0].replacingOccurrences(of: "> ", with: "")] = parts[1] }
            }
            guard fields["Kind"] == "Local" else { continue }
            if let mp = fields["Mount Point"], DestinationRules.samePath(URL(fileURLWithPath: mp), drive.mountPoint) { return true }
            if fields["Mount Point"] == nil, let n = fields["Name"], LibraryNames.same(n, drive.name) { return true }
        }
        return false
    }

    /// The names a new name mustn't take: every mounted volume's but this drive's,
    /// and every drive recorded for a job's destinations and folders but this one.
    public static func takenNames(except uuid: String, jobs: [BackupJob], volumes: VolumeTable) -> [String] {
        var out = volumes.mounted().filter { $0.uuid?.caseInsensitiveCompare(uuid) != .orderedSame }.map(\.name)
        for j in jobs {
            let ids = j.targets.flatMap { [$0.volume].compactMap { $0 } + ($0.otherVolumes ?? []) } + j.libraries.compactMap(\.volume)
            out += ids.filter { !$0.isShare && $0.uuid.caseInsensitiveCompare(uuid) != .orderedSame }.map(\.name)
        }
        return out
    }

    /// the jobs with anything on the drive: a destination or a folder backed up
    static func jobs(on drive: Drive, among jobs: [BackupJob]) -> [BackupJob] {
        jobs.filter { j in
            j.targets.contains { t in
                t.volume?.uuid == drive.uuid || (t.otherVolumes ?? []).contains { $0.uuid == drive.uuid }
                    || DestinationRules.contains(drive.mountPoint, t.destinationDir)
            } || j.libraries.contains { l in
                l.volume?.uuid == drive.uuid || l.paths.contains { DestinationRules.contains(drive.mountPoint, $0.liveURL(home: NSHomeDirectory())) }
            }
        }
    }

    /// Whether `drive` can be renamed `newName` now. Doesn't take any lock: `rename`
    /// checks again holding them. `isQueued`: whether a run of a job (by id) is
    /// waiting to start in this process.
    public static func check(_ drive: Drive, to newName: String, jobs: [BackupJob], locks: RunLocks, pending: [PendingTransfer],
                             isQueued: (String) -> Bool = { _ in false }, volumes: VolumeTable = SystemVolumeTable(),
                             runner: CommandRunner = ProcessCommandRunner(),
                             isOpen: (URL) -> Bool = { LibraryFolders.anyImageAttached(under: $0) }) throws {
        try check(drive, to: newName, jobs: jobs, lockState: locks.look, pending: pending, isQueued: isQueued,
                  volumes: volumes, runner: runner, isOpen: isOpen)
    }

    /// the same, with each job's lock as `lockState` says (held by the rename itself:
    /// free as far as it's concerned)
    static func check(_ drive: Drive, to newName: String, jobs: [BackupJob], lockState: (String) -> RunLocks.Look,
                      pending: [PendingTransfer], isQueued: (String) -> Bool, volumes: VolumeTable,
                      runner: CommandRunner, isOpen: (URL) -> Bool) throws {
        if drive.isInternal { throw Refusal.notExternal(drive.name) }
        if LibraryNames.same(newName, drive.name) { throw Refusal.invalidName("That's the name it has. Choose another one.") }
        if !drive.isWritable { throw Refusal.readOnly(drive.name) }
        if let why = nameProblem(newName, fileSystem: drive.fileSystem) { throw Refusal.invalidName(why) }
        if takenNames(except: drive.uuid, jobs: jobs, volumes: volumes).contains(where: { LibraryNames.same($0, newName) }) {
            throw Refusal.nameTaken(newName)
        }
        for j in Self.jobs(on: drive, among: jobs) {
            if isQueued(j.id) { throw Refusal.inUse("a backup of “\(j.name)” is waiting to start") }
            switch lockState(j.id) {
            case .held(let h): throw Refusal.inUse("for “\(j.name)”, \(h.busyDoing)")
            case .unreadable(let why): throw Refusal.unchecked("whether “\(j.name)” is in use can't be told (\(why))")
            case .free: break
            }
        }
        if pending.contains(where: { p in
            p.volumeUUID.map { $0.caseInsensitiveCompare(drive.uuid) == .orderedSame }
                ?? DestinationRules.contains(drive.mountPoint, URL(fileURLWithPath: p.targetDir))
        }) { throw Refusal.transferPending(drive.name) }
        if isOpen(drive.mountPoint) { throw Refusal.imageAttached(drive.name) }
        switch isTimeMachine(drive, runner: runner) {
        case true?: throw Refusal.timeMachine(drive.name)
        case nil: throw Refusal.unchecked("whether \(drive.name) is a Time Machine drive can't be told")
        case false?: break
        }
    }

    // MARK: the folder, before and after

    /// Every entry under a folder, by its path within it: inode, size and date (a
    /// folder's date moves with Finder's own files in it, so only its inode counts).
    /// Nothing is read.
    public struct Fingerprint: Sendable, Equatable {
        public var entries: [String: String]

        /// what differs from `other`, in words, at most a few
        public func difference(from other: Fingerprint) -> String {
            let keys = Set(entries.keys).union(other.entries.keys).sorted().filter { entries[$0] != other.entries[$0] }
            let shown = keys.prefix(3).map { k in entries[k] == nil ? "\(k) appeared" : other.entries[k] == nil ? "\(k) is gone" : "\(k) changed" }
            return shown.joined(separator: "; ") + (keys.count > 3 ? "; and \(keys.count - 3) more" : "")
        }
    }

    public static func fingerprint(_ dir: URL) -> Fingerprint {
        var out: [String: String] = [:]
        let base = dir.path
        func note(_ path: String, _ rel: String) {
            var st = stat()
            guard lstat(path, &st) == 0 else { return }
            let isDir = (st.st_mode & S_IFMT) == S_IFDIR
            out[rel] = isDir ? "dir \(st.st_ino)" : "\(st.st_ino) \(st.st_size) \(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
        }
        note(base, ".")
        guard let e = FileManager.default.enumerator(atPath: base) else { return Fingerprint(entries: out) }
        while let rel = e.nextObject() as? String {
            if (rel as NSString).lastPathComponent == ".DS_Store" { continue }
            note(base + "/" + rel, rel)
        }
        return Fingerprint(entries: out)
    }

    // MARK: renaming

    /// What `rename` did: the job as saved, and its new destination on the drive.
    public struct Outcome: Sendable, Equatable {
        public var drive: Drive
        public var job: BackupJob
        public var newTarget: Target
    }

    /// Rename the drive `uuid` to `newName`, and change `jobID` to match: its
    /// destination `targetID` keeps its own drive (and stops taking turns at its
    /// folder with this one), and a new destination at the same folder on this drive
    /// takes turns with it. Holds the run lock of every job with anything on the
    /// drive throughout, and checks everything again under them (see `check`).
    ///
    /// `confirmed`: the look (DrivePairing.lookBeforeRenaming) the person saw and
    /// agreed to. It's looked at again, holding the locks: a drive with another job's
    /// backups is refused, and one whose backups the next run changes (see
    /// DrivePairing.changesBackups) needs `confirmed` to say the same. `checks`: the
    /// archive checks recorded, as the look was given them.
    ///
    /// Throws a Refusal: nothing was renamed (or a rename that couldn't be confirmed
    /// was put back), and the job is as it was.
    public static func rename(_ uuid: String, to newName: String, targetID: String, jobID: String, store: JobStore,
                              locks: RunLocks, pending: PendingTransferStore,
                              confirmed: DrivePairing? = nil, checks: [HealthRecord] = [],
                              isQueued: (String) -> Bool = { _ in false },
                              volumes: VolumeTable = SystemVolumeTable(), runner: CommandRunner = ProcessCommandRunner(),
                              isOpen: (URL) -> Bool = { LibraryFolders.anyImageAttached(under: $0) },
                              now: Date = Date()) throws -> Outcome {
        guard let before = drive(uuid, runner: runner) else { throw Refusal.notConnected("The drive") }
        let jobs = store.load().jobs
        guard let job = jobs.first(where: { $0.id == jobID }), let target = job.targets.first(where: { $0.id == targetID }),
              let own = target.volume, own.uuid.caseInsensitiveCompare(uuid) != .orderedSame else {
            throw Refusal.unchecked("the job, or its destination, isn't what it was")
        }
        // the folder on this drive: where the destination's folder is on its own drive
        let relative = (target.otherVolumes ?? []).first { $0.uuid.caseInsensitiveCompare(uuid) == .orderedSame }?.relativePath
            ?? own.relativePath
        // every job with anything on the drive, held for the whole of it
        var leases: [RunLease] = []
        defer { leases.forEach { $0.release() } }
        var holding = Self.jobs(on: before, among: jobs)
        if !holding.contains(where: { $0.id == jobID }) { holding.append(job) }
        for j in holding {
            do { leases.append(try locks.acquire(jobID: j.id, trigger: .cleanup)) }
            catch RunLockError.alreadyRunning(let h) { throw Refusal.inUse("for “\(j.name)”, \(h.busyDoing)") }
            catch { throw Refusal.unchecked(error.localizedDescription) }
        }
        // everything else, again, holding them
        try check(before, to: newName, jobs: jobs, lockState: { _ in .free }, pending: pending.all(), isQueued: isQueued,
                  volumes: volumes, runner: runner, isOpen: isOpen)
        // whose backups are on it, and what the next backup does to them
        guard let look = DrivePairing.lookBeforeRenaming(uuid, target: target, job: job, jobs: jobs, volumes: volumes,
                                                         checks: checks, now: now) else {
            throw Refusal.unchecked("what's on \(before.name) can't be looked at")
        }
        if let why = look.refusal { throw Refusal.notThisJobsDrive(why) }
        if look.changesBackups, confirmed.map({ look.saysTheSame(as: $0) }) != true { throw Refusal.effectNotConfirmed }

        let folder = relative.isEmpty ? before.mountPoint : before.mountPoint.appendingPathComponent(relative, isDirectory: true)
        let print = fingerprint(folder)
        let r: CommandResult
        do { r = try runner.run("/usr/sbin/diskutil", ["rename", before.uuid, newName], stdin: nil) }
        catch { throw Refusal.failed(error.localizedDescription) }
        guard r.ok else {
            throw Refusal.failed((r.stderr.isEmpty ? r.stdout : r.stderr).trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // the same drive, under its new name, and nothing in the folder moved
        func undo(_ why: String) -> Refusal {
            let back = try? runner.run("/usr/sbin/diskutil", ["rename", before.uuid, before.name], stdin: nil)
            return .notConfirmed(back?.ok == true ? why : why + ". Its old name couldn't be put back either: rename it “\(before.name)” in Disk Utility")
        }
        guard let after = drive(uuid, runner: runner) else { throw undo("the drive can't be found by its UUID any more") }
        // FAT keeps a label in its own case: the name counts as it compares everywhere
        guard LibraryNames.same(after.name, newName) else { throw undo("it's called “\(after.name)”, not “\(newName)”") }
        let moved = relative.isEmpty ? after.mountPoint : after.mountPoint.appendingPathComponent(relative, isDirectory: true)
        let now2 = fingerprint(moved)
        guard now2 == print else { throw undo("its backup folder isn't as it was (\(now2.difference(from: print)))") }

        // the job, once: its destination keeps its own drive; a new one on this drive
        // takes turns with it, counted as away only from now
        var saved: Outcome?
        store.update { s in
            guard let j = s.jobs.firstIndex(where: { $0.id == jobID }),
                  let i = s.jobs[j].targets.firstIndex(where: { $0.id == targetID }) else { return }
            var t = s.jobs[j].targets[i]
            let others = (t.otherVolumes ?? []).filter { $0.uuid.caseInsensitiveCompare(uuid) != .orderedSame }
            t.otherVolumes = others.isEmpty ? nil : others
            let group = t.rotation?.group ?? UUID().uuidString
            if t.rotation == nil { t.rotation = Rotation(group: group) }
            var new = DestinationResolver(volumes: volumes).target(for: moved)
            // never in place of one of the job's destinations (the same folder is the same id)
            guard !s.jobs[j].targets.contains(where: { $0.id == new.id }) else { return }
            new.volume = VolumeIdentity(uuid: after.uuid, name: after.name, relativePath: relative)
            new.rotation = Rotation(group: group, maxAwayDays: t.rotation?.maxAwayDays ?? Rotation.defaultMaxAwayDays, addedAt: now)
            s.jobs[j].targets[i] = t
            s.jobs[j].targets.insert(new, at: i + 1)
            // what the look showed the next backup doing to the backups there, said
            // yes to (see AdoptedVersions.swift)
            s.jobs[j] = s.jobs[j].adding(look.consents(targetID: new.id, at: now))
            saved = Outcome(drive: after, job: s.jobs[j], newTarget: new)
        }
        guard let saved else { throw Refusal.renamedJobNotUpdated(newName) }
        return saved
    }
}
