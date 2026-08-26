//
//  StoragePressureCard.swift
//  Cryoframe (app)
//
//  A destination that fills up doesn't slow down, it stops — and it stops silently,
//  because the dashboard keeps showing the last run, which succeeded. This says so
//  while there is still room to do something, and says what would give room back.
//

import SwiftUI
import CryoframeKit

struct StoragePressureCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let findings = model.storageFindings
        if let worst = findings.first(where: { $0.kind == .tight }) ?? findings.first {
            let tight = worst.kind == .tight
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: tight ? "externaldrive.badge.exclamationmark" : "clock.badge.exclamationmark")
                    .foregroundStyle(tight ? .cryoCrit : .cryoWarn)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline(worst)).font(.callout.weight(.semibold))
                    Text(detail(worst)).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Storage…") { model.showStorage = true }.controlSize(.small)
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill((tight ? Color.cryoCrit : Color.cryoWarn).opacity(0.09)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder((tight ? Color.cryoCrit : Color.cryoWarn).opacity(0.30), lineWidth: 1))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(headline(worst)). \(detail(worst))")
        }
    }

    private func headline(_ f: StoragePressure.Finding) -> String {
        f.kind == .tight
            ? "\(f.destination) may not have room for the next backup"
            : "\(f.jobName) is keeping every version"
    }

    private func detail(_ f: StoragePressure.Finding) -> String {
        let free = size(f.free), reclaim = size(f.reclaimable)
        switch f.kind {
        case .tight:
            let run = size(f.runBytes)
            let fix = f.reclaimable > 0
                ? " Keeping the last \(StoragePressure.suggestedKeep) versions of \(f.jobName) would free about \(reclaim)."
                : ""
            return "\(free) free, and the last run of \(f.jobName) took \(run). The next one is likely to fail.\(fix)"
        case .unbounded:
            return "\(f.versionCount) versions on \(f.destination), and nothing prunes them. Keeping the last \(StoragePressure.suggestedKeep) would free about \(reclaim), with \(free) free today."
        }
    }

    private func size(_ b: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
    }
}
