//
//  JobDeleteSheet.swift
//  Cryoframe (app)
//
//  Deleting a job, said plainly first (see JobRemoval): its backups stay at every
//  destination and Restore still finds them; an encrypted job's passphrase stays in
//  the Keychain; an upload that was interrupted leaves parts nothing can read or
//  tidy up. Cancel is the default. Delete waits while anything uses the job, and
//  if what it would do changed since this was shown, it shows it again instead.
//

import SwiftUI
import AppKit
import CryoframeKit

struct JobDeleteSheet: View {
    @ObservedObject var model: AppModel
    let job: BackupJob
    @Binding var isPresented: Bool
    let onDeleted: () -> Void

    @State private var plan: JobRemoval.Plan?
    @State private var footprint: JobFootprint?
    @State private var refusal: String?
    @State private var working = false

    private var busy: Bool { model.isBusy(job.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete “\(job.name)”?").font(.title3.bold())
            Text("The job stops backing up. Nothing it made is deleted.").font(.callout).foregroundStyle(.secondary)
            if let plan {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(plan.places.enumerated()), id: \.offset) { _, place in placeBlock(place) }
                        if plan.encrypted { encryptedBlock }
                        ForEach(Array(plan.unfinished.enumerated()), id: \.offset) { _, u in unfinishedBlock(u) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 320)
            } else {
                HStack { ProgressView().controlSize(.small); Text("Looking at its destinations…").font(.callout) }
            }
            if busy {
                Label("It's in use: a backup, a check or an upload is running or waiting. Delete it once that's done.",
                      systemImage: "hourglass").font(.caption).foregroundStyle(.cryoWarn)
            }
            if let refusal {
                Label(refusal, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.cryoWarn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.defaultAction)
                Button("Delete job", role: .destructive) { delete() }
                    .disabled(plan == nil || busy || working)
            }
        }
        .padding(22).frame(width: 540)
        .task { await look() }
    }

    private func placeBlock(_ place: JobRemoval.Plan.Place) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(place.name).font(.callout.weight(.semibold))
            if place.dir == nil {
                Text("Not connected. Whatever is there stays; Restore finds it when it's connected.").font(.caption).foregroundStyle(.secondary)
            } else if place.folders.isEmpty {
                Text("Nothing of this job's there yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(place.folders, id: \.path) { f in
                    let measured = footprint?.places.first { $0.dir == place.dir }?.folders.first { $0.url == f }
                    HStack(spacing: 6) {
                        Text("“\(f.lastPathComponent)”").font(.caption)
                        if let m = measured {
                            Text(detail(m)).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("stays; Restore still finds it").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func detail(_ f: JobFootprint.Folder) -> String {
        var parts: [String] = []
        if f.hasCopy { parts.append("an up-to-date copy") }
        if f.versions > 0 { parts.append("\(f.versions) dated version\(f.versions == 1 ? "" : "s")") }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(f.bytes), countStyle: .file))
        return "(" + parts.joined(separator: ", ") + ")"
    }

    private var encryptedBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Encrypted", systemImage: "lock.fill").font(.callout.weight(.semibold))
            Text("The passphrase stays in your Keychain, and Restore offers it for these backups.").font(.caption)
            Text(coverage).font(.caption).foregroundStyle(covered ? Color.secondary : Color.cryoWarn)
                .fixedSize(horizontal: false, vertical: true)
            if model.hasStoredPassphrase(job) {
                Button("Copy passphrase") { model.copyPassphrase(job) }.buttonStyle(.link).font(.caption)
            }
        }
    }

    private var covered: Bool { EscrowFreshness.lastExport()?.jobs[job.id] != nil }

    private var coverage: String {
        if let export = EscrowFreshness.lastExport(), export.jobs[job.id] != nil {
            return "Your recovery file from \(export.exportedAt.formatted(date: .abbreviated, time: .omitted)) holds it. Recovery files you export after this won't: keep that one."
        }
        return "Your recovery file doesn't hold it, and ones you export after this won't. Copy the passphrase into your password manager before you delete the job."
    }

    private func unfinishedBlock(_ u: JobRemoval.Plan.Unfinished) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("An upload to \(u.destination) was interrupted", systemImage: "exclamationmark.triangle").font(.callout.weight(.semibold))
            Text("\(size(u.bytesReached)) of \(size(u.totalBytes)) reached \(u.destination). Restore can't read those parts, and nothing cleans them up once the job is gone; delete the folder yourself when you like.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([u.dir]) }.buttonStyle(.link).font(.caption)
        }
    }

    private func size(_ b: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file) }

    private func look() async {
        plan = await model.removalPlan(for: job)
        footprint = await model.footprint(of: job)
    }

    private func delete() {
        guard let plan else { return }
        working = true
        Task {
            let result = await model.deleteJob(job, expected: plan)
            working = false
            switch result {
            case nil: isPresented = false; onDeleted()
            case .changed(let now)?:
                self.plan = now
                refusal = JobRemoval.Refusal.changed(now).localizedDescription
                footprint = await model.footprint(of: job)
            case let other?:
                refusal = other.localizedDescription
            }
        }
    }
}
