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
import UniformTypeIdentifiers
import CryoframeKit

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var droppedFolder: URL?
    @State private var showOnboarding = false
    @AppStorage("onboarding.completed") private var onboardingCompleted = false
    @State private var editingJob: BackupJob?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().frame(width: 38, height: 38)
                Text("Cryoframe").font(.title2.bold()).lineLimit(1).fixedSize()
                Spacer()
                Button { model.showRestore = true } label: { Label("Restore", systemImage: "arrow.uturn.backward.circle") }
                    .help("Restore a library from an archive")
                Button { model.showStorage = true } label: { Label("Storage", systemImage: "internaldrive") }
                    .help("Space used by archives, and free space on each target")
                Button { model.showHistory = true } label: { Label("History", systemImage: "clock.arrow.circlepath") }
                    .help("Past runs, including scheduled ones")
                Button { model.showHelp = true } label: { Label("Help", systemImage: "questionmark.circle") }
                    .help("How to use Cryoframe, with examples")
            }

            systemStatus
            Divider()

            if model.jobs.isEmpty {
                Spacer()
                emptyState
                Spacer()
            } else {
                ProtectionDashboard(model: model, onNewJob: { model.showNewJob = true })
                CoverageCard(model: model)
                HStack {
                    Text("Jobs").font(.headline).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(model.jobs.count) backup \(model.jobs.count == 1 ? "job" : "jobs")")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.jobs) { JobRow(model: model, job: $0, onEdit: { editingJob = $0 }) }
                    }
                }
                // the jobs ARE the window — never let the coverage card and the
                // activity log squeeze them out. At the default size with a card
                // showing, this list used to collapse to nothing.
                .frame(minHeight: 132, maxHeight: .infinity)
                if !model.activity.isEmpty {
                    Divider()
                    activity
                }
            }
        }
        .padding(20)
        // tall enough that the dashboard, a coverage card, at least one job row,
        // and the activity log all fit without anything collapsing.
        .frame(minWidth: 600, minHeight: 620)
        .sheet(isPresented: $model.showNewJob) {
            NewJobWizard(model: model, isPresented: $model.showNewJob,
                         initialFolder: droppedFolder, initialLibraryID: model.newJobLibraryID)
        }
        .onChange(of: model.showNewJob) { _, open in if !open { droppedFolder = nil; model.newJobLibraryID = nil } }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.hasDirectoryPath || url.pathExtension.hasSuffix("library") else { return }
                DispatchQueue.main.async { droppedFolder = url; model.showNewJob = true }   // drop a folder → guided setup
            }
            return true
        }
        .sheet(item: $editingJob) { job in
            NewJobSheet(model: model,
                        isPresented: Binding(get: { editingJob != nil }, set: { if !$0 { editingJob = nil } }),
                        editing: job)
        }
        .sheet(isPresented: $model.showHelp) { HelpView(isPresented: $model.showHelp) }
        .sheet(isPresented: $model.showHistory) { HistoryView(model: model, isPresented: $model.showHistory) }
        .sheet(isPresented: $model.showRestore) { RestoreView(model: model, isPresented: $model.showRestore) }
        .sheet(isPresented: $model.showRecovery) { RecoveryWizard(model: model, isPresented: $model.showRecovery) }
        .sheet(isPresented: $model.showStorage) { StorageView(model: model, isPresented: $model.showStorage) }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(model: model, isPresented: $showOnboarding,
                           onGetStarted: { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { model.showNewJob = true } })
        }
        .onAppear {
            if !onboardingCompleted { showOnboarding = true }   // shown once; "Get Started" marks it done
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.refreshDiskAccess(); model.revalidate(); model.resumeTransfers()
                model.reloadHistory()      // pick up any scheduled runs since we last looked
                model.reloadHealth()
                model.refreshProtectedSize()
                model.measureLibraries(model.coverageGaps.compactMap { g in
                    model.registry.types.first { $0.id == g.typeID }
                })
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
                .foregroundStyle(model.fullDiskAccess ? .cryoGood : .cryoCrit)
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
            Circle().fill(enabled ? .cryoGood : .cryoWarn).frame(width: 8, height: 8)
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
            Text("Create a job to freeze a library with an APFS snapshot and archive it on a schedule — or drop a folder here to start.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
            Button { model.showNewJob = true } label: { Label("New Job", systemImage: "plus") }
                .controlSize(.large)
            // a Mac with no jobs is often a NEW Mac — the person may be here to get
            // their libraries back, not to set up a backup.
            Button("Already have backups? Recover them…") { model.showRecovery = true }
                .buttonStyle(.link).font(.callout)
            if !(model.helper.isEnabled && model.fullDiskAccess) {
                Button("Setup guide…") { showOnboarding = true }.controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Activity").font(.headline)
                if !model.runningJobIDs.isEmpty {
                    ProgressView().controlSize(.small)
                    Text("\(model.runningJobIDs.count) running").font(.caption).foregroundStyle(.cryoAccent)
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

    private var destinationSummary: String {
        let names = job.targets.map(\.displayName)
        return names.count == 1 ? names[0] : "\(names[0]) +\(names.count - 1)"
    }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(job.name).font(.callout.bold())
                    statusBadge
                }
                HStack(spacing: 5) {
                    Text("\(librarySummary) → \(destinationSummary)  ·  \(job.format.label)")
                        .font(.caption).foregroundStyle(.secondary)
                    if job.encrypted {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                            .help("Encrypted with AES-256")
                    }
                }
                libraryStatusRow
                progressRow
                lastRunRow
                healthRow
                HStack(spacing: 10) {
                    Text(job.frequency.label).font(.caption2)
                    if job.enabled, let due = model.nextDue(job) {
                        Text("next: \(due.formatted(date: .abbreviated, time: .shortened))").font(.caption2)
                    }
                    let owners = model.openOwners(job)
                    if !owners.isEmpty {
                        Text("⚠︎ \(owners.joined(separator: ", ")) open").font(.caption2).foregroundStyle(.cryoWarn)
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
                    Button("Verify archives") { model.verifyArchives(job) }
                        .disabled(model.verifyingJobIDs.contains(job.id))
                    Button("Run restore drill…") { model.drillArchives(job) }
                        .disabled(model.verifyingJobIDs.contains(job.id))
                        .help("Reassemble, open, and reopen each archive — proves it actually restores")
                    if model.hasStoredPassphrase(job) {
                        Button("Copy passphrase") { model.copyPassphrase(job) }
                    }
                    Button(job.enabled ? "Disable schedule" : "Enable schedule") { model.setEnabled(job, !job.enabled) }
                    Divider()
                    Button("Delete", role: .destructive) { model.deleteJob(job.id) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("More actions for \(job.name)")
            }
        }
        .cryoCard(padding: 12)
        // a status stripe on the leading edge, so a row's state reads from the same
        // vocabulary as the dashboard ring above it — shape and position, not color alone.
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(rowTint)
                .frame(width: 3)
                .padding(.vertical, 10).padding(.leading, 1)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(job.name), \(librarySummary) to \(destinationSummary)")
    }

    /// the row's state in one color: running, else the last run's outcome.
    private var rowTint: Color {
        if isRunning || isQueued { return .cryoAccent }
        if let r = model.lastRecords[job.id] { return outcomeColor(r.outcome) }
        return .secondary.opacity(0.35)
    }

    @ViewBuilder private var libraryStatusRow: some View {
        switch model.jobValid[job.id] {
        case .some(true):
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2).foregroundStyle(.cryoGood).help("Library found at its path")
        case .some(false):
            HStack(spacing: 6) {
                Label("library not found", systemImage: "xmark.circle.fill")
                    .font(.caption2).foregroundStyle(.cryoCrit)
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
            badge("paused", .cryoWarn)
        } else if isRunning {
            let pct = model.jobProgress[job.id]?.fraction.map { " \(Int($0 * 100))%" } ?? ""
            badge((model.jobStage[job.id]?.rawValue ?? "running") + pct, .cryoAccent)
        } else if isQueued {
            badge("queued", .cryoAccent)
        } else if !job.enabled {
            badge("disabled", .gray)
        } else if let r = model.lastRecords[job.id] {
            switch r.outcome {
            case .verified, .completed: badge(r.summary, .cryoGood)
            case .partial:              badge(r.summary, .cryoWarn)
            case .deferred:             badge("deferred", .cryoWarn)
            case .cancelled:            badge("stopped", .cryoWarn)
            case .failed:               badge(r.summary, .cryoCrit)
            }
        } else {
            EmptyView()
        }
    }

    @ViewBuilder private var healthRow: some View {
        if model.verifyingJobIDs.contains(job.id) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking archives…").foregroundStyle(.secondary)
            }.font(.caption2)
        } else if let h = model.lastHealth[job.id] {
            HStack(spacing: 6) {
                if h.archivesChecked == 0 && h.skipped > 0 {
                    Image(systemName: "cloud").foregroundStyle(.secondary)
                    Text("\(h.skipped) cloud archive\(h.skipped == 1 ? "" : "s") not downloaded").foregroundStyle(.secondary)
                } else if h.archivesChecked == 0 {
                    Image(systemName: "questionmark.circle.fill").foregroundStyle(.cryoWarn)
                    Text("No archives found to check").foregroundStyle(.secondary)
                } else {
                    Image(systemName: h.passed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(h.passed ? .cryoGood : .cryoCrit)
                    Text((h.passed ? "\(h.isDrill ? "Restore-drilled" : "Archives verified") (\(h.archivesChecked))"
                                   : "\(h.failures.count) \(h.isDrill ? "restore drill" : "archive") check(s) failed")
                         + (h.skipped > 0 ? " · \(h.skipped) skipped" : ""))
                        .foregroundStyle(h.passed ? Color.secondary : Color.cryoCrit)
                }
                Text("· \(h.checkedAt.formatted(.relative(presentation: .named)))").foregroundStyle(.tertiary)
            }
            .font(.caption2)
            .help(h.archivesChecked == 0 ? "Nothing was checked — the target may be offline, or the job hasn't run yet."
                  : (h.passed ? (h.isDrill ? "Reassembled, opened, and reopened each archive" : "Re-verified against checksums") : h.failures.joined(separator: "\n")))
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
    case .verified, .completed:        return .cryoGood
    case .partial, .deferred, .cancelled: return .cryoWarn
    case .failed:                      return .cryoCrit
    }
}

// MARK: - History

private struct HistoryView: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            CryoSheetHeader(title: "Run History", symbol: "clock.arrow.circlepath",
                            subtitle: "Every run, manual and scheduled") {
                isPresented = false
            }
            Divider()

            let records = model.runHistory()
            if records.isEmpty {
                CryoEmptyState(symbol: "clock.arrow.circlepath",
                               title: "No runs yet",
                               message: "Once a job runs — by hand or on its schedule — every result lands here.")
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(records) { HistoryRow(record: $0) }
                    }
                    .padding(14)
                }
            }
        }
        .frame(width: 580, height: 560)
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
                Text("⚠︎ \(w)").font(.caption2).foregroundStyle(.cryoWarn)
            }
            ForEach(record.libraries) { lib in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("·").foregroundStyle(.tertiary)
                        Text(lib.destination.isEmpty ? lib.library : "\(lib.library) → \(lib.destination)")
                        Text(lib.status).foregroundStyle(statusColor(lib.status))
                        if lib.bytes > 0 { Text(JobRow.size(lib.bytes)).foregroundStyle(.tertiary) }
                        if lib.parts > 1 { Text("\(lib.parts) parts").foregroundStyle(.tertiary) }
                    }
                    if let e = lib.error {
                        Text(e).foregroundStyle(.cryoCrit).lineLimit(3).padding(.leading, 12)
                    }
                }
                .font(.caption2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cryoCard(padding: 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(record.jobName), \(record.summary), \(record.finishedAt.formatted(date: .abbreviated, time: .shortened))")
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "verified", "archived": return .cryoGood
        case "failed", "verify failed": return .cryoCrit
        case "not found": return .cryoWarn
        default: return .secondary
        }
    }
}
