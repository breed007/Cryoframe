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
        }
        .defaultSize(width: 640, height: 680)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.updater.checkForUpdates() }
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
