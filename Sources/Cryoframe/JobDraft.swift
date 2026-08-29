//
//  JobDraft.swift
//  Cryoframe (app)
//
//  The single source of truth for building a backup job — shared by the guided wizard
//  (new jobs) and the full sheet (editing). Owns every field, the derived values
//  (deduped destinations, retention/frequency, encryption validity, conflicts), and the
//  commit path (Keychain + save). Neither view reimplements this; they only render it.
//

import SwiftUI
import AppKit
import CryoframeKit

@MainActor
final class JobDraft: ObservableObject {
    let model: AppModel

    @Published var name = ""
    @Published var libraries: [ContentType] = []
    @Published var selectedLibraryIDs: Set<String> = []
    @Published var targets: [Target] = []
    @Published var selectedTargetIDs: [String] = []        // ordered; first is primary

    @Published var formatKind = "mirror"                   // "mirror" | "zip" | "dmg"
    @Published var mirrorValue = 500
    @Published var mirrorUnit = "GB"

    @Published var verification: VerificationPolicy = .checksumOnly
    @Published var runPolicy: RunPolicy = .proceed
    @Published var encrypt = false
    @Published var passphrase = ""
    @Published var passphraseConfirm = ""

    // Bounded by default. "Keep every version" meant a sealed job grew until the
    // destination filled and every run after that failed — while the app promised
    // retention was what kept the disk from filling. Keeping every version is still
    // one choice away; it is just no longer the one you get without deciding.
    @Published var retentionKind = "lastN"                 // all | lastN | gfs
    @Published var keepN = 7
    @Published var gfsDaily = 7
    @Published var gfsWeekly = 4
    @Published var gfsMonthly = 6

    @Published var freqKind = FreqKind.daily
    @Published var dailyTime = Calendar.current.date(bySettingHour: 2, minute: 0, second: 0, of: Date()) ?? Date()
    @Published var everyHours = 24
    @Published var onceDate = Date().addingTimeInterval(3600)

    enum FreqKind: String, CaseIterable, Identifiable { case daily, everyHours, once, manual; var id: String { rawValue } }

    // edit context
    let editingID: String?
    private let editingEncrypted: Bool
    private let editingEnabled: Bool
    private let editingCreatedAt: Date?
    var isEditing: Bool { editingID != nil }

    init(model: AppModel, editing: BackupJob? = nil) {
        self.model = model
        editingID = editing?.id
        editingEncrypted = editing?.encrypted ?? false
        editingEnabled = editing?.enabled ?? true
        editingCreatedAt = editing?.createdAt
        libraries = model.registry.types
        targets = model.targets
        if let job = editing { seedFrom(job) } else { seedDefaults() }
    }

    // MARK: derived

    var mirrorGB: Int { mirrorUnit == "TB" ? mirrorValue * 1000 : mirrorValue }
    var format: FormatChoice {
        switch formatKind { case "dmg": .sealedDMG; case "zip": .sealedZip; default: .liveMirror(sizeGB: mirrorGB) }
    }
    var isSealed: Bool { formatKind != "mirror" }
    var selectedLibraries: [ContentType] { libraries.filter { selectedLibraryIDs.contains($0.id) } }
    var selectedTargets: [Target] { selectedTargetIDs.compactMap { id in targets.first { $0.id == id } } }
    var primaryTarget: Target? { dedupedTargets.first }

    /// selected destinations with duplicates-by-path collapsed (a phantom-copy guard).
    var dedupedTargets: [Target] {
        var seen = Set<String>(), out: [Target] = []
        for t in selectedTargets where seen.insert(t.destinationDir.path).inserted { out.append(t) }
        return out
    }
    var hasDuplicateDestinations: Bool { dedupedTargets.count != selectedTargets.count }

