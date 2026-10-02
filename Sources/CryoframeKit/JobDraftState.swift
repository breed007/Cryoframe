//
//  JobDraftState.swift
//  CryoframeKit
//
//  Every rule for building or editing a backup job, as a plain value: the fields,
//  the derived values (deduped destinations, retention and frequency mapping,
//  encryption validity, conflicts), and the job it produces. The app's JobDraft is
//  a thin observable wrapper over this, so the rules can be tested without a UI.
//

import Foundation

public struct JobDraftState: Sendable, Equatable {
    public enum FreqKind: String, CaseIterable, Identifiable, Sendable {
        case daily, everyHours, once, manual
        public var id: String { rawValue }
    }

    /// the remembered choices a new job starts from (the app reads them from its
    /// preferences). nil means "use the built-in default".
    public struct Defaults: Sendable, Equatable {
        public var formatKind: String?
        public var verification: String?
        public var runPolicy: String?
        public init(formatKind: String? = nil, verification: String? = nil, runPolicy: String? = nil) {
            self.formatKind = formatKind; self.verification = verification; self.runPolicy = runPolicy
        }
    }

    public var name = ""
    public var libraries: [ContentType] = []
    public var selectedLibraryIDs: Set<String> = []
    public var targets: [Target] = []
    public var selectedTargetIDs: [String] = []        // ordered; first is primary

    public var formatKind = "mirror"                   // "mirror" | "plain" | "zip" | "dmg"

    public var verification: VerificationPolicy = .checksumOnly
    public var runPolicy: RunPolicy = .proceed
    public var encrypt = false
    public var passphrase = ""
    public var passphraseConfirm = ""

    // Bounded by default. "Keep every version" meant a sealed job grew until the
    // destination filled and every run after that failed — while the app promised
    // retention was what kept the disk from filling. Keeping every version is still
    // one choice away; it is just no longer the one you get without deciding.
    public var retentionKind = "lastN"                 // all | lastN | gfs
    public var keepN = 7
    public var gfsDaily = 7
    public var gfsWeekly = 4
    public var gfsMonthly = 6

    public var freqKind = FreqKind.daily
    public var dailyTime: Date
    public var everyHours = 24
    public var onceDate: Date

    // edit context
    /// the job as it was when the editor opened (nil for a new job): what Save merges
    /// against (see JobEdit)
    public let base: BackupJob?
    /// the id the job has, or will have once saved: fixed now, so what the editor
    /// shows of the folders a run makes (their names come from the id) is what the
    /// first run makes
    public let jobID: String
    public let editingID: String?
    public let editingEncrypted: Bool
    public let editingMirrorGB: Int?     // the size an existing mirror job recorded (see FormatChoice.liveMirror)
    /// the format of the job being edited (nil for a new job)
    public let editingFormat: FormatChoice?
    public let editingEnabled: Bool
    public let editingCreatedAt: Date?
    public var isEditing: Bool { editingID != nil }

    /// a draft for a new job, or for editing `editing`. `libraries` and `targets` are
    /// the choices on offer; an edited job's own libraries and targets are added to
    /// them if missing.
    public init(editing: BackupJob? = nil, libraries: [ContentType], targets: [Target],
                defaults: Defaults = Defaults(), now: Date = Date(), calendar: Calendar = .current,
                newID: String = UUID().uuidString) {
        base = editing
        jobID = editing?.id ?? newID
        editingID = editing?.id
        editingEncrypted = editing?.encrypted ?? false
        if case .liveMirror(let g)? = editing?.format { editingMirrorGB = g } else { editingMirrorGB = nil }
        editingFormat = editing?.format
        editingEnabled = editing?.enabled ?? true
        editingCreatedAt = editing?.createdAt
        dailyTime = calendar.date(bySettingHour: 2, minute: 0, second: 0, of: now) ?? now
        onceDate = now.addingTimeInterval(3600)
        self.libraries = libraries
        self.targets = targets
        if let job = editing { seed(from: job, calendar: calendar, now: now) } else { seed(defaults) }
    }

    // MARK: derived

