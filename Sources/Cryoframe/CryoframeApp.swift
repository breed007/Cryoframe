//
//  CryoframeApp.swift
//  Cryoframe (app)
//

import SwiftUI

struct CryoframeApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(model: model)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            Image(systemName: model.menuBarSymbol)
        }

        Settings {
            SettingsView()
        }
    }
}
