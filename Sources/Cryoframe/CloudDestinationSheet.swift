//
//  CloudDestinationSheet.swift
//  Cryoframe (app)
//
//  Picking the single-file limit for a cloud-sync destination. Plans differ a lot
//  (Box 5/50/150 GB by tier, iCloud 50 GB, the rest ~240 GB), and a sealed archive
//  splits under the chosen limit so the provider accepts it. Defaults to the
//  provider's first plan; a Custom option covers anything else.
//

import SwiftUI
import CryoframeKit

struct CloudDestinationSheet: View {
    let url: URL
    let provider: CloudProvider
    @Binding var isPresented: Bool
    var onConfirm: (_ maxFileBytes: UInt64) -> Void

    @State private var planIndex = 0
    @State private var customGB = 50

    private var isCustom: Bool { planIndex == provider.plans.count }
    private var chosenBytes: UInt64 {
        isCustom ? UInt64(max(1, customGB)) * 1_000_000_000 : provider.plans[planIndex].bytes
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(provider.displayName) destination").font(.title2.bold())
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()
            Form {
                Section {
                    FinderPathLink(path: url.path, font: .callout)
                }
                Section {
                    Picker("Plan", selection: $planIndex) {
                        ForEach(provider.plans.indices, id: \.self) { i in
                            Text("\(provider.plans[i].name) — \(human(provider.plans[i].bytes))").tag(i)
                        }
                        Text("Custom…").tag(provider.plans.count)
                    }
                    if isCustom {
                        HStack {
                            Text("Max file size")
                            Spacer()
                            TextField("", value: $customGB, format: .number)
                                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 70)
                                .onChange(of: customGB) { _, v in if v < 1 { customGB = 1 } }
                            Text("GB")
                        }
                    }
                } header: {
                    Text("Single-file limit")
                } footer: {
                    Text("Sealed archives larger than this are split into volumes that fit. Match it to your \(provider.displayName) plan — too high and the provider rejects an oversized part. A live mirror isn't affected (its bands are small).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Add destination") { onConfirm(chosenBytes); isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 460, height: 360)
    }

    private func human(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
