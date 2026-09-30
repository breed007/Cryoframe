//
//  JobDraftStateTests.swift
//  CryoframeKitTests
//
//  The rules the job editor enforces, pinned as they behaved when they lived in the
//  app: what a draft saves as, what it refuses, and what an edit may not change.
//

import Testing
import Foundation
@testable import CryoframeKit

private var utc: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}
private let now = Date(timeIntervalSince1970: 1_790_000_000)   // a fixed instant

private func folder(_ id: String, _ name: String) -> ContentType {
    ContentType(id: id, displayName: name, paths: [.absolute("/tmp/\(id)")], owningProcess: nil, kind: .staticContent)
}
private func dest(_ id: String, _ path: String, name: String? = nil) -> Target {
    .localVolume(id: id, name: name ?? id, dir: URL(fileURLWithPath: path, isDirectory: true))
}

private let photos = ContentType.photos
private let projects = folder("work-projects", "Projects")
private let otherProjects = folder("home-projects", "projects")
private let music = folder("music", "Music")
private let t7 = dest("t7", "/Volumes/T7/Backups", name: "T7")
private let nas = dest("nas", "/Volumes/NAS/Backups", name: "NAS")
private let t7Again = dest("t7-again", "/Volumes/T7/Backups", name: "T7 (again)")

private func draft(editing job: BackupJob? = nil, defaults: JobDraftState.Defaults = .init()) -> JobDraftState {
    JobDraftState(editing: job, libraries: [photos, projects, otherProjects, music], targets: [t7, nas, t7Again],
                  defaults: defaults, now: now, calendar: utc)
}

