//
//  CryoframeApp.swift
//  Cryoframe (app)
//

import SwiftUI
import Sparkle

struct CryoframeApp: App {
    @StateObject private var model = AppModel()
    private let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(model: model)
                .tint(.cryoAccent)          // Cryoframe's electric-cyan brand accent, app-wide
        }
        // tall enough that a first run shows an actual job row under the dashboard,
        // rather than opening onto advice with the backups below the fold
        .defaultSize(width: 700, height: 860)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.updater.checkForUpdates() }
            }
            // Everything the toolbar can do, the keyboard can do. macOS puts an
            // empty File menu there by default; these give it a reason to exist.
            CommandGroup(replacing: .newItem) {
                Button("New Job…") { model.showNewJob = true }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Divider()
                Button("Restore…") { model.showRestore = true }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Recover to This Mac…") { model.showRecovery = true }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Storage") { model.showStorage = true }
                    .keyboardShortcut("d", modifiers: .command)
                Button("History") { model.showHistory = true }
                    .keyboardShortcut("y", modifiers: .command)
                Divider()
                Button("Verify All Archives") { model.verifyAllArchives() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                    .disabled(model.jobs.isEmpty)
            }
            // Replace macOS's default "Cryoframe Help" item, which looks for a Help
            // Book we don't ship and errors with "Help isn't available." Point it at
            // the in-app help sheet instead.
            CommandGroup(replacing: .help) {
                Button("Cryoframe Help") {
                    NSApp.activate(ignoringOtherApps: true)
                    model.showHelp = true
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }

        MenuBarExtra {
            MenuBarView(model: model, updater: updater.updater)
        } label: {
            Image(systemName: model.menuBarSymbol)
        }

        Settings {
            SettingsView()
        }
    }
}
