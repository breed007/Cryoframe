//
//  CoverageCard.swift
//  Cryoframe (app)
//
//  "You're not protecting this." The dashboard above answers how the jobs you made
//  are doing; this answers the question those jobs can't — what's on this Mac that
//  nothing is backing up.
//
//  It's built to be easy to silence. One line per library, a button to fix it, and
//  a dismiss that sticks forever. It only appears once at least one job exists —
//  on a fresh install the empty state is already asking for a first job, and two
//  prompts saying the same thing is how a helpful nudge turns into nagging.
//

import SwiftUI
import CryoframeKit

struct CoverageCard: View {
    @ObservedObject var model: AppModel

    /// show at most this many at once — a wall of prompts reads as pressure.
    private let maxShown = 3

    var body: some View {
        let gaps = model.coverageGaps
        if !gaps.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "shield.lefthalf.filled.slash")
                        .foregroundStyle(.cryoWarn)
                        .accessibilityHidden(true)
                    Text(headline(gaps.count)).font(.callout.weight(.semibold))
                    Spacer()
                }
                ForEach(gaps.prefix(maxShown)) { gap in row(gap) }
                if gaps.count > maxShown {
                    Text("and \(gaps.count - maxShown) more")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.cryoWarn.opacity(0.09)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.cryoWarn.opacity(0.28), lineWidth: 1))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(headline(gaps.count))
        }
    }

    private func headline(_ n: Int) -> String {
        n == 1 ? "1 library on this Mac isn't backed up" : "\(n) libraries on this Mac aren't backed up"
    }

    private func row(_ gap: CoverageAdvisor.Gap) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.caption).foregroundStyle(.secondary).frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(gap.displayName).font(.callout.weight(.medium))
                Text(sizeLine(gap)).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button("Back up…") { model.startJob(forLibrary: gap.typeID) }
                .controlSize(.small)
            Button { model.dismissCoverage(gap.typeID) } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless).controlSize(.small)
            .help("Stop suggesting \(gap.displayName)")
            .accessibilityLabel("Dismiss \(gap.displayName)")
        }
    }

    /// the measured size once it's known, otherwise the path — never a spinner, so
    /// the row doesn't twitch while sizes come in.
    private func sizeLine(_ gap: CoverageAdvisor.Gap) -> String {
        if let bytes = model.librarySizes[gap.typeID], bytes > 0 {
            return "\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) · not in any job"
        }
        return gap.root.path
    }
}
