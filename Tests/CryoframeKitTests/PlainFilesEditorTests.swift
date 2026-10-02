//
//  PlainFilesEditorTests.swift
//  CryoframeKitTests
//
//  The editor's rules for plain files: offered for a new job only, never encrypted,
//  an app library refused where the drive can't hold it (with why and what to use
//  instead), and one notice that says the files aren't encrypted and what is deleted
//  is kept, and where to delete it.
//

import Testing
import Foundation
@testable import CryoframeKit

private let now = Date(timeIntervalSince1970: 1_790_000_000)
private let docs = ContentType(id: "docs", displayName: "Documents", paths: [.absolute("/tmp/docs")], owningProcess: nil, kind: .staticContent)
private let card = Target.externalDrive(id: "card", name: "Card", dir: URL(fileURLWithPath: "/Volumes/Card/Backups", isDirectory: true))
private let ssd = Target.externalDrive(id: "ssd", name: "SSD", dir: URL(fileURLWithPath: "/Volumes/SSD/Backups", isDirectory: true))

private func draft(editing job: BackupJob? = nil) -> JobDraftState {
    JobDraftState(editing: job, libraries: [.photos, docs], targets: [card, ssd], now: now)
}

private func profile(_ t: Target) -> FileSystemProfile {
    t.id == "card" ? .make(fsType: "exfat") : .make(fsType: "apfs")
}

@Suite struct PlainFilesEditorTests {

    @Test func plainFilesAreANewJobsChoiceAndAreNeverEncrypted() {
        var d = draft()
        d.formatKind = "plain"
        d.encrypt = true
        #expect(d.isPlainFiles && !d.isSealed && d.plainFilesOffered && !d.formatLocked)
        let job = d.makeJob(now: now)
        #expect(job.format == .plainFiles)
        #expect(!job.encrypted)
        #expect(job.retention == .keepAll)

        let editingPlain = draft(editing: job)
        #expect(editingPlain.formatKind == "plain")
        #expect(editingPlain.formatLocked && !editingPlain.plainFilesOffered)
        let editingImage = draft(editing: BackupJob(name: "I", libraries: [docs], target: card, format: .liveMirror(sizeGB: 500),
                                                    frequency: .manual, createdAt: now))
        #expect(!editingImage.formatLocked && !editingImage.plainFilesOffered)
    }

    // Photos as plain files: refused on the exFAT card, saying why and what to use;
    // taken on the APFS drive. A folder is taken anywhere.
    @Test func anAppLibraryIsRefusedWhereTheDriveCantHoldIt() {
        var d = draft()
        d.formatKind = "plain"
        d.selectedLibraryIDs = [ContentType.photos.id]
        d.selectedTargetIDs = ["card"]
        let issues = d.plainFilesIssues(profile: profile)
        #expect(issues.count == 1)
        #expect(issues[0].hasPrefix("Photos can't be kept as plain files on this drive: an exFAT drive can't hold"))
        #expect(issues[0].hasSuffix("Use a disk image on this drive."))
        #expect(!d.isValid(existing: [], profile: profile))

        d.selectedTargetIDs = ["ssd"]
        #expect(d.plainFilesIssues(profile: profile).isEmpty)
        d.selectedTargetIDs = ["card"]
        d.selectedLibraryIDs = ["docs"]
        #expect(d.plainFilesIssues(profile: profile).isEmpty)
        d.formatKind = "mirror"
        d.selectedLibraryIDs = [ContentType.photos.id]
        #expect(d.plainFilesIssues(profile: profile).isEmpty)
    }

    // One notice: not encrypted (left out when every drive is), what is deleted is
    // kept and where to delete it; messages named only when the job backs them up.
    @Test func theNoticeSaysWhatPlainFilesMean() {
        var d = draft()
        d.formatKind = "plain"
        d.selectedLibraryIDs = ["docs"]
        let open = d.plainFilesNotice(encrypted: { _ in false })
        #expect(open == "Plain files aren't encrypted: anyone with the drive can open them. What you delete from a library is kept in Removed items beside its copy, until you delete it in Storage.")
        #expect(d.plainFilesNotice(encrypted: { _ in true }) == "What you delete from a library is kept in Removed items beside its copy, until you delete it in Storage.")
        let messages = ContentType(id: "com.apple.messages", displayName: "Messages", paths: [.home("Library/Messages")],
                                   owningProcess: nil, kind: .liveDB)
        #expect(JobDraftState.plainFilesNotice(libraries: [messages], encrypted: false).contains("including photos and files from your messages"))
        d.formatKind = "mirror"
        #expect(d.plainFilesNotice(encrypted: { _ in false }) == nil)
    }

    // A plain-files job and a disk-image job of one library at one destination don't
    // share anything; two plain-files jobs do, and are refused like two image jobs.
    @Test func conflictsAreBetweenJobsOfTheSameKind() {
        var d = draft()
        d.formatKind = "plain"
        d.selectedLibraryIDs = ["docs"]
        d.selectedTargetIDs = ["card"]
        let image = BackupJob(id: "i", name: "Image", libraries: [docs], target: card, format: .liveMirror(sizeGB: 500), frequency: .manual, createdAt: now)
        let plain = BackupJob(id: "p", name: "Plain", libraries: [docs], target: card, format: .plainFiles, frequency: .manual, createdAt: now)
        #expect(d.destinationConflicts(existing: [image]).isEmpty)
        #expect(d.destinationConflicts(existing: [plain]) == ["“Plain” already keeps plain files of Documents at Card"])
    }
}
