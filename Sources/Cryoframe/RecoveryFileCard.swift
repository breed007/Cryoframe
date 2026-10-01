//
//  RecoveryFileCard.swift
//  Cryoframe (app)
//
//  "Your recovery file is out of date." Encrypted backups open on another Mac only
//  with the recovery file, and a file exported before a job was made, encrypted, or
//  given other libraries doesn't hold what that Mac will need. Nothing said so until
//  the day it was needed. One line, and a way to Settings to export a new one.
//

import SwiftUI
import CryoframeKit

struct RecoveryFileCard: View {
    @ObservedObject var model: AppModel
    @State private var status: EscrowFreshness.Status = .notNeeded
    /// the printed recovery kit (see RecoveryKitPrinter) is from before the jobs changed
    @State private var kitOutOfDate = false

    var body: some View {
        // nothing at all when there's nothing to say, so the dashboard keeps no gap for it
        Group {
            if message != nil || kitOutOfDate {
                VStack(spacing: 8) {
                    if let text = message {
                        notice(symbol: "key.fill", text: text) {
                            SettingsLink { Text("Export…") }
                                .help("Settings ▸ Security ▸ Export passphrases")
                        }
                    }
                    if kitOutOfDate {
                        notice(symbol: "printer.fill",
                               text: "Your printed recovery kit is from before your jobs changed. Print a new one and replace the old.") {
                            Button("Print…") { RecoveryKitPrinter.run(); refreshKit() }
                        }
                    }
                }
            }
        }
        .onAppear { status = EscrowFreshness.current(); refreshKit() }
        // a job made, encrypted, or given other libraries changes what the file must hold
        .onChange(of: model.jobs.map { "\($0.id)|\($0.encrypted)|\($0.libraries.map(\.displayName))" }) { _, _ in
            status = EscrowFreshness.current()
        }
        // any change to a job may change what the printed kit says
        .onChange(of: model.jobs) { _, _ in refreshKit() }
        .onReceive(NotificationCenter.default.publisher(for: .escrowExported)) { _ in status = EscrowFreshness.current() }
        .onReceive(NotificationCenter.default.publisher(for: .recoveryKitPrinted)) { _ in refreshKit() }
    }

    private func refreshKit() { kitOutOfDate = RecoveryKitPrinter.isOutOfDate(jobs: model.jobs) }

    private func notice<Action: View>(symbol: String, text: String, @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol).foregroundStyle(.cryoWarn).accessibilityHidden(true)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            action()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.cryoWarn.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.cryoWarn.opacity(0.28), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var message: String? { EscrowFreshness.notice(status) }
}