private func job(_ id: String = "existing", name: String = "Existing", libraries: [ContentType] = [photos],
                 targets: [Target] = [t7], format: FormatChoice = .sealedDMG, encrypted: Bool = false,
                 enabled: Bool = true, retention: RetentionPolicy = .keepLast(3),
                 frequency: BackupFrequency = .daily(hour: 3, minute: 15)) -> BackupJob {
    BackupJob(id: id, name: name, libraries: libraries, targets: targets, format: format, frequency: frequency,
              verification: .mountAndOpen, runPolicy: .deferIfRunning, enabled: enabled, encrypted: encrypted,
              retention: retention, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
}

// MARK: - new-job defaults

@Test func aNewDraftStartsBoundedDailyAt2AndOnTheFirstDestination() {
    let d = draft()
    #expect(!d.isEditing)
    #expect(d.formatKind == "mirror")
    #expect(d.format == .liveMirror(sizeGB: FormatChoice.legacyMirrorGB))
    #expect(d.selectedTargetIDs == ["t7"])
    #expect(d.retentionPolicy == .keepLast(7))
    #expect(d.frequency(calendar: utc) == .daily(hour: 2, minute: 0))
    #expect(d.onceDate == now.addingTimeInterval(3600))
    #expect(d.verification == .checksumOnly && d.runPolicy == .proceed)
}

@Test func aNewDraftTakesTheRememberedChoices() {
    let d = draft(defaults: .init(formatKind: "dmg", verification: "mountAndOpen", runPolicy: "warnIfRunning"))
    #expect(d.formatKind == "dmg" && d.isSealed)
    #expect(d.verification == .mountAndOpen && d.runPolicy == .warnIfRunning)
}

@Test func unusableRememberedChoicesFallBackToTheBuiltInDefaults() {
    let d = draft(defaults: .init(verification: "bogus", runPolicy: "bogus"))
    #expect(d.verification == .checksumOnly && d.runPolicy == .proceed)
}

@Test func withNoDestinationsOnOfferNothingIsPreselected() {
    let d = JobDraftState(libraries: [photos], targets: [], now: now, calendar: utc)
    #expect(d.selectedTargetIDs.isEmpty)
    #expect(d.primaryTarget == nil)
}

// MARK: - format

@Test func formatKindMapsToTheFormatSaved() {
    var d = draft()
    #expect(d.format == .liveMirror(sizeGB: FormatChoice.legacyMirrorGB) && !d.isSealed)
    d.formatKind = "zip";  #expect(d.format == .sealedZip && d.isSealed)
    d.formatKind = "dmg";  #expect(d.format == .sealedDMG && d.isSealed)
}

// MARK: - destinations

@Test func twoDestinationsAtTheSamePathCountOnce() {
    var d = draft()
    d.selectedTargetIDs = ["t7", "t7-again", "nas"]
    #expect(d.selectedTargets.map(\.id) == ["t7", "t7-again", "nas"])
    #expect(d.dedupedTargets.map(\.id) == ["t7", "nas"])
    #expect(d.hasDuplicateDestinations)
    #expect(d.primaryTarget?.id == "t7")
}

@Test func toggleTargetKeepsSelectionOrder() {
    var d = draft()
    d.toggleTarget("nas"); d.toggleTarget("t7"); d.toggleTarget("t7")
    #expect(d.selectedTargetIDs == ["nas", "t7"])
}

@Test func addTargetReplacesBySameIDAndSelectsIt() {
    var d = draft()
    d.addTarget(dest("nas", "/Volumes/NAS2/Backups", name: "NAS 2"))
    #expect(d.targets.filter { $0.id == "nas" }.map(\.displayName) == ["NAS 2"])
    #expect(d.selectedTargetIDs == ["t7", "nas"])
    d.addTarget(dest("nas", "/Volumes/NAS2/Backups", name: "NAS 2"))
    #expect(d.selectedTargetIDs == ["t7", "nas"])
}

// MARK: - retention and schedule

@Test func retentionMapping() {
    var d = draft()
    d.retentionKind = "lastN"; d.keepN = 0
    #expect(d.retentionPolicy == .keepLast(1))
    d.keepN = 12
    #expect(d.retentionPolicy == .keepLast(12))
    d.retentionKind = "gfs"; d.gfsDaily = 7; d.gfsWeekly = 0; d.gfsMonthly = -3
    #expect(d.retentionPolicy == .gfs(daily: 7, weekly: 0, monthly: 0))
    d.gfsDaily = 0
    #expect(d.retentionPolicy == .keepLast(1))      // "keep nothing" is not a policy
    d.retentionKind = "all"
    #expect(d.retentionPolicy == .keepAll)
}

@Test func frequencyMapping() {
    var d = draft()
    d.dailyTime = utc.date(bySettingHour: 23, minute: 45, second: 0, of: now)!
    #expect(d.frequency(calendar: utc) == .daily(hour: 23, minute: 45))
    d.freqKind = .everyHours; d.everyHours = 6
    #expect(d.frequency(calendar: utc) == .everyHours(6))
    d.freqKind = .once
    #expect(d.frequency(calendar: utc) == .oneTime(now.addingTimeInterval(3600)))
    d.freqKind = .manual
    #expect(d.frequency(calendar: utc) == .manual)
}

// MARK: - encryption

@Test func aNewEncryptedJobNeedsAMatchingPassphrase() {
    var d = draft()
    d.selectedLibraryIDs = [photos.id]
    d.encrypt = true
    #expect(!d.encryptionValid && !d.isValid(existing: []))
    d.passphrase = "correct horse"; d.passphraseConfirm = "correct hors"
    #expect(!d.encryptionValid)
    d.passphraseConfirm = "correct horse"
    #expect(d.encryptionValid && d.isValid(existing: []))
    #expect(d.storesNewPassphrase)
    d.encrypt = false
    #expect(!d.storesNewPassphrase)
}

@Test func anEditedJobKeepsItsEncryptionWhateverTheToggleSays() {
    let plain = job(encrypted: false)
    var d = draft(editing: plain)
    #expect(d.encryptionLocked)
    d.encrypt = true; d.passphrase = "x"; d.passphraseConfirm = "y"
    #expect(d.encryptionValid)                       // locked: the fields are ignored
    #expect(!d.storesNewPassphrase)
    #expect(d.makeJob(id: plain.id).encrypted == false)

    let sealedAway = job(encrypted: true)
    var e = draft(editing: sealedAway)
    e.encrypt = false
    #expect(e.makeJob(id: sealedAway.id).encrypted == true)
}

// MARK: - mirror size

// There is no mirror size to choose any more: the image is sized from its drive.
// An edited mirror job keeps whatever size it recorded, so a version before 1.6
// reading it still has one, and editing can't be refused over a size.
@Test func editingAMirrorKeepsItsRecordedSizeAndIsNeverRefusedOverIt() {
    let mirror = job(format: .liveMirror(sizeGB: 2000))
    var d = draft(editing: mirror)
    d.selectedLibraryIDs = [photos.id]
    #expect(d.format == .liveMirror(sizeGB: 2000))
    #expect(d.isValid(existing: [mirror]))
    #expect(d.makeJob(id: mirror.id, now: now, calendar: utc).format == .liveMirror(sizeGB: 2000))
    d.formatKind = "dmg"
    #expect(d.format == .sealedDMG)
}

@Test func aSealedJobTurnedIntoAMirrorRecordsTheLegacySize() {
    var d = draft(editing: job(format: .sealedDMG))
    d.formatKind = "mirror"
    #expect(d.format == .liveMirror(sizeGB: FormatChoice.legacyMirrorGB))
}

// MARK: - conflicts and clashes

@Test func twoSealedJobsMayNotArchiveTheSameLibraryToTheSameFolder() {
    let other = job(name: "Nightly", libraries: [photos], targets: [dest("x", "/Volumes/t7/backups/")])
    var d = draft()
    d.formatKind = "dmg"; d.selectedLibraryIDs = [photos.id]
    #expect(d.destinationConflicts(existing: [other]) == ["“Nightly” already keeps dated versions of Photos at T7"])
    #expect(!d.isValid(existing: [other]))
}

@Test func twoMirrorsAreHeldToTheSameRule() {
    let other = job(name: "Live", libraries: [photos], targets: [t7], format: .liveMirror(sizeGB: 500))
    var d = draft()
    d.selectedLibraryIDs = [photos.id]
    #expect(d.destinationConflicts(existing: [other]) == ["“Live” already keeps an up-to-date copy of Photos at T7"])
}

@Test func aSealedJobAndAMirrorMayShareAFolder() {
    let other = job(libraries: [photos], targets: [t7], format: .liveMirror(sizeGB: 500))
    var d = draft()
    d.formatKind = "zip"; d.selectedLibraryIDs = [photos.id]
    #expect(d.destinationConflicts(existing: [other]).isEmpty)
    #expect(d.isValid(existing: [other]))
}

@Test func aSameNamedLibraryInAnotherJobConflictsToo() {
    let other = job(name: "Work", libraries: [projects], targets: [t7])
    var d = draft()
    d.formatKind = "dmg"; d.selectedLibraryIDs = [otherProjects.id]
    #expect(d.destinationConflicts(existing: [other]) == ["“Work” already keeps dated versions of projects at T7"])
}

@Test func editingAJobNeverConflictsWithItself() {
    let me = job(libraries: [photos], targets: [t7])
    let d = draft(editing: me)
    #expect(d.destinationConflicts(existing: [me]).isEmpty)
    #expect(d.isValid(existing: [me]))
}

// 1.5.6 refused this: the two shared one archive folder. Folders found by identity
// (1.6) keep them apart, so it's allowed, with a note to rename one.
@Test func twoLibrariesOfOneNameAreAllowedWithANote() {
    var d = draft()
    d.selectedLibraryIDs = [projects.id, otherProjects.id]
    #expect(d.libraryNameClashes == [LibraryNames.clashMessage("Projects")])
    #expect(LibraryNames.clashMessage("Projects").contains("separate folders"))
    #expect(d.isValid(existing: []))
}

@Test func aDraftNeedsALibraryAndADestination() {
    var d = draft()
    #expect(!d.isValid(existing: []))
    d.toggleLibrary(photos.id)
    #expect(d.isValid(existing: []))
    d.selectedTargetIDs = []
    #expect(!d.isValid(existing: []))
    d.toggleTarget("nas"); d.toggleLibrary(photos.id)
    #expect(!d.isValid(existing: []))
}

// MARK: - naming

@Test func defaultNameDescribesLibrariesAndDestinations() {
    var d = draft()
    #expect(d.defaultName == "Libraries → T7")
    d.selectedLibraryIDs = [photos.id]
    #expect(d.defaultName == "Photos → T7")
    d.selectedLibraryIDs = [photos.id, music.id]
    #expect(d.defaultName == "Photos, Music → T7")
    d.selectedLibraryIDs = [photos.id, music.id, projects.id]
    d.selectedTargetIDs = ["nas", "t7", "t7-again"]
    #expect(d.defaultName == "3 libraries → NAS +1")
    d.selectedTargetIDs = []
    #expect(d.defaultName == "3 libraries → Target")
}

// MARK: - adding libraries

@Test func addLibraryReplacesBySameIDAndSelectsIt() {
    var d = draft()
    d.addLibrary(folder("music", "Music (external)"))
    #expect(d.libraries.filter { $0.id == "music" }.map(\.displayName) == ["Music (external)"])
    #expect(d.selectedLibraryIDs == ["music"])
}

@Test func replacingBuiltInsKeepsAddedLibraries() {
    var d = draft()
    d.addLibrary(folder("added", "Added"))
    d.replaceBuiltInLibraries([photos])
    #expect(d.libraries.map(\.id) == [photos.id, "work-projects", "home-projects", "music", "added"])
}

// MARK: - what a draft saves as

@Test func aNewJobSavesWhatWasChosen() {
    var d = draft()
    d.selectedLibraryIDs = [photos.id]
    d.selectedTargetIDs = ["t7", "t7-again", "nas"]
    d.formatKind = "dmg"; d.retentionKind = "gfs"
    d.freqKind = .everyHours; d.everyHours = 12
    let j = d.makeJob(id: "new", now: now, calendar: utc)
    #expect(j.id == "new" && j.name == "Photos → T7 +1")
    #expect(j.targets.map(\.id) == ["t7", "nas"])
    #expect(j.format == .sealedDMG && j.retention == .gfs(daily: 7, weekly: 4, monthly: 6))
    #expect(j.frequency == .everyHours(12))
    #expect(j.enabled && !j.encrypted && j.createdAt == now)
}

@Test func aMirrorAlwaysSavesKeepAll() {
    var d = draft()
    d.selectedLibraryIDs = [photos.id]
    d.retentionKind = "lastN"; d.keepN = 2
    #expect(d.makeJob(id: "m", now: now, calendar: utc).retention == .keepAll)
}

@Test func editingAndSavingUnchangedGivesBackTheSameJob() {
    let cases: [BackupJob] = [
        job(format: .sealedDMG, retention: .keepLast(3), frequency: .daily(hour: 3, minute: 15)),
        job(format: .sealedZip, retention: .gfs(daily: 1, weekly: 2, monthly: 3), frequency: .everyHours(8)),
        job(format: .sealedDMG, encrypted: true, enabled: false, retention: .keepAll, frequency: .manual),
        job(format: .liveMirror(sizeGB: 750), retention: .keepAll, frequency: .oneTime(now)),
        job(libraries: [photos, music], targets: [nas, t7], format: .liveMirror(sizeGB: 4000), retention: .keepAll),
    ]
    for original in cases {
        let saved = draft(editing: original).makeJob(id: original.id, now: now, calendar: utc)
        #expect(saved == original)
    }
}

@Test func anEditedJobOffersItsOwnLibrariesAndDestinationsEvenIfGoneFromTheLists() {
    let gone = folder("gone", "Gone")
    let away = dest("away", "/Volumes/Away")
    let d = JobDraftState(editing: job(libraries: [gone], targets: [away]), libraries: [photos], targets: [t7],
                          now: now, calendar: utc)
    #expect(d.libraries.map(\.id) == [photos.id, "gone"])
    #expect(d.targets.map(\.id) == ["t7", "away"])
    #expect(d.selectedLibraryIDs == ["gone"] && d.selectedTargetIDs == ["away"])
}
