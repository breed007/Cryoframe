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
            LibrariesSettings().tabItem { Label("Libraries", systemImage: "books.vertical") }
            ScheduleSettings().tabItem { Label("Schedule", systemImage: "clock") }
        }
        .frame(width: 500, height: 440)
    }
}

private struct LibrariesSettings: View {
    @State private var overrides = LibraryOverrides.loadRaw()

    var body: some View {
        Form {
            Section("Built-in library locations") {
                ForEach(ContentTypeRegistry.builtIns) { type in row(type) }
            }
            Section {
                Button("Restore all defaults") { LibraryOverrides.resetAll(); overrides = [:] }
                    .disabled(overrides.isEmpty)
            } footer: {
                Text("Repoint a built-in library if it lives somewhere other than its default location, such as an external drive. The owning app and integrity check stay attached.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func row(_ type: ContentType) -> some View {
        let defaultPath = type.paths.first?.liveURL(home: NSHomeDirectory()).path ?? ""
        let current = overrides[type.id] ?? defaultPath
        let isCustom = overrides[type.id] != nil
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(type.displayName)
                    if isCustom {
                        Text("custom").font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(current).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(current)
            }
            Spacer()
            Button("Change…") { change(type) }
            if isCustom { Button("Reset") { LibraryOverrides.reset(id: type.id); overrides = LibraryOverrides.loadRaw() } }
        }
        .padding(.vertical, 2)
    }

    private func change(_ type: ContentType) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true            // a .photoslibrary is a package (a file to the panel)
        panel.allowsMultipleSelection = false
        panel.message = "Choose the \(type.displayName) library"
        if panel.runModal() == .OK, let url = panel.url {
            LibraryOverrides.set(id: type.id, path: url.path)
            overrides = LibraryOverrides.loadRaw()
        }
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
