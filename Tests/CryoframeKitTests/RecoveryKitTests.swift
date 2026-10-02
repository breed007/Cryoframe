//
//  RecoveryKitTests.swift
//  CryoframeKitTests
//
//  The printed recovery kit: never a passphrase, every destination with its drive,
//  each format's steps word for word as the recovery note has them, and the
//  passphrase page only when asked for.
//

import Testing
import Foundation
@testable import CryoframeKit

private let printed = Date(timeIntervalSince1970: 1_790_000_000)
private let secret = "correct horse battery staple 7Q!"

private func jobs() -> [BackupJob] {
    let photos = ContentType.genericFolder(id: "p", displayName: "Photos", path: .absolute("/Users/someone/Pictures/Photos"))
    let notes = ContentType.genericFolder(id: "n", displayName: "Notes", path: .absolute("/Users/someone/Notes"))
    var drive = Target.externalDrive(id: "d1", name: "Backups on T7", dir: URL(fileURLWithPath: "/Volumes/T7/Backups"))
    drive.volume = VolumeIdentity(uuid: "4F2A9C11-0000-4000-8000-000000000001", name: "T7", relativePath: "Backups")
    let cloud = Target.cloudSyncFolder(id: "c1", name: "Dropbox", dir: URL(fileURLWithPath: "/Users/someone/Library/CloudStorage/Dropbox/Cryoframe"),
                                       provider: .dropbox)
    let share = Target.networkShare(id: "s1", name: "NAS", dir: URL(fileURLWithPath: "/Volumes/backup/Mac"),
                                    mount: NetworkMountSpec(url: URL(string: "smb://nas.local/backup")!, mountpoint: "/Volumes/backup"))
    return [
        BackupJob(id: "j1", name: "Photos nightly", libraries: [photos], targets: [drive, cloud], format: .sealedDMG,
                  frequency: .daily(hour: 2, minute: 0), encrypted: true, createdAt: printed),
        BackupJob(id: "j2", name: "Notes zip", libraries: [notes], target: share, format: .sealedZip,
                  frequency: .manual, createdAt: printed),
        BackupJob(id: "j3", name: "Notes mirror", libraries: [notes], target: drive, format: .liveMirror(sizeGB: 1),
                  frequency: .manual, createdAt: printed),
        BackupJob(id: "j4", name: "Notes plain", libraries: [notes], target: drive, format: .plainFiles,
                  frequency: .manual, createdAt: printed),
    ]
}

@Suite struct RecoveryKitTests {
    @Test func theKitHoldsNoPassphrase() {
        let all = jobs()
        for escrow in [EscrowFreshness.Status.notNeeded, .noExportRecorded, .current(printed), .outOfDate(printed, ["Photos nightly isn't in it"])] {
            let text = RecoveryKit.text(RecoveryKit.document(jobs: all, escrow: escrow, printedAt: printed))
            #expect(!text.contains(secret))
            #expect(!text.localizedCaseInsensitiveContains("passphrase:"))
        }
    }

    // The passphrase is only ever on its own page, which the app prints only when
    // its box is ticked (see EscrowView); the kit never takes passphrases at all.
    @Test func aPassphraseAppearsOnlyOnThePassphrasePage() {
        let entry = PassphraseEscrow.Entry(jobID: "j1", jobName: "Photos nightly", libraries: ["Photos"], passphrase: secret)
        let page = RecoveryKit.text(RecoveryKit.passphrasePage([entry], printedAt: printed))
        #expect(page.contains(secret))
        #expect(page.contains("Anyone holding this page can open these backups"))
        let kit = RecoveryKit.text(RecoveryKit.document(jobs: jobs(), escrow: .current(printed), printedAt: printed))
        #expect(!kit.contains(secret))
        // the print plan the app follows: the passphrase page is a second job, never
        // part of the kit's own, and only when the box is ticked
        #expect(RecoveryKitPrintPlan.jobs(includePassphrases: false) == [.kit])
        #expect(RecoveryKitPrintPlan.jobs(includePassphrases: true) == [.kit, .passphrases])
    }

