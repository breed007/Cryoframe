//
//  MenuBarView.swift
//  Cryoframe (app)
//
//  The menu-bar status item: a glance at each job's last run, plus open/quit. Its
//  presence keeps Cryoframe resident so it can notify you of scheduled-run results
//  even when the window is closed.
//

import SwiftUI
import AppKit
import CryoframeKit
import Sparkle

struct MenuBarView: View {
    @ObservedObject var model: AppModel
    let updater: SPUUpdater
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.jobs.isEmpty {
            Text("No backup jobs yet")
        } else {
            ForEach(model.jobs) { job in
                Text(statusLine(job))
            }
        }
        if !model.runningJobIDs.isEmpty {
            Divider()
            Text("\(model.runningJobIDs.count) running")
        }
        Divider()
        if !model.jobs.isEmpty {
            Button("Verify all archives") { model.verifyAllArchives() }
        }
        Button("Open Cryoframe") { openMain() }
        Button("Check for Updates…") { updater.checkForUpdates() }
        Button("Quit Cryoframe") { NSApplication.shared.terminate(nil) }
    }

    private func statusLine(_ job: BackupJob) -> String {
        if model.isPaused(job.id) { return "⏸ \(job.name): paused" }
        if model.isRunning(job.id) {
            let pct = model.jobProgress[job.id]?.fraction.map { " \(Int($0 * 100))%" } ?? ""
            return "● \(job.name): \(model.jobStage[job.id]?.rawValue ?? "running")\(pct)"
        }
        if let r = model.lastRecords[job.id] { return "\(AppModel.symbol(r.outcome)) \(job.name): \(r.summary)" }
        return "○ \(job.name): no runs yet"
    }

    private func openMain() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }
}
