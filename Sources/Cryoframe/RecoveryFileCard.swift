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

    var body: some View {
        Group {
            if let text = message {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "key.fill").foregroundStyle(.cryoWarn).accessibilityHidden(true)
                    Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    SettingsLink { Text("Export…") }
                        .help("Settings ▸ Security ▸ Export passphrases")
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.cryoWarn.opacity(0.09)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.cryoWarn.opacity(0.28), lineWidth: 1))
                .accessibilityElement(children: .combine)
            }
        }
        .onAppear { status = EscrowFreshness.current() }
        // a job made, encrypted, or given other libraries changes what the file must hold
        .onChange(of: model.jobs.map { "\($0.id)|\($0.encrypted)|\($0.libraries.map(\.displayName))" }) { _, _ in
            status = EscrowFreshness.current()
        }
        .onReceive(NotificationCenter.default.publisher(for: .escrowExported)) { _ in status = EscrowFreshness.current() }
    }

    private var message: String? {
        switch status {
        case .notNeeded, .current: return nil
        case .neverExported:
            return "Your encrypted backups have no recovery file yet. Without it they can't be opened on another Mac. Export one and keep it apart from the backups."
        case .outOfDate(_, let why):
            return "Your recovery file is out of date (\(why.joined(separator: "; "))). Export a new one so every encrypted backup can be opened on another Mac."
        }
    }
}
