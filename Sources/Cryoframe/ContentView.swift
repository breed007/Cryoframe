//
//  ContentView.swift
//  Cryoframe (app)
//
//  The product UI: system services, the job list with live status + verification
//  results, and an activity log. Status colors follow the brand spec —
//  blue = in progress, green = verified/sealed, red = failed.
//

import SwiftUI
import CryoframeKit

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var showNewJob = false
    @State private var showHelp = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Cryoframe").font(.largeTitle.bold())
                Spacer()
                Button { showHelp = true } label: { Label("Help", systemImage: "questionmark.circle") }
                    .help("How to use Cryoframe, with examples")
            }

            systemStatus
            Divider()

            HStack {
                Text("Jobs").font(.title3.bold())
                Spacer()
                Button { showNewJob = true } label: { Label("New Job", systemImage: "plus") }
            }

            if model.jobs.isEmpty {
                Text("No jobs yet. Create one to back up a library on a schedule.")
                    .foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.jobs) { JobRow(model: model, job: $0) }
                    }
                }.frame(maxHeight: 260)
            }

            Divider()
            activity
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 640, height: 680)
        .sheet(isPresented: $showNewJob) { NewJobSheet(model: model, isPresented: $showNewJob) }
        .sheet(isPresented: $showHelp) { HelpView(isPresented: $showHelp) }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.refreshDiskAccess() } }
    }

    private var systemStatus: some View {
        HStack(spacing: 16) {
            servicePill("Helper", status: model.helper.statusText, enabled: model.helper.isEnabled) {
                try? model.helper.register()
            }
            servicePill("Schedule", status: model.schedule.statusText, enabled: model.schedule.isEnabled) {
                try? model.schedule.register()
            }
            Spacer()
            diskAccessIndicator
        }
    }

    private var diskAccessIndicator: some View {
        HStack(spacing: 6) {
            Image(systemName: model.fullDiskAccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(model.fullDiskAccess ? .green : .red)
            Text("Full Disk Access").font(.caption)
            if !model.fullDiskAccess {
                Button("Grant…") { DiskAccess.openSettings() }.controlSize(.small)
            }
        }
        .help(model.fullDiskAccess
              ? "Cryoframe can read protected libraries."
              : "Grant Full Disk Access in System Settings, then relaunch Cryoframe.")
    }

    private func servicePill(_ title: String, status: String, enabled: Bool, register: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Circle().fill(enabled ? .green : .orange).frame(width: 8, height: 8)
            Text(title).font(.callout.bold())
            Text(status).font(.caption).foregroundStyle(.secondary)
            if !enabled { Button("Enable", action: register).controlSize(.small) }
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Activity").font(.headline)
                if let stage = model.stage {
                    ProgressView().controlSize(.small)
                    Text(stage.rawValue).font(.caption).foregroundStyle(.blue)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.activity.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.frame(height: 120)
        }
    }

    /// shared by NewJobSheet — map a picked folder to a Data-volume LibraryPath.
    static func libraryPath(for url: URL, home: String) -> LibraryPath {
        let p = url.path
        if p == home { return .home("") }
        if p.hasPrefix(home + "/") { return .home(String(p.dropFirst(home.count + 1))) }
        return .absolute(p)
    }
}

private struct JobRow: View {
    @ObservedObject var model: AppModel
    let job: BackupJob

    private var isRunning: Bool { model.runningJobID == job.id }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(job.name).font(.callout.bold())
                    statusBadge
                }
                Text("\(job.contentType.displayName) → \(job.target.displayName)  ·  \(job.format.label)")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Text(job.frequency.label).font(.caption2)
                    if let due = model.nextDue(job) {
                        Text("next: \(due.formatted(date: .abbreviated, time: .shortened))").font(.caption2)
                    }
                    if model.owningAppRunning(job.contentType), let owner = job.contentType.owningProcess {
                        Text("⚠︎ \(owner.displayName) open").font(.caption2).foregroundStyle(.orange)
                    }
                }.foregroundStyle(.tertiary)
            }
            Spacer()
            VStack(spacing: 6) {
                Button("Run now") { model.runNow(job) }
                    .disabled(model.runningJobID != nil || !model.helper.isEnabled)
                Button(role: .destructive) { model.deleteJob(job.id) } label: { Image(systemName: "trash") }
                    .disabled(isRunning)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    @ViewBuilder private var statusBadge: some View {
        if isRunning {
            badge(model.stage?.rawValue ?? "running", .blue)
        } else {
            switch model.lastResults[job.id] {
            case .verified(let s):  badge(s, .green)
            case .completed(let s): badge(s, .green)
            case .deferred:         badge("deferred", .orange)
            case .failed:           badge("failed", .red)
            case .none:             EmptyView()
            }
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}