    /// There is no mirror size to choose: the image is sized from its destination. A
    /// job keeps the size it recorded, so an older version reading it still works.
    public var format: FormatChoice {
        switch formatKind {
        case "dmg": .sealedDMG
        case "zip": .sealedZip
        case "plain": .plainFiles
        default: .liveMirror(sizeGB: editingMirrorGB ?? FormatChoice.legacyMirrorGB)
        }
    }
    public var isSealed: Bool { formatKind == "dmg" || formatKind == "zip" }
    public var isPlainFiles: Bool { formatKind == "plain" }
    public var selectedLibraries: [ContentType] { libraries.filter { selectedLibraryIDs.contains($0.id) } }
    public var selectedTargets: [Target] { selectedTargetIDs.compactMap { id in targets.first { $0.id == id } } }
    public var primaryTarget: Target? { dedupedTargets.first }

    /// selected destinations with duplicates-by-path collapsed (a phantom-copy guard).
    public var dedupedTargets: [Target] {
        var seen = Set<String>(), out: [Target] = []
        for t in selectedTargets where seen.insert(t.destinationDir.path).inserted { out.append(t) }
        return out
    }
    public var hasDuplicateDestinations: Bool { dedupedTargets.count != selectedTargets.count }

    public var retentionPolicy: RetentionPolicy {
        switch retentionKind {
        case "lastN": return .keepLast(max(1, keepN))
        // an individual bucket at zero is a real preference ("no monthlies"); all
        // three at zero is a setting that means "keep nothing", which is not a
        // retention policy. retentionPrune refuses to act on it either way — this
        // just stops the UI expressing it.
        case "gfs":
            let (d, w, m) = (max(0, gfsDaily), max(0, gfsWeekly), max(0, gfsMonthly))
            return d + w + m == 0 ? .keepLast(1) : .gfs(daily: d, weekly: w, monthly: m)
        default:      return .keepAll
        }
    }

    public func frequency(calendar: Calendar = .current) -> BackupFrequency {
        switch freqKind {
        case .daily:
            let c = calendar.dateComponents([.hour, .minute], from: dailyTime)
            return .daily(hour: c.hour ?? 2, minute: c.minute ?? 0)
        case .everyHours: return .everyHours(everyHours)
        case .once:       return .oneTime(onceDate)
        case .manual:     return .manual
        }
    }
    public var frequency: BackupFrequency { frequency() }

    /// Encryption and the passphrase are fixed once a job exists. Turning encryption on
    /// left an existing mirror image in plaintext while the manifest said encrypted; a
    /// new passphrase replaced the only stored key, so the mirror and every earlier
    /// version stopped opening; turning it off deleted that key. Changing keys needs a
    /// key history. Until then: create a new job.
    public var encryptionLocked: Bool { isEditing }

    /// a new encrypted job needs a passphrase, entered twice and matching.
    public var encryptionValid: Bool {
        if encryptionLocked { return true }
        guard encrypt else { return true }
        return !passphrase.isEmpty && passphrase == passphraseConfirm
    }

    /// Two sealed jobs writing the same library to the same folder share version
    /// folders and cross-prune each other, so this blocks the combination. Compared
    /// on canonical paths and case-insensitively: /Volumes/D/Backups and
    /// /Volumes/d/backups are the SAME directory on case-insensitive APFS, and a raw
    /// string compare let that pair through into exactly the data loss this prevents.
    static func samePlace(_ a: URL, _ b: URL) -> Bool {
        TMUtilSnapshotBackend.canonicalPath(a.resolvingSymlinksInPath().path)
            .compare(TMUtilSnapshotBackend.canonicalPath(b.resolvingSymlinksInPath().path),
                     options: .caseInsensitive) == .orderedSame
    }

    /// Two mirror jobs writing the same library to the same folder share one image the
    /// same way, and each run's --delete erases the other's copy, so mirrors are held
    /// to the same rule. A sealed job and a mirror job may share a folder: their files
    /// don't overlap. `existing` is every saved job; the one being edited is skipped.
    public func destinationConflicts(existing: [BackupJob]) -> [String] {
        var out = Set<String>()
        for job in existing where job.id != editingID && job.format.isSealed == isSealed && job.format.isPlainFiles == isPlainFiles {
            for t in selectedTargets where job.targets.contains(where: { Self.samePlace($0.destinationDir, t.destinationDir) }) {
                for lib in selectedLibraries where job.libraries.contains(where: { LibraryNames.same($0.displayName, lib.displayName) }) {
                    let what = isSealed ? "dated versions" : isPlainFiles ? "plain files" : "an up-to-date copy"
                    out.insert("“\(job.name)” already keeps \(what) of \(lib.displayName) at \(t.displayName)")
                }
            }
        }
        return out.sorted()
    }

