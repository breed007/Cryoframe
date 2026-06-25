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
    @AppStorage("settings.selectedTab") private var tab = "General"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag("General")
            LibrariesSettings().tabItem { Label("Libraries", systemImage: "books.vertical") }.tag("Libraries")
            TransferSettings().tabItem { Label("Transfers", systemImage: "arrow.up.arrow.down") }.tag("Transfers")
            EscrowView().tabItem { Label("Security", systemImage: "key.fill") }.tag("Security")
            ScheduleSettings().tabItem { Label("Schedule", systemImage: "clock") }.tag("Schedule")
        }
        .frame(width: 500, height: 440)
    }
}

private struct TransferSettings: View {
    @AppStorage(Prefs.transferChunkValue) private var chunkValue = 2
    @AppStorage(Prefs.transferChunkUnit) private var chunkUnit = "GB"
    @AppStorage(Prefs.scratchDir) private var scratchDir = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Part size")
                    Spacer()
                    TextField("", value: $chunkValue, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                        .onChange(of: chunkValue) { _, v in if v < 1 { chunkValue = 1 } }
                    Picker("", selection: $chunkUnit) {
                        Text("GB").tag("GB")
                        Text("TB").tag("TB")
                    }
                    .labelsHidden()
                    .frame(width: 72)
                }
                HStack {
                    Text("Scratch location")
                    Spacer()
                    Text(scratchDir.isEmpty ? "System cache (default)" : scratchDir)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(scratchDir)
                    Button("Change…") { chooseScratch() }
                    if !scratchDir.isEmpty { Button("Reset") { scratchDir = "" } }
                }
            } header: {
                Text("Resumable transfers")
            } footer: {
                Text("Sealed archives sent to a network share or external drive are built locally in the scratch location, then shipped in parts of this size. A dropped transfer resumes from the last completed part. The scratch location needs about one archive of free space.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseScratch() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { scratchDir = url.path }
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
    @AppStorage(Prefs.format) private var format = "mirror"
    @AppStorage(Prefs.verify) private var verify = VerificationPolicy.checksumOnly.rawValue
    @AppStorage(Prefs.runPolicy) private var runPolicy = RunPolicy.proceed.rawValue
    @AppStorage(Prefs.archiveDir) private var archiveDir = ""
    @AppStorage(Prefs.mirrorGB) private var mirrorGB = 500
    @AppStorage(Prefs.mirrorUnit) private var mirrorUnit = "GB"
    @AppStorage(Prefs.maxConcurrent) private var maxConcurrent = 2
    @AppStorage(Prefs.keepAwake) private var keepAwake = true
    @AppStorage(Prefs.wakeForSchedule) private var wakeForSchedule = false
    @AppStorage(Prefs.notifyPolicy) private var notifyPolicy = "failure"
    @AppStorage(Prefs.healthInterval) private var healthInterval = "off"
    @AppStorage(Prefs.healthScope) private var healthScope = "latest"

    var body: some View {
        Form {
            Section {
                Stepper("Maximum jobs running at once: \(maxConcurrent)", value: $maxConcurrent, in: 1...8)
                Toggle("Keep the Mac awake while a backup runs", isOn: $keepAwake)
                Toggle("Wake the Mac for scheduled backups", isOn: $wakeForSchedule)
                    .onChange(of: wakeForSchedule) { Task { await WakeScheduler.arm() } }
            } header: {
                Text("Running")
            } footer: {
                Text("Keeping awake prevents idle sleep during a run. Waking for a schedule changes the system power schedule and asks the helper for permission; it can't wake a Mac that's shut down or one with its lid closed.")
            }
            Section {
                Picker("Notify me", selection: $notifyPolicy) {
                    Text("Never").tag("never")
                    Text("On failure").tag("failure")
                    Text("On every run").tag("all")
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("Cryoframe stays in the menu bar so it can notify you of scheduled-run results even when the window is closed. Quit it from the menu bar to stop.")
            }
            Section {
                Picker("Re-verify archives", selection: $healthInterval) {
                    Text("Off").tag("off")
                    Text("Weekly").tag("weekly")
                    Text("Monthly").tag("monthly")
                }
                Picker("Scope", selection: $healthScope) {
                    Text("Latest version only").tag("latest")
                    Text("All versions").tag("all")
                }
            } header: {
                Text("Archive health")
            } footer: {
                Text("Periodically re-checks existing archives against their checksums to catch corruption (bit rot) before a restore needs them. \"Latest version only\" keeps the I/O down on large versioned jobs. You can also verify a job's archives any time from its ⋯ menu.")
            }
            Section("Defaults for new jobs") {
                Picker("Format", selection: $format) {
                    Text("Live mirror").tag("mirror")
                    Text("Sealed zip").tag("zip")
                    Text("Sealed DMG").tag("dmg")
                }
                if format == "mirror" {
                    HStack {
                        Text("Mirror size")
                        Spacer()
                        TextField("", value: $mirrorGB, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 64)
                            .onChange(of: mirrorGB) { _, v in if v < 1 { mirrorGB = 1 } }
                        Picker("", selection: $mirrorUnit) {
                            Text("GB").tag("GB")
                            Text("TB").tag("TB")
                        }
                        .labelsHidden()
                        .frame(width: 72)
                    }
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
