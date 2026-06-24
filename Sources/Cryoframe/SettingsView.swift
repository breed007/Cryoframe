//
//  SettingsView.swift
//  Cryoframe (app)
//
//  Standard macOS Settings (Cmd-,): defaults for new jobs, and the background
//  schedule service.
//

import SwiftUI
import AppKit
import CryoframeKit

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            ScheduleSettings().tabItem { Label("Schedule", systemImage: "clock") }
        }
        .frame(width: 460, height: 320)
    }
}

private struct GeneralSettings: View {
    @AppStorage(Prefs.format) private var format = "dmg"
    @AppStorage(Prefs.verify) private var verify = VerificationPolicy.checksumOnly.rawValue
    @AppStorage(Prefs.runPolicy) private var runPolicy = RunPolicy.proceed.rawValue
    @AppStorage(Prefs.archiveDir) private var archiveDir = ""
    @AppStorage(Prefs.mirrorGB) private var mirrorGB = 500

    var body: some View {
        Form {
            Section("Defaults for new jobs") {
                Picker("Format", selection: $format) {
                    Text("Sealed DMG").tag("dmg")
                    Text("Sealed zip").tag("zip")
                    Text("Live mirror").tag("mirror")
                }
                if format == "mirror" {
                    Stepper("Mirror size: \(mirrorGB) GB", value: $mirrorGB, in: 50...8000, step: 50)
                }
                Picker("Verify", selection: $verify) {
                    Text("Checksum").tag(VerificationPolicy.checksumOnly.rawValue)
                    Text("Mount & open").tag(VerificationPolicy.mountAndOpen.rawValue)
                }
                Picker("If app is open", selection: $runPolicy) {
                    Text("Proceed").tag(RunPolicy.proceed.rawValue)
                    Text("Warn").tag(RunPolicy.warnIfRunning.rawValue)
                    Text("Defer").tag(RunPolicy.deferIfRunning.rawValue)
                }
            }
            Section("Default archive location") {
                HStack {
                    Text(archiveDir.isEmpty ? "~/Documents/Cryoframe Archives" : archiveDir)
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…") { chooseDir() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { archiveDir = url.path }
    }
}

private struct ScheduleSettings: View {
    @StateObject private var schedule = ScheduleManager()

    var body: some View {
        Form {
            Section("Background schedule") {
                HStack {
                    Text("Agent:"); Text(schedule.statusText).foregroundStyle(.secondary)
                    Spacer()
                    if schedule.isEnabled { Button("Disable") { try? schedule.unregister() } }
                    else { Button("Enable") { try? schedule.register() } }
                    Button("Refresh") { schedule.refresh() }
                }
            }
            Section {
                Text("When enabled, Cryoframe wakes about once an hour to run any jobs that are due. Jobs only run while you're logged in. Use Run now in the main window to run a job immediately.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
