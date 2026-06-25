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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Storage").font(.title2.bold())
                Spacer()
                Button("Done") { isPresented = false }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()

            if loading {
                Spacer()
                ProgressView("Measuring archives…")
                Spacer()
            } else if rows.allSatisfy({ $0.archiveBytes == 0 }) {
                Spacer()
                Text("No archives on disk yet — run a job to see its storage here.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(rows) { row($0); Divider() }
                    }
                }
            }
        }
        .frame(width: 560, height: 480)
        .task { await load() }
    }

    private func load() async {
        let jobs = model.jobs
        let report = await Task.detached { StorageReporter.report(jobs) }.value
        rows = report; loading = false
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
                Text("\(s.targetName) · no archives yet").font(.caption).foregroundStyle(.secondary)
            } else {
                DisclosureGroup("\(s.targetName) · \(s.versionCount) archive\(s.versionCount == 1 ? "" : "s")") {
                    ForEach(s.archives) { a in
                        HStack {
                            Text(a.version.map { "\(a.library) · \($0.formatted(date: .abbreviated, time: .shortened))" } ?? a.library)
                            Spacer()
                            Text(size(a.bytes)).monospacedDigit()
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
        }
        .padding(.horizontal).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
    private func usageColor(free: UInt64, total: UInt64) -> Color {
        let frac = 1 - Double(free) / Double(total)
        return frac > 0.9 ? .red : (frac > 0.75 ? .orange : .accentColor)
    }
}
