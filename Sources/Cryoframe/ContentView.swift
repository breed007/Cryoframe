//
//  ContentView.swift
//  Cryoframe (app)
//
//  The product UI: system services, the job list with live status + verification
//  results, and an activity log. Status colors follow the brand spec —
//  blue = in progress, green = verified/sealed, red = failed.
//

import SwiftUI
import AppKit
import CryoframeKit

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var showNewJob = false
    @State private var showHelp = false
    @State private var showHistory = false
    @State private var editingJob: BackupJob?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().frame(width: 38, height: 38)
                Text("Cryoframe").font(.largeTitle.bold())
                Spacer()
                Button { showHistory = true } label: { Label("History", systemImage: "clock.arrow.circlepath") }
                    .help("Past runs, including scheduled ones")
                Button { showHelp = true } label: { Label("Help", systemImage: "questionmark.circle") }
                    .help("How to use Cryoframe, with examples")
            }

            systemStatus
            Divider()

            if model.jobs.isEmpty {
                Spacer()
                emptyState
                Spacer()
            } else {
                HStack {
                    Text("Jobs").font(.title3.bold())
                    Spacer()
                    Button { showNewJob = true } label: { Label("New Job", systemImage: "plus") }
                }
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.jobs) { JobRow(model: model, job: $0, onEdit: { editingJob = $0 }) }
                    }
                }.frame(maxHeight: 260)
                if !model.activity.isEmpty {
                    Divider()
                    activity
                }
                Spacer(minLength: 0)
            }
        }
        .padding(20)
        .frame(width: 640, height: 680)
        .sheet(isPresented: $showNewJob) { NewJobSheet(model: model, isPresented: $showNewJob) }
        .sheet(item: $editingJob) { job in
            NewJobSheet(model: model,
                        isPresented: Binding(get: { editingJob != nil }, set: { if !$0 { editingJob = nil } }),
                        editing: job)
        }
        .sheet(isPresented: $showHelp) { HelpView(isPresented: $showHelp) }
        .sheet(isPresented: $showHistory) { HistoryView(model: model, isPresented: $showHistory) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.refreshDiskAccess(); model.revalidate(); model.resumeTransfers()
                model.reloadHistory()      // pick up any scheduled runs since we last looked
            }
        }
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

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().frame(width: 104, height: 104).opacity(0.95)
            Text("No backup jobs yet").font(.title3.weight(.medium))
            Text("Create a job to freeze a library with an APFS snapshot and archive it on a schedule.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
            Button { showNewJob = true } label: { Label("New Job", systemImage: "plus") }
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Activity").font(.headline)
                if !model.runningJobIDs.isEmpty {
                    ProgressView().controlSize(.small)
                    Text("\(model.runningJobIDs.count) running").font(.caption).foregroundStyle(.blue)
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
    let onEdit: (BackupJob) -> Void

    private var isRunning: Bool { model.isRunning(job.id) }
    private var isQueued: Bool { model.isQueued(job.id) }
    private var librarySummary: String {
        let names = job.libraries.map(\.displayName)
        return names.count <= 2 ? names.joined(separator: ", ")
                                : "\(names.prefix(2).joined(separator: ", ")) +\(names.count - 2)"
    }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(job.name).font(.callout.bold())
                    statusBadge
                }
                Text("\(librarySummary) → \(job.target.displayName)  ·  \(job.format.label)")
                    .font(.caption).foregroundStyle(.secondary)
                libraryStatusRow
                progressRow
                lastRunRow
                HStack(spacing: 10) {
                    Text(job.frequency.label).font(.caption2)
                    if job.enabled, let due = model.nextDue(job) {
                        Text("next: \(due.formatted(date: .abbreviated, time: .shortened))").font(.caption2)
                    }
                    let owners = model.openOwners(job)
                    if !owners.isEmpty {
                        Text("⚠︎ \(owners.joined(separator: ", ")) open").font(.caption2).foregroundStyle(.orange)
                    }
                }.foregroundStyle(.tertiary)
            }
            Spacer()
            VStack(spacing: 6) {
                if isRunning {
                    if model.isPaused(job.id) {
                        Button("Resume") { model.resumeJob(job.id) }
                    } else if model.canPause(job) {
                        Button("Pause") { model.pauseJob(job.id) }
                    }
                    Button("Stop") { model.stopJob(job.id) }
                } else if isQueued {
                    Button("Stop") { model.stopJob(job.id) }
                } else {
                    Button("Run now") { model.runNow(job) }.disabled(!model.helper.isEnabled)
                }
                Menu {
                    Button("Edit…") { onEdit(job) }
                    Button(job.enabled ? "Disable schedule" : "Enable schedule") { model.setEnabled(job, !job.enabled) }
                    Divider()
                    Button("Delete", role: .destructive) { model.deleteJob(job.id) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    @ViewBuilder private var libraryStatusRow: some View {
        switch model.jobValid[job.id] {
        case .some(true):
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2).foregroundStyle(.green).help("Library found at its path")
        case .some(false):
            HStack(spacing: 6) {
                Label("library not found", systemImage: "xmark.circle.fill")
                    .font(.caption2).foregroundStyle(.red)
                if model.isBuiltInLibrary(job) {
                    Button("Fix in Settings") { model.openLibrarySettings() }
                        .font(.caption2).buttonStyle(.link)
                }
            }
        case .none:
            EmptyView()                       // unknown without Full Disk Access
        }
    }

    @ViewBuilder private var progressRow: some View {
        if isRunning, let p = model.jobProgress[job.id] {
            VStack(alignment: .leading, spacing: 2) {
                if let f = p.fraction {
                    ProgressView(value: f).frame(maxWidth: 240)
                } else {
                    ProgressView().controlSize(.small)
                }
                HStack(spacing: 8) {
                    Text(p.detail).font(.caption2).foregroundStyle(.secondary)
                    if p.libraryCount > 1, let lib = model.jobLibrary[job.id] {
                        Text("· \(lib) (\(p.libraryIndex)/\(p.libraryCount))").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                if !model.isPaused(job.id), p.speed != nil || p.elapsed != nil {
                    HStack(spacing: 8) {
                        if let s = p.speed, s > 0 { Text(Self.rate(s)) }
                        if let e = p.elapsed { Text("\(Self.duration(e)) elapsed") }
                        if let eta = p.eta, eta.isFinite, eta > 0 { Text("~\(Self.duration(eta)) left") }
                    }
                    .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder private var statusBadge: some View {
        if isRunning && model.isPaused(job.id) {
            badge("paused", .orange)
        } else if isRunning {
            let pct = model.jobProgress[job.id]?.fraction.map { " \(Int($0 * 100))%" } ?? ""
            badge((model.jobStage[job.id]?.rawValue ?? "running") + pct, .blue)
        } else if isQueued {
            badge("queued", .blue)
        } else if !job.enabled {
            badge("disabled", .gray)
        } else if let r = model.lastRecords[job.id] {
            switch r.outcome {
            case .verified, .completed: badge(r.summary, .green)
            case .deferred:             badge("deferred", .orange)
            case .cancelled:            badge("stopped", .orange)
            case .failed:               badge(r.summary, .red)
            }
        } else {
            EmptyView()
        }
    }

    @ViewBuilder private var lastRunRow: some View {
        if !isRunning, !isQueued, let r = model.lastRecords[job.id] {
            HStack(spacing: 6) {
                Text("Last run:").foregroundStyle(.tertiary)
                Text("\(AppModel.symbol(r.outcome)) \(r.summary)").foregroundStyle(outcomeColor(r.outcome))
                Text("· \(Self.duration(r.duration))").foregroundStyle(.tertiary)
                if r.bytes > 0 { Text("· \(Self.size(r.bytes))").foregroundStyle(.tertiary) }
                Text("· \(r.finishedAt.formatted(.relative(presentation: .named)))").foregroundStyle(.tertiary)
            }
            .font(.caption2)
        }
    }

    static func rate(_ bytesPerSec: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSec), countStyle: .file) + "/s"
    }

    /// h:mm:ss when over an hour, else m:ss.
    static func duration(_ seconds: TimeInterval) -> String {
        let t = max(0, Int(seconds.rounded()))
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}

private func outcomeColor(_ kind: RunOutcomeKind) -> Color {
    switch kind {
    case .verified, .completed: return .green
    case .failed:               return .red
    case .deferred, .cancelled: return .orange
    }
}

// MARK: - History

private struct HistoryView: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Run History").font(.title2.bold())
                Spacer()
                Button("Done") { isPresented = false }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()

            let records = model.runHistory()
            if records.isEmpty {
                Spacer()
                Text("No runs yet — they'll show here once a job runs, including scheduled ones.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(records) { r in
                            HistoryRow(record: r)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(width: 560, height: 540)
    }
}

private struct HistoryRow: View {
    let record: RunRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(AppModel.symbol(record.outcome)).foregroundStyle(outcomeColor(record.outcome))
                Text(record.jobName).font(.callout.bold())
                if record.trigger == "scheduled" {
                    Text("scheduled").font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(record.finishedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Text(record.summary).foregroundStyle(outcomeColor(record.outcome))
                Text(JobRow.duration(record.duration)).foregroundStyle(.tertiary)
                if record.bytes > 0 { Text(JobRow.size(record.bytes)).foregroundStyle(.tertiary) }
            }
            .font(.caption)
            if let w = record.warning {
                Text("⚠︎ \(w)").font(.caption2).foregroundStyle(.orange)
            }
            ForEach(record.libraries) { lib in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("·").foregroundStyle(.tertiary)
                        Text(lib.library)
                        Text(lib.status).foregroundStyle(statusColor(lib.status))
                        if lib.bytes > 0 { Text(JobRow.size(lib.bytes)).foregroundStyle(.tertiary) }
                        if lib.parts > 1 { Text("\(lib.parts) parts").foregroundStyle(.tertiary) }
                    }
                    if let e = lib.error {
                        Text(e).foregroundStyle(.red).lineLimit(3).padding(.leading, 12)
                    }
                }
                .font(.caption2)
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "verified", "archived": return .green
        case "failed", "verify failed": return .red
        case "not found": return .orange
        default: return .secondary
        }
    }
}
