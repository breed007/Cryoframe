//
//  OnboardingView.swift
//  Cryoframe (app)
//
//  First-run guide: walk a new user through the three pieces of setup — Full Disk
//  Access, the privileged helper, and scheduling — with live status, instead of
//  leaving them to decode the status pills. Shown once; existing/configured users
//  never see it.
//

import SwiftUI
import AppKit

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to Cryoframe").font(.title.bold())
                    Text("A couple of quick steps to your first verified backup.")
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            step(1, "Grant Full Disk Access",
                 "Cryoframe needs it to read protected libraries like Photos and Messages. After you add Cryoframe in System Settings, quit and reopen it so the change takes effect.",
                 done: model.fullDiskAccess,
                 action: ("Open Settings…", { DiskAccess.openSettings() }))

            step(2, "Enable the background helper",
                 "A small privileged helper takes the APFS snapshots. You'll approve it once in System Settings ▸ Login Items.",
                 done: model.helper.isEnabled,
                 action: ("Enable", { try? model.helper.register() }))

            step(3, "Turn on scheduling (optional)",
                 "Lets Cryoframe run your backups automatically. You can always Run now by hand instead.",
                 done: model.schedule.isEnabled,
                 action: ("Enable", { try? model.schedule.register() }))

            Divider()

            HStack {
                if !ready { Text("You can finish any step later from the status row up top.").font(.caption).foregroundStyle(.tertiary) }
                Spacer()
                Button(ready ? "Get Started" : "Done") { finish() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 540)
        .onAppear { model.refreshDiskAccess(); model.helper.refresh(); model.schedule.refresh() }
    }

    private var ready: Bool { model.fullDiskAccess && model.helper.isEnabled }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "onboarding.completed")
        isPresented = false
    }

    @ViewBuilder
    private func step(_ number: Int, _ title: String, _ description: String,
                      done: Bool, action: (title: String, run: () -> Void)?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : Color.secondary.opacity(0.2)).frame(width: 26, height: 26)
                if done { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white) }
                else { Text("\(number)").font(.caption.bold()).foregroundStyle(.secondary) }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(description).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if done {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
            } else if let action {
                Button(action.title, action: action.run)
            }
        }
    }
}