    /// libraries in THIS job with one name: allowed, with a note (see LibraryNames)
    public var libraryNameClashes: [String] { LibraryNames.clashMessages(selectedLibraries) }

    /// Each chosen library against each chosen destination, by path alone: a
    /// destination inside a library backs up its own backups; a library inside a
    /// destination is copied into itself. Checked on every save, so a library chosen
    /// after the destinations can't slip one through, and a destination whose drive
    /// is away doesn't stop the save (see DestinationRules.pathIssues).
    public func pathIssues(home: String = NSHomeDirectory()) -> [String] {
        var out: [String] = []
        let roots = selectedLibraries.flatMap { $0.paths.map { $0.liveURL(home: home) } }
        for t in dedupedTargets {
            for issue in DestinationRules.pathIssues(t.destinationDir, sources: roots) where !out.contains(issue.message) {
                out.append(issue.message)
            }
        }
        return out
    }

    public func isValid(existing: [BackupJob], home: String = NSHomeDirectory(),
                        profile: (Target) -> FileSystemProfile = { FileSystemProfile.of($0.destinationDir, target: $0) }) -> Bool {
        !selectedLibraries.isEmpty && !dedupedTargets.isEmpty && encryptionValid
            && destinationConflicts(existing: existing).isEmpty && pathIssues(home: home).isEmpty
            && plainFilesIssues(profile: profile).isEmpty
    }

    // MARK: plain files

    /// The format is chosen when a job is made. A plain-files job is kept apart from
    /// the others (see JobStore) and its folder holds files, not a disk image or
    /// versions, so neither becomes the other.
    public var formatLocked: Bool { editingFormat?.isPlainFiles == true }

    /// plain files are offered for a new job only (see formatLocked)
    public var plainFilesOffered: Bool { !isEditing }

    /// An app's library (Photos, Music…) kept as plain files on a drive that can't
    /// hold it as its app needs (see FileSystemProfile.refusal): each, with why.
    public func plainFilesIssues(profile: (Target) -> FileSystemProfile = { FileSystemProfile.of($0.destinationDir, target: $0) }) -> [String] {
        guard isPlainFiles else { return [] }
        var out: [String] = []
        for t in dedupedTargets {
            let p = profile(t)
            for lib in selectedLibraries where lib.kind == .liveDB {
                if let why = p.refusal(appLibrary: lib.owningProcess?.displayName ?? lib.displayName), !out.contains(why) { out.append(why) }
            }
        }
        return out
    }

    /// What plain files mean, said once in the editor and in what saving does:
    /// unencrypted (unless every destination is an encrypted drive), and what is
    /// deleted from a library kept, with where to delete it. Messages are named only
    /// when the job backs them up.
    public func plainFilesNotice(encrypted: (Target) -> Bool = { MediaExportDrive.of($0.destinationDir).encrypted }) -> String? {
        guard isPlainFiles else { return nil }
        return Self.plainFilesNotice(libraries: selectedLibraries, encrypted: !dedupedTargets.isEmpty && dedupedTargets.allSatisfy(encrypted))
    }

    public static func plainFilesNotice(libraries: [ContentType], encrypted: Bool) -> String {
        let messages = libraries.contains { $0.id.hasPrefix("com.apple.messages") }
        let open = encrypted ? "" : "Plain files aren't encrypted: anyone with the drive can open them"
            + (messages ? ", including photos and files from your messages. " : ". ")
        return open + "What you delete from a library is kept in Removed items beside its copy, until you delete it in Storage."
    }

    public var defaultName: String {
        let names = selectedLibraries.map(\.displayName)
        let lib = names.isEmpty ? "Libraries" : (names.count <= 2 ? names.joined(separator: ", ") : "\(names.count) libraries")
        let dest = primaryTarget?.displayName ?? "Destination"
        let suffix = dedupedTargets.count > 1 ? " +\(dedupedTargets.count - 1)" : ""
        return "\(lib) → \(dest)\(suffix)"
    }

    /// whether saving this draft should store `passphrase` as the job's key. Only a
    /// new encrypted job sets a key; an existing job keeps its key exactly as it is.
    public var storesNewPassphrase: Bool { !encryptionLocked && encrypt && !passphrase.isEmpty }

