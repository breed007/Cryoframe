//
//  RecoveryKitPrinter.swift
//  Cryoframe (app)
//
//  Printing the recovery kit (see RecoveryKit in the Kit), straight from memory: no
//  file of ours is written. The passphrase page is offered by a box that starts
//  unticked every time, and printed as a print job of its own after a warning, since
//  the print queue holds the page and the print panel's PDF menu saves, mails or
//  opens a copy.
//

import AppKit
import CryoframeKit

enum RecoveryKitPrinter {
    /// what the last kit printed covered (never a passphrase), for "printed before
    /// your jobs changed"
    struct Printed: Codable, Equatable {
        var printedAt: Date
        var fingerprint: String
    }

    static func lastPrinted() -> Printed? {
        guard let data = UserDefaults.standard.data(forKey: Prefs.recoveryKitPrinted) else { return nil }
        return try? JSONDecoder().decode(Printed.self, from: data)
    }

    /// whether the jobs have changed since the kit was last printed; false when it never was
    static func isOutOfDate(jobs: [BackupJob]) -> Bool {
        guard let printed = lastPrinted() else { return false }
        return printed.fingerprint != RecoveryKit.fingerprint(jobs: jobs)
    }

    /// Ask, print the kit, and, if its box was ticked, warn and print the passphrase page.
    @MainActor
    static func run() {
        let ask = NSAlert()
        ask.messageText = "Print a recovery kit"
        ask.informativeText = "The kit lists your jobs, where each keeps its backups (with each drive's name and volume UUID), and how to open them without Cryoframe. It holds no passphrases. Keep it away from this Mac and its backup drives."
        // made here each time, so it always starts unticked and nothing remembers it
        let box = NSButton(checkboxWithTitle: "Also print the passphrases, on a separate page", target: nil, action: nil)
        box.state = .off
        ask.accessoryView = box
        ask.addButton(withTitle: "Print…")
        ask.addButton(withTitle: "Cancel")
        guard ask.runModal() == .alertFirstButtonReturn else { return }

        let jobs = JobStore.standard().load().jobs
        let escrow = EscrowFreshness.current()
        for job in RecoveryKitPrintPlan.jobs(includePassphrases: box.state == .on) {
            let now = Date()
            switch job {
            case .kit:
                let kit = RecoveryKitPrintPlan.sections(for: .kit, jobs: jobs, escrow: escrow, passphrases: { [] }, printedAt: now)
                guard print(kit, title: "Cryoframe Recovery Kit") else { return }
                if let data = try? JSONEncoder().encode(Printed(printedAt: now, fingerprint: RecoveryKit.fingerprint(jobs: jobs))) {
                    UserDefaults.standard.set(data, forKey: Prefs.recoveryKitPrinted)
                    NotificationCenter.default.post(name: .recoveryKitPrinted, object: nil)
                }
            case .passphrases:
                let warn = NSAlert()
                warn.alertStyle = .critical
                warn.messageText = "Print the passphrase page?"
                warn.informativeText = "Anyone holding this page can open your encrypted backups. It goes through the print queue like any page, and macOS keeps a copy of each print job's file for about a day afterward. The print panel's PDF menu (Save as PDF, Save to iCloud Drive, Mail, Preview) writes or sends a copy: choose a printer, not PDF. Keep the page locked away, apart from the backup drives and the kit."
                warn.addButton(withTitle: "Print Passphrase Page…")
                warn.addButton(withTitle: "Don't Print")
                guard warn.runModal() == .alertFirstButtonReturn else { return }
                let page = RecoveryKitPrintPlan.sections(for: .passphrases, jobs: jobs, escrow: escrow,
                                                         passphrases: { PassphraseEscrow.collect() }, printedAt: now)
                _ = print(page, title: "Cryoframe Passphrases")
            }
        }
    }

    /// One print job of `sections`, with the print panel. Returns whether it printed.
    @MainActor
    private static func print(_ sections: [RecoveryKit.Section], title: String) -> Bool {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: max(width, 400), height: 100))
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.textStorage?.setAttributedString(attributed(sections))
        view.sizeToFit()
        let op = NSPrintOperation(view: view, printInfo: info)
        op.jobTitle = title
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        return op.run()
    }

    private static func attributed(_ sections: [RecoveryKit.Section]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let heading: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 12)]
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)]
        for (i, s) in sections.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n", attributes: body)) }
            out.append(NSAttributedString(string: s.title + "\n", attributes: heading))
            out.append(NSAttributedString(string: s.lines.joined(separator: "\n") + "\n", attributes: body))
        }
        return out
    }
}

extension Notification.Name {
    static let recoveryKitPrinted = Notification.Name("app.cryoframe.recoveryKitPrinted")
}
