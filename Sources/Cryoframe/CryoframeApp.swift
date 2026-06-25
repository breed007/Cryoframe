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
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.updater.checkForUpdates() }
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
