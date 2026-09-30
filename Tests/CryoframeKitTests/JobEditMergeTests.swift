//
//  JobEditMergeTests.swift
//  CryoframeKitTests
//
//  Saving an edited job over what runs recorded while the editor was open (see
//  JobEdit), the editor starting from the job's own destinations, and the store's
//  writes holding across processes.
//

import Testing
import Foundation
@testable import CryoframeKit

private let start = Date(timeIntervalSince1970: 1_790_000_000)

private func scratch(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-merge-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return TempTracker.track(d)
}

private func drive(_ uuid: String, _ name: String = "T7", learned: Bool = true) -> VolumeIdentity {
    VolumeIdentity(uuid: uuid, name: name, relativePath: "Backups", learnedAt: learned ? start : nil)
}

private func t7(volume: VolumeIdentity? = nil, others: [VolumeIdentity]? = nil) -> Target {
    var t = Target.externalDrive(id: "/Volumes/T7/Backups", name: "Backups on T7", dir: URL(fileURLWithPath: "/Volumes/T7/Backups"))
    t.volume = volume; t.otherVolumes = others
    return t
}
private let nas = Target.localVolume(id: "/Volumes/NAS/Backups", name: "Backups on NAS", dir: URL(fileURLWithPath: "/Volumes/NAS/Backups"))

private func papers(volume: VolumeIdentity? = nil) -> ContentType {
    var lib = ContentType.genericFolder(id: "/Volumes/Work/Papers", displayName: "Papers", path: .absolute("/Volumes/Work/Papers"))
    lib.volume = volume
    return lib
}

private func job(_ targets: [Target], libraries: [ContentType] = [papers()], enabled: Bool = true) -> BackupJob {
    BackupJob(id: "job-1", name: "Papers", libraries: libraries, targets: targets, format: .sealedDMG,
              frequency: .daily(hour: 2, minute: 0), enabled: enabled, retention: .keepLast(5), createdAt: start)
}

/// an editor opened on `job`, offering the app's remembered destinations (which know
/// nothing of drives)
private func editor(_ job: BackupJob, offered: [Target] = [t7(), nas]) -> JobDraftState {
    JobDraftState(editing: job, libraries: [.photos], targets: offered, now: start)
}

@Suite struct JobEditMergeTests {
    // MARK: seeding

    @Test func theEditorStartsFromTheJobsOwnDestinationsNotTheRememberedCopies() {
        let saved = job([t7(volume: drive("A"), others: [drive("B")])])
        var d = editor(saved)
        #expect(d.targets.first { $0.id == saved.targets[0].id } == saved.targets[0])
        d.everyHours = 6; d.freqKind = .everyHours
        let out = d.makeJob(now: start)
        #expect(out.targets == saved.targets)                         // drives kept
        #expect(out.frequency == .everyHours(6))
    }

    @Test func savingUnchangedGivesBackTheJobWithEveryDriveFact() {
        var r = Rotation(group: "g", addedAt: start)
        r.maxAwayDays = 9
        var a = t7(volume: drive("A"), others: [drive("B")]); a.rotation = r
        let saved = job([a, nas], libraries: [papers(volume: drive("W", "Work"))])
        #expect(editor(saved).makeJob(now: start) == saved)
    }

    @Test func aBuiltInTakesItsFolderFromTheListButKeepsTheJobsNameForIt() {
        var mine = ContentType.photos; mine.displayName = "Family photos"
        let moved = ContentType.photos.overridingPath(.absolute("/Volumes/Media/Photos Library.photoslibrary"))
        let d = JobDraftState(editing: job([nas], libraries: [mine]), libraries: [moved], targets: [], now: start)
        let lib = d.libraries.first { $0.id == ContentType.photos.id }
        #expect(lib?.displayName == "Family photos")
        #expect(lib?.paths == moved.paths)
    }

    @Test func aNewDraftsIDIsFixedFromTheStart() {
        let d = JobDraftState(libraries: [.photos], targets: [nas], now: start, newID: "fixed")
        #expect(d.jobID == "fixed")
        #expect(d.makeJob(now: start).id == "fixed")
        let e = editor(job([nas]))
        #expect(e.jobID == "job-1")
    }

    // MARK: merging

    @Test func aDriveARunLearnedWhileTheEditorWasOpenIsKept() {
        let base = job([t7()])
        var stored = base; stored.targets[0].volume = drive("A")          // the run recorded it
        var draft = base; draft.name = "Renamed"
        let out = JobEdit.merge(draft: draft, base: base, stored: stored)
        #expect(out?.targets[0].volume == drive("A"))
        #expect(out?.name == "Renamed")
    }

    @Test func anotherDriveARunRecordedIsKept() {
        let base = job([t7(volume: drive("A"))])
        var stored = base; stored.targets[0].otherVolumes = [drive("B")]
        let out = JobEdit.merge(draft: base, base: base, stored: stored)
        #expect(out?.targets[0].otherVolumes == [drive("B")])
    }

    @Test func stopTakingTurnsRemovesOnlyTheDriveTheEditorTookAway() {
        let base = job([t7(volume: drive("A"), others: [drive("B")])])
        var stored = base; stored.targets[0].otherVolumes = [drive("B"), drive("C")]    // a run added C
        var draft = base; draft.targets[0].otherVolumes = nil                           // stop taking turns with B
        let out = JobEdit.merge(draft: draft, base: base, stored: stored)
        #expect(out?.targets[0].otherVolumes?.map(\.uuid) == ["C"])
    }

