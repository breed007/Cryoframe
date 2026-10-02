//
//  RecoveryKit.swift
//  CryoframeKit
//
//  A printed page for the day the Mac is gone: which jobs there were, where each
//  wrote its backups (with the drive's name and volume UUID, so the right drive can
//  be found in a drawer of them), how to open each format with what macOS has, and
//  when the recovery file was last exported.
//
//  The kit never holds a passphrase. Passphrases go on a page of their own, printed
//  only when asked for and only after a warning (see passphrasePage): a print job
//  passes through the print queue, and the print panel's PDF menu saves, mails or
//  opens a copy. The app prints both straight from memory, with no file of ours.
//
//  Built here as plain sections so it can be tested without printing.
//

import Foundation
import CryptoKit

public enum RecoveryKit {
    public struct Section: Sendable, Equatable {
        public var title: String
        public var lines: [String]
        public init(title: String, lines: [String]) { self.title = title; self.lines = lines }
    }

    /// The kit for `jobs`. `escrow` is the recovery file's standing (see EscrowFreshness).
    public static func document(jobs: [BackupJob], escrow: EscrowFreshness.Status, printedAt: Date) -> [Section] {
        var out: [Section] = []
        out.append(Section(title: "Cryoframe recovery kit", lines: [
            "Printed \(stamp(printedAt)).",
            "",
            "What you need to get your backups back if this Mac is lost, stolen or broken. Keep",
            "it somewhere away from the Mac and its backup drives. It holds no passwords or",
            "passphrases.",
        ]))

        if jobs.isEmpty {
            out.append(Section(title: "Jobs", lines: ["No backup jobs were set up when this was printed."]))
        }
        for job in jobs {
            out.append(Section(title: "Job: \(job.name)", lines: jobLines(job)))
        }

        let formats = Set(jobs.map { format($0.format) })
        for f in ArchiveFormat.noteOrder where formats.contains(f) {
            let steps = RecoveryNote.steps(for: f)
            out.append(Section(title: steps[0], lines: Array(steps.dropFirst())))
        }
        let split = Set(jobs.filter { job in job.format.isSealed && job.targets.contains(where: { $0.constraints.splitPolicy != .none }) }
            .map { format($0.format) })
        if !split.isEmpty {
            let steps = RecoveryNote.splitSteps(split)
            out.append(Section(title: steps[0], lines: Array(steps.dropFirst())))
        }

        if jobs.contains(where: \.encrypted) {
            let steps = RecoveryNote.encryptedSteps
            out.append(Section(title: steps[0], lines: Array(steps.dropFirst()) + escrowLines(escrow)))
        }

        out.append(Section(title: "Where this kit is kept", lines: [
            "Kept at: ______________________________________________",
            "",
            "Recovery file kept at: ________________________________",
        ]))
        return out
    }

    /// The passphrase page: printed on its own, only when asked for.
    public static func passphrasePage(_ entries: [PassphraseEscrow.Entry], printedAt: Date) -> [Section] {
        var out = [Section(title: "Cryoframe passphrases", lines: [
            "Printed \(stamp(printedAt)).",
            "",
            "Anyone holding this page can open these backups. Keep it apart from the backup",
            "drives and from the recovery kit, somewhere locked.",
        ])]
        if entries.isEmpty {
            out.append(Section(title: "No passphrases", lines: ["No encrypted job had a saved passphrase on this Mac."]))
        }
        for e in entries {
            out.append(Section(title: e.jobName, lines: [
                "Libraries: \(e.libraryList)",
                "Passphrase: \(e.passphrase)",
            ]))
        }
        return out
    }

    /// the sections as plain text, as printed
    public static func text(_ sections: [Section]) -> String {
        sections.map { ([$0.title, String(repeating: "=", count: min(80, $0.title.count))] + $0.lines).joined(separator: "\n") }
            .joined(separator: "\n\n") + "\n"
    }

    /// What the kit says about `jobs`, as a short digest: a kit printed for other
    /// jobs (one added, removed, moved to another drive) no longer matches.
    public static func fingerprint(jobs: [BackupJob]) -> String {
        // without the heading, which carries the date it was printed
        let body = text(Array(document(jobs: jobs, escrow: .notNeeded, printedAt: Date()).dropFirst()))
        return SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: -

    static func format(_ f: FormatChoice) -> ArchiveFormat {
        switch f {
        case .sealedDMG: return .sealedDMG
        case .sealedZip: return .sealedZip
        case .liveMirror: return .liveMirror
        case .plainFiles: return .plainFiles
        }
    }

    static func jobLines(_ job: BackupJob) -> [String] {
        var lines = [
            "Libraries: \(job.libraries.map(\.displayName).joined(separator: ", "))",
            "Kept as: \(RecoveryNote.formatName(format(job.format)))\(job.encrypted ? ", encrypted" : "")",
            "",
        ]
        let labels = job.destinationLabels
        for t in job.targets {
            let name = labels[t.id] ?? t.displayName
            lines.append("Destination: \(name) (\(kind(t)))")
            lines.append("  Folder: \(t.destinationDir.path)")
            if let share = t.networkMount { lines.append("  Share: \(share.url.absoluteString)") }
            for v in [t.volume].compactMap({ $0 }) + (t.otherVolumes ?? []) where !v.isShare {
                lines.append("  Drive: \(v.name), volume UUID \(v.uuid)")
            }
        }
        return lines
    }

    static func kind(_ t: Target) -> String {
        switch t.kind {
        case .local: return t.rotation != nil ? "a drive that takes turns with others" : "a drive or folder"
        case .networkShare: return "a network share"
        case .cloudSync: return "a cloud folder, \((t.cloudProvider ?? CloudProvider.identify(t.destinationDir)).displayName)"
        }
    }

    static func escrowLines(_ status: EscrowFreshness.Status) -> [String] {
        switch status {
        case .notNeeded:
            return ["No encrypted job had a saved passphrase on this Mac when this was printed."]
        case .noExportRecorded:
            return ["No export of the recovery file is recorded on this Mac. Export one in",
                    "Cryoframe's Settings, under Security."]
        case .current(let date):
            return ["Recovery file last exported \(stamp(date)); it covers every encrypted job."]
        case .outOfDate(let date, let why):
            return ["Recovery file last exported \(stamp(date)), and it is out of date:",
                    "  " + why.joined(separator: "; ") + ".",
                    "Export a new one and keep it in place of the old."]
        }
    }

    static func stamp(_ date: Date) -> String {
        date.formatted(date: .long, time: .shortened)
    }
}

/// What printing the kit sends to the printer, in order. The passphrase page is a
/// print job of its own, only when its box was ticked, and the passphrases are read
/// only to print it.
public enum RecoveryKitPrintPlan {
    public enum Job: Sendable, Equatable { case kit, passphrases }

    public static func jobs(includePassphrases: Bool) -> [Job] {
        includePassphrases ? [.kit, .passphrases] : [.kit]
    }

    /// one print job's sections; `passphrases` is called only for the passphrase page
    public static func sections(for job: Job, jobs: [BackupJob], escrow: EscrowFreshness.Status,
                                passphrases: () -> [PassphraseEscrow.Entry], printedAt: Date) -> [RecoveryKit.Section] {
        switch job {
        case .kit: return RecoveryKit.document(jobs: jobs, escrow: escrow, printedAt: printedAt)
        case .passphrases: return RecoveryKit.passphrasePage(passphrases(), printedAt: printedAt)
        }
    }
}
