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
        public var mirrorValue: Int?
        public var mirrorUnit: String?
        public var formatKind: String?
        public var verification: String?
        public var runPolicy: String?
        public init(mirrorValue: Int? = nil, mirrorUnit: String? = nil, formatKind: String? = nil,
                    verification: String? = nil, runPolicy: String? = nil) {
            self.mirrorValue = mirrorValue; self.mirrorUnit = mirrorUnit; self.formatKind = formatKind
            self.verification = verification; self.runPolicy = runPolicy
        }
    }

    public var name = ""
    public var libraries: [ContentType] = []
    public var selectedLibraryIDs: Set<String> = []
    public var targets: [Target] = []
    public var selectedTargetIDs: [String] = []        // ordered; first is primary

    public var formatKind = "mirror"                   // "mirror" | "zip" | "dmg"
    public var mirrorValue = 500
    public var mirrorUnit = "GB"

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
    public let editingID: String?
    public let editingEncrypted: Bool
    public let editingMirrorGB: Int?     // the size the existing mirror image was made at
    public let editingEnabled: Bool
    public let editingCreatedAt: Date?
    public var isEditing: Bool { editingID != nil }

    /// a draft for a new job, or for editing `editing`. `libraries` and `targets` are
    /// the choices on offer; an edited job's own libraries and targets are added to
    /// them if missing.
    public init(editing: BackupJob? = nil, libraries: [ContentType], targets: [Target],
                defaults: Defaults = Defaults(), now: Date = Date(), calendar: Calendar = .current) {
        editingID = editing?.id
        editingEncrypted = editing?.encrypted ?? false
        if case .liveMirror(let g)? = editing?.format { editingMirrorGB = g } else { editingMirrorGB = nil }
        editingEnabled = editing?.enabled ?? true
        editingCreatedAt = editing?.createdAt
        dailyTime = calendar.date(bySettingHour: 2, minute: 0, second: 0, of: now) ?? now
        onceDate = now.addingTimeInterval(3600)
        self.libraries = libraries
        self.targets = targets
        if let job = editing { seed(from: job, calendar: calendar, now: now) } else { seed(defaults) }
    }

    // MARK: derived

    public var mirrorGB: Int { mirrorUnit == "TB" ? mirrorValue * 1000 : mirrorValue }
    public var format: FormatChoice {
        switch formatKind { case "dmg": .sealedDMG; case "zip": .sealedZip; default: .liveMirror(sizeGB: mirrorGB) }
    }
    public var isSealed: Bool { formatKind != "mirror" }
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

    /// A mirror image can be grown in place on its next run but not shrunk.
    public var mirrorShrinkRequested: Bool {
        guard isEditing, formatKind == "mirror", let was = editingMirrorGB else { return false }
        return mirrorGB < was
    }
    public var editingMirrorSizeText: String? {
        editingMirrorGB.map { $0 >= 1000 && $0 % 1000 == 0 ? "\($0 / 1000) TB" : "\($0) GB" }
    }

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
        for job in existing where job.id != editingID && job.format.isSealed == isSealed {
            for t in selectedTargets where job.targets.contains(where: { Self.samePlace($0.destinationDir, t.destinationDir) }) {
                for lib in selectedLibraries where job.libraries.contains(where: { LibraryNames.same($0.displayName, lib.displayName) }) {
                    out.insert("“\(job.name)” already \(isSealed ? "archives" : "mirrors") \(lib.displayName) to \(t.displayName)")
                }
            }
        }
        return out.sorted()
    }

    /// libraries in THIS job that would share an archive folder (see LibraryNames).
    public var libraryNameClashes: [String] { LibraryNames.clashMessages(selectedLibraries) }

    public func isValid(existing: [BackupJob]) -> Bool {
        !selectedLibraries.isEmpty && !dedupedTargets.isEmpty && encryptionValid
            && destinationConflicts(existing: existing).isEmpty
            && libraryNameClashes.isEmpty && !mirrorShrinkRequested
    }

    public var defaultName: String {
        let names = selectedLibraries.map(\.displayName)
        let lib = names.isEmpty ? "Libraries" : (names.count <= 2 ? names.joined(separator: ", ") : "\(names.count) libraries")
        let dest = primaryTarget?.displayName ?? "Target"
        let suffix = dedupedTargets.count > 1 ? " +\(dedupedTargets.count - 1)" : ""
        return "\(lib) → \(dest)\(suffix)"
    }

    /// whether saving this draft should store `passphrase` as the job's key. Only a
    /// new encrypted job sets a key; an existing job keeps its key exactly as it is.
    public var storesNewPassphrase: Bool { !encryptionLocked && encrypt && !passphrase.isEmpty }

    /// the job this draft saves as. `id` is the edited job's id, or a new one.
    public func makeJob(id: String, now: Date = Date(), calendar: Calendar = .current) -> BackupJob {
        // an existing job keeps its encryption exactly as it is (see encryptionLocked);
        // only a new job sets it
        let encrypted = encryptionLocked ? editingEncrypted : encrypt
        return BackupJob(id: id, name: name.isEmpty ? defaultName : name,
                         libraries: selectedLibraries, targets: dedupedTargets, format: format,
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

    /// re-read the built-in library list (after a location edit) while keeping added ones.
    public mutating func replaceBuiltInLibraries(_ builtins: [ContentType]) {
        let ids = Set(builtins.map(\.id))
        libraries = builtins + libraries.filter { !ids.contains($0.id) }
    }

    /// add a destination to the list on offer, replacing any with the same id, and select it.
    public mutating func addTarget(_ t: Target) {
        targets.removeAll { $0.id == t.id }; targets.append(t)
        if !selectedTargetIDs.contains(t.id) { selectedTargetIDs.append(t.id) }
    }

    // MARK: seeding

    private mutating func seed(_ d: Defaults) {
        selectedTargetIDs = targets.first.map { [$0.id] } ?? []
        if let v = d.mirrorValue, v > 0 { mirrorValue = v }
        if let u = d.mirrorUnit { mirrorUnit = u }
        formatKind = d.formatKind ?? "mirror"
        if let v = d.verification, let p = VerificationPolicy(rawValue: v) { verification = p }
        if let r = d.runPolicy, let p = RunPolicy(rawValue: r) { runPolicy = p }
    }

    private mutating func seed(from job: BackupJob, calendar: Calendar, now: Date) {
        name = job.name
        for lib in job.libraries where !libraries.contains(where: { $0.id == lib.id }) { libraries.append(lib) }
        selectedLibraryIDs = Set(job.libraries.map(\.id))
        for t in job.targets where !targets.contains(where: { $0.id == t.id }) { targets.append(t) }
        selectedTargetIDs = job.targets.map(\.id)
        switch job.format {
        case .sealedDMG: formatKind = "dmg"
        case .sealedZip: formatKind = "zip"
        case .liveMirror(let g):
            formatKind = "mirror"
            if g >= 1000, g % 1000 == 0 { mirrorValue = g / 1000; mirrorUnit = "TB" } else { mirrorValue = g; mirrorUnit = "GB" }
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