    var retentionPolicy: RetentionPolicy {
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

    var frequency: BackupFrequency {
        switch freqKind {
        case .daily:
            let c = Calendar.current.dateComponents([.hour, .minute], from: dailyTime)
            return .daily(hour: c.hour ?? 2, minute: c.minute ?? 0)
        case .everyHours: return .everyHours(everyHours)
        case .once:       return .oneTime(onceDate)
        case .manual:     return .manual
        }
    }

    /// when encrypting, a new passphrase must be entered and confirmed — unless editing an
    /// already-encrypted job and leaving the fields blank to keep the stored one.
    var encryptionValid: Bool {
        guard encrypt else { return true }
        if passphrase.isEmpty, passphraseConfirm.isEmpty,
           let id = editingID, editingEncrypted, KeychainArchiveKey.exists(jobID: id) { return true }
        return !passphrase.isEmpty && passphrase == passphraseConfirm
    }

    /// another sealed job already archiving the same library to the same destination —
    /// they'd share version folders and cross-prune. Blocks create.
    /// Two sealed jobs writing the same library to the same folder share version
    /// folders and cross-prune each other, so this blocks the combination. Compared
    /// on canonical paths and case-insensitively: /Volumes/D/Backups and
    /// /Volumes/d/backups are the SAME directory on case-insensitive APFS, and a raw
    /// string compare let that pair through into exactly the data loss this prevents.
    private static func samePlace(_ a: URL, _ b: URL) -> Bool {
        TMUtilSnapshotBackend.canonicalPath(a.resolvingSymlinksInPath().path)
            .compare(TMUtilSnapshotBackend.canonicalPath(b.resolvingSymlinksInPath().path),
                     options: .caseInsensitive) == .orderedSame
    }

    var destinationConflicts: [String] {
        guard isSealed else { return [] }
        var out = Set<String>()
        for job in model.jobs where job.id != editingID && job.format.isSealed {
            for t in selectedTargets where job.targets.contains(where: { Self.samePlace($0.destinationDir, t.destinationDir) }) {
                for lib in selectedLibraries where job.libraries.contains(where: { $0.displayName == lib.displayName }) {
                    out.insert("“\(job.name)” already archives \(lib.displayName) to \(t.displayName)")
                }
            }
        }
        return out.sorted()
    }

    var isValid: Bool { !selectedLibraries.isEmpty && !dedupedTargets.isEmpty && encryptionValid && destinationConflicts.isEmpty }

    var defaultName: String {
        let names = selectedLibraries.map(\.displayName)
        let lib = names.isEmpty ? "Libraries" : (names.count <= 2 ? names.joined(separator: ", ") : "\(names.count) libraries")
        let dest = primaryTarget?.displayName ?? "Target"
        let suffix = dedupedTargets.count > 1 ? " +\(dedupedTargets.count - 1)" : ""
        return "\(lib) → \(dest)\(suffix)"
    }

    // MARK: mutators

    func toggleLibrary(_ id: String) { if selectedLibraryIDs.contains(id) { selectedLibraryIDs.remove(id) } else { selectedLibraryIDs.insert(id) } }
    func toggleTarget(_ id: String) { if selectedTargetIDs.contains(id) { selectedTargetIDs.removeAll { $0 == id } } else { selectedTargetIDs.append(id) } }

    func addLibrary(_ ct: ContentType, at url: URL) {
        libraries.removeAll { $0.id == ct.id }
        libraries.append(ct)
        selectedLibraryIDs.insert(ct.id)
        model.libraryValid[ct.id] = FileManager.default.fileExists(atPath: url.path)
    }
    /// re-read the built-in library list (after a location edit) while keeping added ones.
    func refreshBuiltInLibraries() {
        let builtins = model.registry.types
        let ids = Set(builtins.map(\.id))
        libraries = builtins + libraries.filter { !ids.contains($0.id) }
        model.revalidate()
    }

    func addTarget(_ t: Target) {
        targets.removeAll { $0.id == t.id }; targets.append(t); model.addTarget(t)
        if !selectedTargetIDs.contains(t.id) { selectedTargetIDs.append(t.id) }
    }
    func removeTarget(_ id: String) {
        guard model.canRemoveTarget(id) else { return }
        selectedTargetIDs.removeAll { $0 == id }
        model.removeTarget(id)
        targets = model.targets
    }

    /// persist the job (Keychain + store). Returns false if the draft isn't valid.
    @discardableResult
    func commit() -> Bool {
        guard isValid else { return false }
        let id = editingID ?? UUID().uuidString
        if encrypt {
            if !passphrase.isEmpty { KeychainArchiveKey.save(passphrase, jobID: id) }   // else keep existing
        } else if editingEncrypted {
            KeychainArchiveKey.delete(jobID: id)                                        // encryption turned off
        }
        model.addJob(BackupJob(id: id, name: name.isEmpty ? defaultName : name,
                               libraries: selectedLibraries, targets: dedupedTargets, format: format,
                               frequency: frequency, verification: verification, runPolicy: runPolicy,
                               enabled: editingEnabled, encrypted: encrypt,
                               retention: isSealed ? retentionPolicy : .keepAll,
                               createdAt: editingCreatedAt ?? Date()))
        return true
    }

    // MARK: seeding

    private func seedDefaults() {
        selectedTargetIDs = targets.first.map { [$0.id] } ?? []
        let d = UserDefaults.standard
        if d.integer(forKey: Prefs.mirrorGB) > 0 { mirrorValue = d.integer(forKey: Prefs.mirrorGB) }
        if let u = d.string(forKey: Prefs.mirrorUnit) { mirrorUnit = u }
        formatKind = d.string(forKey: Prefs.format) ?? "mirror"
        if let v = d.string(forKey: Prefs.verify), let p = VerificationPolicy(rawValue: v) { verification = p }
        if let r = d.string(forKey: Prefs.runPolicy), let p = RunPolicy(rawValue: r) { runPolicy = p }
    }

    private func seedFrom(_ job: BackupJob) {
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
        case .daily(let h, let m): freqKind = .daily; dailyTime = Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date()
        case .everyHours(let h): freqKind = .everyHours; everyHours = h
        case .oneTime(let date): freqKind = .once; onceDate = date
        case .manual: freqKind = .manual
        }
    }
}
