//
//  CryoframeApp.swift
//  Cryoframe (app)
//

import SwiftUI

struct CryoframeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
        }
    }
}
