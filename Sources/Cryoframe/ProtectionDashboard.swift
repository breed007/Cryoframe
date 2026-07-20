//
//  ProtectionDashboard.swift
//  Cryoframe (app)
//
//  The "am I protected?" hero at the top of the window. It answers the one question a
//  backup user actually has — before the job list, before the log. Status is encoded in
//  shape AND text (shield vs warning triangle, plain-language line), not color alone, so
//  it reads at a glance and passes for VoiceOver / color-blind users.
//

import SwiftUI
import CryoframeKit

struct ProtectionDashboard: View {
    @ObservedObject var model: AppModel
    var onNewJob: () -> Void

    var body: some View {
        let s = ProtectionStatus.compute(model)
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                statusRing(s)
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.title).font(.system(size: 21, weight: .bold)).accessibilityAddTraits(.isHeader)
                    Text(s.subtitle).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(action: onNewJob) { Label("New Job", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
            statTiles(s)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.cryoElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(RadialGradient(colors: [s.tint.opacity(0.16), .clear],
                                             center: .topTrailing, startRadius: 0, endRadius: 340))
                )
        )
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.cryoLine, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Backup status: \(s.title). \(s.subtitle)")
    }

    private func statusRing(_ s: ProtectionStatus) -> some View {
        ZStack {
            Circle().stroke(Color.cryoLine, lineWidth: 4)
            Circle().trim(from: 0, to: s.level == .protected ? 1 : 0.62)
                .stroke(s.tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .cryoGlow(s.tint, radius: 8)
            Image(systemName: s.glyph)
                .font(.system(size: 22, weight: .semibold)).foregroundStyle(s.tint)
        }
        .frame(width: 58, height: 58)
    }

    private func statTiles(_ s: ProtectionStatus) -> some View {
        HStack(spacing: 12) {
            tile("Last backup", value: ProtectionStatus.lastBackupText(model), sub: lastBackupSub)
            tile("Backed up", value: protectedText, sub: "\(libraryCount) \(libraryCount == 1 ? "library" : "libraries")")
            tile("Destinations", value: "\(destinationCount)", sub: destinationSub)
            tile("Next run", value: nextRunValue, sub: nextRunSub)
        }
    }

    private func tile(_ key: String, value: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(key.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.4).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 16, weight: .semibold)).monospacedDigit().lineLimit(1)
            Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.cryoLine, lineWidth: 1))
    }

    // MARK: - stat values

    private var lastBackupSub: String {
        guard let rec = model.jobs.compactMap({ model.lastRecords[$0.id] })
            .filter({ [.verified, .completed, .partial].contains($0.outcome) })
            .max(by: { $0.finishedAt < $1.finishedAt }) else { return "no runs yet" }
        return rec.jobName
    }
    private var protectedText: String {
        guard let b = model.protectedBytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
    }
    private var libraryCount: Int {
        Set(model.jobs.flatMap { $0.libraries.map(\.displayName) }).count
    }
    private var destinationCount: Int {
        Set(model.jobs.flatMap { $0.targets.map(\.destinationDir.path) }).count
    }
    /// the destination with the least free space — the "are we running low?" signal.
    private var tightestDestination: (name: String, free: UInt64)? {
        let unique = Dictionary(grouping: model.jobs.flatMap(\.targets), by: { $0.destinationDir.path }).compactMap { $0.value.first }
        return unique.compactMap { t -> (String, UInt64)? in
            model.volumeInfo(for: t.destinationDir).map { (t.displayName, $0.free) }
        }.min(by: { $0.1 < $1.1 })
    }
    private var destinationSub: String {
        guard let t = tightestDestination else { return "—" }
        return "\(ByteCountFormatter.string(fromByteCount: Int64(t.free), countStyle: .file)) free"
    }
    private var nextRun: Date? { model.nextScheduledRun() }
    private var nextRunValue: String {
        guard let d = nextRun else { return "Manual" }
        return d.formatted(.relative(presentation: .named)).localizedCapitalized
    }
    private var nextRunSub: String {
        guard let d = nextRun else { return "no schedule" }
        return d.formatted(date: .omitted, time: .shortened)
    }
}