    /// the job this draft saves as
    public func makeJob(now: Date = Date(), calendar: Calendar = .current) -> BackupJob {
        makeJob(id: jobID, now: now, calendar: calendar)
    }

    /// the job this draft saves as, under `id`
    public func makeJob(id: String, now: Date = Date(), calendar: Calendar = .current) -> BackupJob {
        // an existing job keeps its encryption exactly as it is (see encryptionLocked);
        // only a new job sets it
        let encrypted = isPlainFiles ? false : encryptionLocked ? editingEncrypted : encrypt
        // a rotation needs two drives: one whose partners are on offer but weren't
        // chosen is a destination of its own (one saved alone is left as it was)
        var targets = dedupedTargets
        for i in targets.indices {
            guard let g = targets[i].rotation?.group else { continue }
            if targets.filter({ $0.rotation?.group == g }).count < 2,
               self.targets.filter({ $0.rotation?.group == g }).count >= 2 { targets[i].rotation = nil }
        }
        return BackupJob(id: id, name: name.isEmpty ? defaultName : name,
                         libraries: selectedLibraries, targets: targets, format: format,
                         frequency: frequency(calendar: calendar), verification: verification, runPolicy: runPolicy,
                         enabled: editingEnabled, encrypted: encrypted,
                         retention: isSealed ? retentionPolicy : .keepAll,
                         createdAt: editingCreatedAt ?? now)
    }

    // MARK: mutators

    public mutating func toggleLibrary(_ id: String) {
        if selectedLibraryIDs.contains(id) { selectedLibraryIDs.remove(id) } else { selectedLibraryIDs.insert(id) }
    }
    public mutating func toggleTarget(_ id: String) {
        if selectedTargetIDs.contains(id) { selectedTargetIDs.removeAll { $0 == id } } else { selectedTargetIDs.append(id) }
    }

    /// add a library to the list on offer, replacing any with the same id, and select it.
    public mutating func addLibrary(_ ct: ContentType) {
        libraries.removeAll { $0.id == ct.id }
        libraries.append(ct)
        selectedLibraryIDs.insert(ct.id)
    }

    /// Rename a library in this job only (a built-in keeps its name in every other
    /// job). Its folders at the job's destinations follow at the next run that
    /// reaches each; one whose drive is away keeps its name until then, and is still
    /// known by it (see ContentType.formerNames). False for an empty name.
    @discardableResult
    public mutating func renameLibrary(_ id: String, to name: String) -> Bool {
        guard let i = libraries.firstIndex(where: { $0.id == id }) else { return false }
        return libraries[i].rename(to: name)
    }

    /// re-read the built-in library list (after a location edit) while keeping added
    /// ones, and the edited job's own name for each of its libraries
    public mutating func replaceBuiltInLibraries(_ builtins: [ContentType]) {
        let ids = Set(builtins.map(\.id))
        let current = libraries
        libraries = builtins.map { b in current.first { $0.id == b.id }.map { $0.resolved(with: b) } ?? b }
            + current.filter { !ids.contains($0.id) }
    }

    /// add a destination to the list on offer, replacing any with the same id, and select it.
    public mutating func addTarget(_ t: Target) {
        targets.removeAll { $0.id == t.id }; targets.append(t)
        if !selectedTargetIDs.contains(t.id) { selectedTargetIDs.append(t.id) }
    }

    /// Add `target`, a place just chosen, as a destination, if it passes every rule
    /// for one (see DestinationRules.check) against the chosen libraries. What's wrong
    /// or worth knowing about it, either way; nothing is added when anything is refused.
    @discardableResult
    public mutating func addDestination(_ target: Target, volumes: VolumeTable = SystemVolumeTable(),
                                        home: String = NSHomeDirectory(),
                                        systemRoots: [String] = DestinationRules.systemRoots) -> [PlaceIssue] {
        let roots = selectedLibraries.flatMap { $0.paths.map { $0.liveURL(home: home) } }
        let issues = DestinationRules.check(target.destinationDir, sources: roots, volumes: volumes, home: home,
                                            systemRoots: systemRoots)
        if !issues.contains(where: { $0.severity == .refusal }) { addTarget(target) }
        return issues
    }

