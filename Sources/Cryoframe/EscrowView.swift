//
//  EscrowView.swift
//  Cryoframe (app)
//
//  Settings ▸ Security. Export every stored archive passphrase into one file
//  encrypted with a master password (store it offsite), and restore/view those
//  passphrases on a new Mac. This is the recovery path for "the Mac died and the
//  encrypted backups are now unreadable."
//

import SwiftUI
import AppKit
import CryoframeKit

struct EscrowView: View {
    @State private var jobCount = 0
    @State private var encryptedCount = 0
    @State private var status: (text: String, ok: Bool)?

    private var missingKeys: Int { max(0, encryptedCount - jobCount) }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Encrypted jobs with a saved passphrase")
                    Spacer()
                    Text("\(jobCount)").foregroundStyle(.secondary).monospacedDigit()
                }
                if missingKeys > 0 {
                    Label("\(missingKeys) encrypted job\(missingKeys == 1 ? "" : "s") \(missingKeys == 1 ? "has" : "have") no saved passphrase and can't be exported.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.callout)
                }
                Button("Export passphrases…") { exportFlow() }
                    .disabled(jobCount == 0)
            } header: {
                Text("Recovery key")
            } footer: {
                Text("Saves every archive passphrase into one file, encrypted with a master password you choose. Keep it somewhere safe and separate from the backups — a password manager or a second drive. Without it, an encrypted archive can't be opened on a Mac that doesn't have the original passphrase in its keychain.")
            }
            Section {
                Button("Restore from a recovery file…") { importFlow() }
            } footer: {
                Text("Opens a recovery file and shows the saved passphrases so you can copy them into the restore prompt on a new Mac. “Copy all” places them on the clipboard — paste where you need them, then copy something else to clear it.")
            }
            if let status {
                Section {
                    Label(status.text, systemImage: status.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(status.ok ? .green : .orange)
                        .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            jobCount = PassphraseEscrow.collect().count
            encryptedCount = JobStore.standard().load().jobs.filter(\.encrypted).count
        }
    }

    // MARK: Export

    private func exportFlow() {
        guard let pw = askMasterPassword(confirm: true,
                                         prompt: "Choose a master password to protect the recovery file.\nYou'll need it to read the file later — it can't be recovered if lost.") else { return }
        let entries = PassphraseEscrow.collect()
        guard let data = PassphraseEscrow.exportData(entries, password: pw) else {
            status = ("Couldn't build the recovery file.", false); return
        }
        let save = NSSavePanel()
        save.nameFieldStringValue = "Cryoframe Recovery Keys.cryoframekeys"
        save.allowedContentTypes = []
        save.allowsOtherFileTypes = true
        save.message = "Save the encrypted recovery file"
        guard save.runModal() == .OK, let url = save.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            let omitted = missingKeys > 0 ? " (\(missingKeys) encrypted job\(missingKeys == 1 ? "" : "s") without a saved passphrase were skipped)" : ""
            status = ("Exported \(entries.count) passphrase\(entries.count == 1 ? "" : "s") to \(url.lastPathComponent).\(omitted)", missingKeys == 0)
        } catch {
            status = ("Couldn't write the file: \(error.localizedDescription)", false)
        }
    }

    // MARK: Import

    private func importFlow() {
        let open = NSOpenPanel()
        open.canChooseFiles = true; open.canChooseDirectories = false
        open.allowsMultipleSelection = false
        open.message = "Choose a Cryoframe recovery file"
        guard open.runModal() == .OK, let url = open.url else { return }
        guard let data = try? Data(contentsOf: url) else {
            status = ("Couldn't read that file.", false); return
        }
        guard let pw = askMasterPassword(confirm: false,
                                         prompt: "Enter the master password for this recovery file.") else { return }
        guard let entries = PassphraseEscrow.importEntries(data, password: pw) else {
            status = ("Wrong password, or this isn't a Cryoframe recovery file.", false); return
        }
        showEntries(entries)
        status = ("Opened \(entries.count) passphrase\(entries.count == 1 ? "" : "s").", true)
    }

    private func showEntries(_ entries: [PassphraseEscrow.Entry]) {
        let alert = NSAlert()
        alert.messageText = "Recovered passphrases"
        alert.informativeText = entries.isEmpty
            ? "The file contained no passphrases."
            : entries.map { "• \($0.jobName) (\($0.library))\n    \($0.passphrase)" }.joined(separator: "\n\n")
        alert.addButton(withTitle: "Copy all")
        alert.addButton(withTitle: "Done")
        if alert.runModal() == .alertFirstButtonReturn {
            let text = entries.map { "\($0.jobName) (\($0.library)): \($0.passphrase)" }.joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    // MARK: Master-password prompt

    private func askMasterPassword(confirm: Bool, prompt: String) -> String? {
        let alert = NSAlert()
        alert.messageText = confirm ? "Master password" : "Enter master password"
        alert.informativeText = prompt
        alert.addButton(withTitle: confirm ? "Export" : "Open")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: confirm ? 26 : 0, width: 240, height: 24))
        field.placeholderString = "Password"
        if !confirm {
            alert.accessoryView = field
        } else {
            let confirmField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            confirmField.placeholderString = "Confirm password"
            let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 240, height: 54))
            stack.orientation = .vertical
            stack.addView(field, in: .top)
            stack.addView(confirmField, in: .top)
            alert.accessoryView = stack
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            let pw = field.stringValue, c = confirmField.stringValue
            if pw.isEmpty { status = ("Master password can't be blank.", false); return nil }
            if pw != c { status = ("The passwords didn't match.", false); return nil }
            return pw
        }
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.isEmpty ? nil : field.stringValue
    }
}