    @Test func aPairingMadeInTheEditorIsAddedToWhatRunsRecorded() {
        let base = job([t7(volume: drive("A"))])
        var stored = base; stored.targets[0].otherVolumes = [drive("C")]
        var draft = base; draft.targets[0].otherVolumes = [drive("B")]
        let out = JobEdit.merge(draft: draft, base: base, stored: stored)
        #expect(Set(out?.targets[0].otherVolumes?.map(\.uuid) ?? []) == ["B", "C"])
    }

    @Test func aDriveTheEditorChangedIsTheEditors() {
        let base = job([t7(volume: drive("A"))])
        var stored = base; stored.targets[0].volume = drive("A2")
        var draft = base; draft.targets[0].volume = drive("Z")
        #expect(JobEdit.merge(draft: draft, base: base, stored: stored)?.targets[0].volume == drive("Z"))
    }

    @Test func aFoldersDriveARunRecordedIsKept() {
        let base = job([nas])
        var stored = base; stored.libraries[0].volume = drive("W", "Work")
        var draft = base; draft.retention = .keepLast(2)
        let out = JobEdit.merge(draft: draft, base: base, stored: stored)
        #expect(out?.libraries[0].volume == drive("W", "Work"))
        #expect(out?.retention == .keepLast(2))
    }

    @Test func aDestinationTheEditorRemovedStaysRemoved() {
        let base = job([t7(volume: drive("A")), nas])
        var stored = base; stored.targets[1].volume = drive("N", "NAS")
        var draft = base; draft.targets = [draft.targets[0]]
        #expect(JobEdit.merge(draft: draft, base: base, stored: stored)?.targets.map(\.id) == [base.targets[0].id])
    }

    @Test func aJobDeletedWhileEditedIsNotBroughtBack() {
        let base = job([nas])
        #expect(JobEdit.merge(draft: base, base: base, stored: nil) == nil)
    }

    @Test func pausingWhileTheEditorWasOpenIsKept() {
        let base = job([nas])
        var stored = base; stored.enabled = false
        #expect(JobEdit.merge(draft: base, base: base, stored: stored)?.enabled == false)
    }

    @Test func aNewJobIsTheEditorsWhole() {
        let draft = job([t7(volume: drive("A"))])
        #expect(JobEdit.merge(draft: draft, base: nil, stored: nil) == draft)
    }

    // MARK: committing

    @Test func commitMergesUnderTheStoresLockAndSaysWhenTheJobIsGone() {
        let dir = scratch("commit")
        let store = JobStore(url: dir.appendingPathComponent("jobs.json"))
        let saved = job([t7()])
        store.upsert(saved)
        var d = editor(saved)
        store.recordVolume(jobID: saved.id, targetID: saved.targets[0].id, drive("A"))    // a run, meanwhile
        d.keepN = 3
        #expect(d.commit(to: store, now: start, savePassphrase: { _, _ in Issue.record("no key for an edit") })
                == .saved(store.load().jobs[0]))
        let after = store.load().jobs[0]
        #expect(after.targets[0].volume == drive("A"))
        #expect(after.retention == .keepLast(3))

        store.remove(id: saved.id)
        #expect(d.commit(to: store, now: start, savePassphrase: { _, _ in }) == .deleted)
        #expect(store.load().jobs.isEmpty)
    }

    @Test func aNewEncryptedJobsKeyIsSavedBeforeTheJob() {
        let dir = scratch("key")
        let store = JobStore(url: dir.appendingPathComponent("jobs.json"))
        var d = JobDraftState(libraries: [papers()], targets: [nas], now: start, newID: "new-job")
        d.selectedLibraryIDs = [papers().id]
        d.encrypt = true; d.passphrase = "horse battery"; d.passphraseConfirm = "horse battery"; d.formatKind = "dmg"
        var keyed: [String] = []
        let result = d.commit(to: store, now: start) { pass, id in
            #expect(store.load().jobs.isEmpty)           // before the job
            keyed.append("\(id):\(pass)")
        }
        #expect(keyed == ["new-job:horse battery"])
        if case .saved(let j) = result { #expect(j.id == "new-job" && j.encrypted) } else { Issue.record("not saved: \(result)") }
    }

    // MARK: the list on offer

    @Test func removingOneRememberedDestinationKeepsOnesOnlyThisJobHas() {
        let onlyMine = Target.localVolume(id: "/Volumes/Mine/B", name: "B on Mine", dir: URL(fileURLWithPath: "/Volumes/Mine/B"))
        var d = editor(job([onlyMine]), offered: [nas, t7()])
        d.removeFromOffer(nas.id)
        #expect(d.targets.map(\.id).sorted() == [onlyMine.id, t7().id].sorted())
        #expect(d.selectedTargetIDs == [onlyMine.id])
    }

    @Test func theEditedJobsOwnDestinationCantBeTakenOffTheList() {
        var d = editor(job([nas]))
        d.removeFromOffer(nas.id)
        #expect(d.targets.contains { $0.id == nas.id })
        #expect(d.selectedTargetIDs == [nas.id])
    }
}
