//
//  StorageView.swift
//  Cryoframe (app)
//
//  Storage overview: per-job archive usage and free space on each target volume.
//

import SwiftUI
import CryoframeKit

struct StorageView: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    @State private var rows: [JobStorage] = []
    @State private var loading = true
    @State private var trends: [DestinationKey: DestinationTrend] = [:]
    /// cloud destinations' upload state; a key with no value is being looked at
    @State private var uploads: [DestinationKey: UploadSummary] = [:]
    @State private var checking: Set<DestinationKey> = []
    /// a plain-files copy's Removed items to empty, and from before when (nil: all)
    @State private var emptying: (folder: URL, before: Date?, label: String)?

    var body: some View {
        VStack(spacing: 0) {
            CryoSheetHeader(title: "Storage", symbol: "internaldrive",
                            subtitle: "What the archives use, and what's left on each volume") {
                isPresented = false
            }
            Divider()

            if loading {
                Spacer()
                ProgressView("Measuring archives…")
                Spacer()
            } else if rows.allSatisfy({ $0.archiveBytes == 0 }) && trends.isEmpty {
                CryoEmptyState(symbol: "internaldrive",
                               title: "No archives on disk yet",
                               message: "Run a job and its archives — and the space they take — show up here.")
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(rows) { row($0) }
                    }
                    .padding(14)
                }
            }
        }
        .frame(width: 580, height: 500)
        .task { await load() }
        .alert("Delete removed items?", isPresented: Binding(get: { emptying != nil }, set: { if !$0 { emptying = nil } })) {
            Button("Delete", role: .destructive) {
                if let e = emptying {
                    emptying = nil
                    Task {
                        _ = await Task.detached { RemovedItems.delete(in: e.folder, before: e.before) }.value
                        await load()
                    }
                }
            }
            Button("Cancel", role: .cancel) { emptying = nil }
        } message: {
            Text("What was deleted from the library \(emptying?.label ?? "") is deleted from the backup too. This can't be undone.")
        }
    }

    private func load() async {
        let jobs = model.jobs
        let (report, rings) = await Task.detached {
            let keys = DestinationKey.all(jobs)
            UploadLedger.standard().prune(keeping: keys)
            return (StorageReporter.report(jobs), DestinationHealthStore.standard().load(keeping: keys))
        }.value
        rows = report
        trends = rings.compactMapValues { DestinationTrend($0) }
        loading = false
        // then each cloud folder's uploads, which may take a few seconds a file
        for job in jobs {
            for t in job.targets where t.kind == .cloudSync {
                await checkUploads(job: job, target: t, whole: false)
            }
        }
    }

    private func checkUploads(job: BackupJob, target: Target, whole: Bool) async {
        let key = DestinationKey(jobID: job.id, targetID: target.id)
        checking.insert(key)
        let summary = await Task.detached {
            let check = UploadCheck(ledger: .standard())
            return whole ? check.rescan(job: job, target: target) : check.refresh(job: job, target: target)
        }.value
        uploads[key] = summary
        checking.remove(key)
    }

    @ViewBuilder private func row(_ s: JobStorage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(s.jobName).font(.callout.bold())
                Spacer()
                Text(size(s.archiveBytes)).font(.callout).monospacedDigit()
            }
            if let free = s.volumeFree, let total = s.volumeTotal, total > 0 {
                ProgressView(value: Double(total - free), total: Double(total))
                    .tint(usageColor(free: free, total: total))
                Text("\(size(free)) free of \(size(total)) on the volume")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if s.archives.isEmpty {
                Text("\(s.targetName) · \(s.contentsSummary)").font(.caption).foregroundStyle(.secondary)
            } else {
                DisclosureGroup("\(s.targetName) · \(s.contentsSummary)") {
                    ForEach(s.archives) { a in
                        HStack {
                            Text(a.version.map { "\(a.library) · \($0.formatted(date: .abbreviated, time: .shortened))" } ?? a.library)
                            if a.kept {
                                Text("Kept").font(.caption2.weight(.semibold)).padding(.horizontal, 5)
                                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                                    .help("Kept from before its job changed kind: nothing deletes it.")
                            }
                            Spacer()
                            if let removed = a.removedItems { emptyMenu(removed) }
                            Text(size(a.bytes)).monospacedDigit()
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
            let key = DestinationKey(jobID: s.jobID, targetID: s.targetID)
            if let trend = trends[key] { trendRow(trend) }
            if let job = model.jobs.first(where: { $0.id == s.jobID }),
               let target = job.targets.first(where: { $0.id == s.targetID }), target.kind == .cloudSync {
                uploadRow(job: job, target: target, key: key)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cryoCard(padding: 13)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(s.jobName), \(size(s.archiveBytes)) backed up on \(s.targetName)")
    }

    /// Delete what a plain-files copy kept of what was deleted from its library, from
    /// before a day (see RemovedItems): nothing else ever deletes it.
    private func emptyMenu(_ removed: URL) -> some View {
        Menu("Delete…") {
            let now = Date(), cal = Calendar.current
            Button("Older than 30 days") { emptying = (removed, cal.date(byAdding: .day, value: -30, to: now), "more than 30 days ago") }
            Button("Older than 90 days") { emptying = (removed, cal.date(byAdding: .day, value: -90, to: now), "more than 90 days ago") }
            Button("Older than a year") { emptying = (removed, cal.date(byAdding: .year, value: -1, to: now), "more than a year ago") }
            Divider()
            Button("All of them") { emptying = (removed, nil, "at any time") }
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Removed items are what was deleted from the library, kept beside its copy until you delete them here.")
    }

    /// "Last 30 runs: 29 good, 1 failed", a bar per run, and a gray note when the
    /// latest took much longer than usual (information, not a problem)
    @ViewBuilder private func trendRow(_ trend: DestinationTrend) -> some View {
        HStack(spacing: 8) {
            Text(trend.line).font(.caption).foregroundStyle(trend.failed > 0 ? Color.cryoWarn : .secondary)
            RunSparkline(runs: trend.runs)
            Spacer()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(trend.line + (trend.slowerThanUsual ? ". The last run was slower than usual." : ""))
        if trend.slowerThanUsual {
            Text("The last run was slower than usual: over twice the time of the runs before it.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// whether a cloud folder's backups have reached the cloud, as far as can be told
    @ViewBuilder private func uploadRow(job: BackupJob, target: Target, key: DestinationKey) -> some View {
        let provider = target.cloudProvider ?? CloudProvider.identify(target.destinationDir)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if checking.contains(key) {
                ProgressView().controlSize(.mini)
                Text("Checking whether the backups here are uploaded…").font(.caption).foregroundStyle(.secondary)
            } else if let summary = uploads[key] {
                let (text, color) = uploadText(summary, provider: provider)
                Text(text).font(.caption).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Button("Check Again") { Task { await checkUploads(job: job, target: target, whole: true) } }
                .controlSize(.small)
                .disabled(checking.contains(key))
                .help("Look at every version in this cloud folder again")
        }
    }

    private func uploadText(_ s: UploadSummary, provider: CloudProvider) -> (String, Color) {
        func versions(_ n: Int) -> String { n == 1 ? "1 version" : "\(n) versions" }
        switch s {
        case .notChecked:
            return ("No versions here to check yet.", .secondary)
        case .uploaded:
            return ("Uploaded: every version here is in the cloud.", .cryoGood)
        case .uploading(let n, let error):
            return ("Uploading: \(versions(n)) not in the cloud yet." + (error.map { " \(provider.displayName) says: \($0)" } ?? ""), .secondary)
        case .notOffsite(let n, let since):
            return ("Not offsite yet: \(versions(n)) still not uploaded, the oldest from \(since.formatted(date: .abbreviated, time: .shortened)). Check that \(provider.displayName) is signed in and syncing.", .cryoWarn)
        case .unknown(let detail):
            return ("Upload not known. " + (detail ?? CloudUpload.unknownText(provider)), .secondary)
        }
    }

    private func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
    private func usageColor(free: UInt64, total: UInt64) -> Color {
        let frac = 1 - Double(free) / Double(total)
        return frac > 0.9 ? .cryoCrit : (frac > 0.75 ? .cryoWarn : .cryoAccent)
    }
}

/// One bar per run, oldest at the left: its height the run's time against the
/// longest shown, gray when good and red when it failed.
private struct RunSparkline: View {
    let runs: [DestinationRun]

    var body: some View {
        let longest = max(runs.map(\.seconds).max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                RoundedRectangle(cornerRadius: 1)
                    .fill(run.good ? Color.secondary.opacity(0.55) : Color.cryoCrit)
                    .frame(width: 3, height: max(2, 14 * run.seconds / longest))
            }
        }
        .frame(height: 14, alignment: .bottom)
        .accessibilityHidden(true)
    }
}