    /// Add `library`, a folder just chosen at `folder`, to back up, if it passes every
    /// rule for one (see SourceRules.check) against the chosen destinations. What's
    /// wrong or worth knowing about it, either way; nothing is added when anything is
    /// refused.
    @discardableResult
    public mutating func addSource(_ library: ContentType, at folder: URL, home: String = NSHomeDirectory(),
                                   systemRoots: [String] = SourceRules.systemRoots) -> [PlaceIssue] {
        let issues = SourceRules.check(folder, destinations: dedupedTargets.map(\.destinationDir), home: home,
                                       systemRoots: systemRoots)
        if !issues.contains(where: { $0.severity == .refusal }) { addLibrary(library) }
        return issues
    }

    // MARK: destinations: the main one, taking turns, the drives one is on

    /// Make `id` the main destination: the one a run must reach.
    public mutating func makeMain(_ id: String) {
        guard selectedTargetIDs.contains(id) else { return }
        selectedTargetIDs.removeAll { $0 == id }
        selectedTargetIDs.insert(id, at: 0)
    }

    /// the other destinations `id` takes turns with (see Rotation)
    public func takesTurns(_ id: String) -> [Target] {
        guard let g = targets.first(where: { $0.id == id })?.rotation?.group else { return [] }
        return selectedTargets.filter { $0.id != id && $0.rotation?.group == g }
    }

    /// Have `id` take turns with `other`: one place the backups go, written to
    /// whichever of its drives is connected (see Rotation). One joining a rotation is
    /// counted as away from `now`, not from before it joined.
    public mutating func takeTurns(_ id: String, with other: String, now: Date = Date()) {
        guard id != other, selectedTargetIDs.contains(id), selectedTargetIDs.contains(other),
              let a = targets.firstIndex(where: { $0.id == id }), let b = targets.firstIndex(where: { $0.id == other }) else { return }
        let group = targets[b].rotation?.group ?? targets[a].rotation?.group ?? UUID().uuidString
        if targets[a].rotation?.group != group {
            leaveRotation(a)
            targets[a].rotation = Rotation(group: group, addedAt: now)
        }
        if targets[b].rotation == nil { targets[b].rotation = Rotation(group: group, addedAt: now) }
    }

    /// `id` stops taking turns: a destination of its own again. A rotation left with
    /// one drive is no rotation.
    public mutating func stopTakingTurns(_ id: String) {
        guard let i = targets.firstIndex(where: { $0.id == id }) else { return }
        leaveRotation(i)
    }

    private mutating func leaveRotation(_ i: Int) {
        guard let g = targets[i].rotation?.group else { return }
        targets[i].rotation = nil
        let left = targets.indices.filter { targets[$0].rotation?.group == g }
        if left.count == 1 { targets[left[0]].rotation = nil }
    }

    /// Record `drive` as another drive `id` is on, taking turns at its folder under one
    /// name, as 1.5 did (see Target.otherVolumes, DrivePairing). Only for a destination
    /// whose own drive is known. Saved with the job; Cancel forgets it.
    @discardableResult
    public mutating func pair(_ id: String, with drive: VolumeIdentity) -> Bool {
        guard let i = targets.firstIndex(where: { $0.id == id }), let own = targets[i].volume, !own.isShare, !drive.isShare,
              own.uuid != drive.uuid else { return false }
        var others = targets[i].otherVolumes ?? []
        if !others.contains(where: { $0.uuid == drive.uuid }) { others.append(drive) }
        targets[i].otherVolumes = others
        return true
    }

    /// The same, from what DrivePairing.look showed: never a drive it refused (one
    /// holding another job's backups), whatever the view offers.
    @discardableResult
    public mutating func pair(_ id: String, as look: DrivePairing) -> Bool {
        guard look.refusal == nil else { return false }
        return pair(id, with: look.drive)
    }

    /// `id` stops taking turns with the drive `uuid` at its folder.
    public mutating func unpair(_ id: String, uuid: String) {
        guard let i = targets.firstIndex(where: { $0.id == id }) else { return }
        let others = (targets[i].otherVolumes ?? []).filter { $0.uuid != uuid }
        targets[i].otherVolumes = others.isEmpty ? nil : others
    }

    /// Take one destination off the list on offer (and out of the selection). One of
    /// the edited job's own stays: taking it off the list would take it out of the job
    /// without saying so. Only this entry goes: the list used to be read back whole
    /// from the app's remembered destinations, which dropped every destination only
    /// this job had.
    public mutating func removeFromOffer(_ id: String) {
        guard base?.targets.contains(where: { $0.id == id }) != true else { return }
        targets.removeAll { $0.id == id }
        selectedTargetIDs.removeAll { $0 == id }
    }