    // Unticked, nothing printed holds a passphrase, and the passphrases aren't even read.
    @Test func unlessTheBoxIsTickedNoPassphraseIsPrinted() {
        final class Reads: @unchecked Sendable { var n = 0 }
        let reads = Reads()
        let entries = {
            reads.n += 1
            return [PassphraseEscrow.Entry(jobID: "j1", jobName: "Photos nightly", libraries: ["Photos"], passphrase: secret)]
        }
        func pages(_ ticked: Bool) -> [String] {
            RecoveryKitPrintPlan.jobs(includePassphrases: ticked).map {
                RecoveryKit.text(RecoveryKitPrintPlan.sections(for: $0, jobs: jobs(), escrow: .current(printed),
                                                               passphrases: entries, printedAt: printed))
            }
        }
        let unticked = pages(false)
        #expect(unticked.count == 1)
        #expect(!unticked.contains { $0.contains(secret) })
        #expect(reads.n == 0, "the passphrases were read for a print without them")
        let ticked = pages(true)
        #expect(ticked.count == 2)
        #expect(!ticked[0].contains(secret), "the kit's own print job holds the passphrase")
        #expect(ticked[1].contains(secret))
        #expect(reads.n == 1)
    }

    @Test func everyDestinationIsListedWithItsDrive() {
        let text = RecoveryKit.text(RecoveryKit.document(jobs: jobs(), escrow: .notNeeded, printedAt: printed))
        #expect(text.contains("Destination: Backups on T7 (a drive or folder)"))
        #expect(text.contains("Folder: /Volumes/T7/Backups"))
        #expect(text.contains("Drive: T7, volume UUID 4F2A9C11-0000-4000-8000-000000000001"))
        #expect(text.contains("Destination: Dropbox (a cloud folder, Dropbox)"))
        #expect(text.contains("Folder: /Users/someone/Library/CloudStorage/Dropbox/Cryoframe"))
        #expect(text.contains("Share: smb://nas.local/backup"))
        #expect(text.contains("Kept at: ____"))
        for j in jobs() { #expect(text.contains("Job: \(j.name)")) }
    }

    @Test func eachFormatsStepsAreTheRecoveryNotesWordForWord() {
        let sections = RecoveryKit.document(jobs: jobs(), escrow: .notNeeded, printedAt: printed)
        for f in ArchiveFormat.noteOrder {
            let steps = RecoveryNote.steps(for: f)
            let s = sections.first { $0.title == steps[0] }
            #expect(s.map { [$0.title] + $0.lines } == steps, "\(f)")
        }
        // the cloud job is split, so the split steps are there, for its format
        let split = RecoveryNote.splitSteps([.sealedDMG])
        #expect(sections.first { $0.title == split[0] }.map { [$0.title] + $0.lines } == split)
        // and the note itself still says the same (the steps were moved, not changed)
        let note = RecoveryNote.text(for: [])
        #expect(note.contains("HOW TO RESTORE WITHOUT CRYOFRAME"))
    }

    @Test func theRecoveryFilesStandingIsSaid() {
        let text = RecoveryKit.text(RecoveryKit.document(jobs: jobs(), escrow: .outOfDate(printed, ["Photos nightly's libraries have changed"]),
                                                        printedAt: printed))
        #expect(text.contains("ENCRYPTED BACKUPS"))
        #expect(text.contains("out of date"))
        #expect(text.contains("Photos nightly's libraries have changed"))
    }

    @Test func theFingerprintFollowsTheJobsNotTheDate() {
        let a = RecoveryKit.fingerprint(jobs: jobs())
        #expect(a == RecoveryKit.fingerprint(jobs: jobs()))
        var changed = jobs(); changed.removeLast()
        #expect(a != RecoveryKit.fingerprint(jobs: changed))
        #expect(!a.isEmpty && !a.contains(secret))
    }
}
