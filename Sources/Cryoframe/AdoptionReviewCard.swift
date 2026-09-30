//
//  AdoptionReviewCard.swift
//  Cryoframe (app)
//
//  Earlier backups a job's folder took in (a folder an earlier version of Cryoframe
//  made, or versions moved in from another) are left alone until the person lets
//  the job's Keep rule apply to them (see AdoptedVersions.swift). Each run says so;
//  this is where the person sees what saying yes deletes, and says it.
//

import SwiftUI
import CryoframeKit

struct AdoptionReviewCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if !model.adoptionReviews.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.adoptionReviews) { review in
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "tray.full")
                            .foregroundStyle(Color.cryoWarn)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(headline(review)).font(.callout.weight(.semibold))
                            Text(detail(review)).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Button(buttonTitle(review)) { model.confirm(review) }
                            .controlSize(.small)
                            .help(review.effect)
                    }
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.cryoWarn.opacity(0.09)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.cryoWarn.opacity(0.30), lineWidth: 1))
        }
    }

    private func headline(_ r: AdoptionReview) -> String {
        let n = r.versions.count
        let job = model.jobs.first { $0.id == r.jobID }?.name ?? "A job"
        return "\(job): \(n) earlier backup\(n == 1 ? "" : "s") of \(r.library) at \(r.destination) \(n == 1 ? "is" : "are") kept for now"
    }

    private func detail(_ r: AdoptionReview) -> String {
        "This job didn't make \(r.versions.count == 1 ? "it" : "them"), so its Keep rule doesn't apply yet. " + r.effect
    }

    private func buttonTitle(_ r: AdoptionReview) -> String {
        let n = r.deletes + r.unfinished
        return n == 0 ? "Let Keep apply" : "Let Keep apply, and delete \(n)"
    }
}