    // MARK: saving

    public enum CommitResult: Sendable, Equatable {
        case saved(BackupJob)
        /// the draft can't be saved as it is (see isValid), now that the saved jobs
        /// were read again
        case invalid
        /// the job was deleted while it was being edited: nothing was saved
        case deleted
    }

    /// Save the draft into `store`, merged with the job as it is on disk now (see
    /// JobEdit), all under the store's lock. A new encrypted job's passphrase is
    /// handed to `savePassphrase` (passphrase, job id) first, so no job is ever
    /// saved without its key.
    /// `consents`: the go-ahead the save summary asked for (see JobEditImpact.consents),
    /// recorded with the job.
    public func commit(to store: JobStore, now: Date = Date(), calendar: Calendar = .current,
                       home: String = NSHomeDirectory(), consents: [AdoptionConsent] = [],
                       savePassphrase: (String, String) -> Void) -> CommitResult {
        guard isValid(existing: store.load().jobs, home: home) else { return .invalid }
        if storesNewPassphrase { savePassphrase(passphrase, jobID) }
        let draft = makeJob(now: now, calendar: calendar)
        return store.update { s -> CommitResult in
            guard isValid(existing: s.jobs, home: home) else { return .invalid }
            let stored = s.jobs.first { $0.id == jobID }
            guard let job = JobEdit.merge(draft: draft, base: base, stored: stored)?.adding(consents) else { return .deleted }
            if let i = s.jobs.firstIndex(where: { $0.id == jobID }) { s.jobs[i] = job } else { s.jobs.append(job) }
            // a dashboard review this save answered, or counted under a Keep rule the job
            // no longer has, is gone: the next backup asks again if there's anything to ask
            let reviews = (s.adoptionReviews[jobID] ?? []).filter { r in
                r.rule == job.retention && !consents.contains { $0.targetID == r.targetID && $0.libraryID == r.libraryID }
            }
            s.adoptionReviews[jobID] = reviews.isEmpty ? nil : reviews
            return .saved(job)
        }
    }

    // MARK: seeding

    private mutating func seed(_ d: Defaults) {
        selectedTargetIDs = targets.first.map { [$0.id] } ?? []
        formatKind = d.formatKind ?? "mirror"
        if let v = d.verification, let p = VerificationPolicy(rawValue: v) { verification = p }
        if let r = d.runPolicy, let p = RunPolicy(rawValue: r) { runPolicy = p }
    }

    private mutating func seed(from job: BackupJob, calendar: Calendar, now: Date) {
        name = job.name
        // The job's own libraries and destinations, not the copies on offer with the
        // same ids: the list of remembered destinations knows nothing of the drives a
        // run recorded, and saving its copy erased them. A built-in library takes its
        // folder from the list on offer (it may have been moved since), and keeps the
        // job's name for it.
        for lib in job.libraries {
            if let i = libraries.firstIndex(where: { $0.id == lib.id }) { libraries[i] = lib.resolved(with: libraries[i]) }
            else { libraries.append(lib) }
        }
        selectedLibraryIDs = Set(job.libraries.map(\.id))
        for t in job.targets {
            if let i = targets.firstIndex(where: { $0.id == t.id }) { targets[i] = t } else { targets.append(t) }
        }
        selectedTargetIDs = job.targets.map(\.id)
        switch job.format {
        case .sealedDMG: formatKind = "dmg"
        case .sealedZip: formatKind = "zip"
        case .liveMirror:
            formatKind = "mirror"
        case .plainFiles:
            formatKind = "plain"
        }
        verification = job.verification; runPolicy = job.runPolicy; encrypt = job.encrypted
        switch job.retention {
        case .keepAll: retentionKind = "all"
        case .keepLast(let n): retentionKind = "lastN"; keepN = n
        case .gfs(let d, let w, let m): retentionKind = "gfs"; gfsDaily = d; gfsWeekly = w; gfsMonthly = m
        }
        switch job.frequency {
        case .daily(let h, let m): freqKind = .daily; dailyTime = calendar.date(bySettingHour: h, minute: m, second: 0, of: now) ?? now
        case .everyHours(let h): freqKind = .everyHours; everyHours = h
        case .oneTime(let date): freqKind = .once; onceDate = date
        case .manual: freqKind = .manual
        }
    }
}
