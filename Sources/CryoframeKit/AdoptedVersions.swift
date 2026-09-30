//
//  AdoptedVersions.swift
//  CryoframeKit
//
//  Versions a job's library folder adopted, and the person's go-ahead for its Keep
//  rule to apply to them.
//
//  A job's run can come to hold versions it didn't make: it takes over a folder 1.5
//  wrote, with every version in it, or moves its library's versions in from a folder
//  it shared with a mirror job (see LibraryFolders). Its Keep rule would delete the
//  older ones at once. The folder records them as adopted (see
//  LibraryIdentity.adoptedVersions), and retention leaves them alone until the
//  person has been shown what applying the Keep rule to them deletes, and said yes:
//  in the save summary, when pairing a drive, when renaming one, or on the
//  dashboard. The go-ahead is kept on the job, version by version. A version adopted
//  without one is left as it is, and every run says so, whichever path led there.
//

import Foundation

/// The person's go-ahead for a job's Keep rule to apply to versions a library
/// folder at one destination adopted.
public struct AdoptionConsent: Codable, Sendable, Equatable {
    public var targetID: String
    public var libraryID: String
    /// the version folders' names
    public var versions: [String]
    /// how many of them the person was told the next backup deletes
    public var deletes: Int
    public var confirmedAt: Date

    public init(targetID: String, libraryID: String, versions: [String], deletes: Int, confirmedAt: Date) {
        self.targetID = targetID; self.libraryID = libraryID; self.versions = versions
        self.deletes = deletes; self.confirmedAt = confirmedAt
    }
}

/// Adopted versions a run left alone because no one has said yes yet: what the
/// dashboard shows, and what saying yes there does.
public struct AdoptionReview: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(jobID)/\(targetID)/\(libraryID)" }
    public var jobID: String
    public var targetID: String
    public var libraryID: String
    /// the destination's and the library's names, as the run said them
    public var destination: String
    public var library: String
    /// the version folders' names
    public var versions: [String]
    /// of them, how many the next backup deletes once the Keep rule applies
    public var deletes: Int
    /// of them, dated folders that never finished, deleted then too
    public var unfinished: Int
    public var foundAt: Date

    public init(jobID: String, targetID: String, libraryID: String, destination: String, library: String,
                versions: [String], deletes: Int, unfinished: Int, foundAt: Date) {
        self.jobID = jobID; self.targetID = targetID; self.libraryID = libraryID
        self.destination = destination; self.library = library; self.versions = versions
        self.deletes = deletes; self.unfinished = unfinished; self.foundAt = foundAt
    }

    /// the go-ahead saying yes records
    public func consent(at date: Date) -> AdoptionConsent {
        AdoptionConsent(targetID: targetID, libraryID: libraryID, versions: versions, deletes: deletes + unfinished, confirmedAt: date)
    }

    /// what the run and the dashboard say of it
    public var text: String {
        let n = versions.count
        return "\(n) earlier backup\(n == 1 ? "" : "s") of \(library) at \(destination) \(n == 1 ? "is" : "are") kept for now: this job didn't make \(n == 1 ? "it" : "them"). Review \(n == 1 ? "it" : "them") on the dashboard to let the Keep rule apply."
    }

    /// what saying yes does at the next backup
    public var effect: String {
        var parts: [String] = []
        parts.append(deletes == 0 ? "none of them are deleted at the next backup" : "\(deletes) \(deletes == 1 ? "is" : "are") deleted at the next backup")
        if unfinished > 0 { parts.append("\(unfinished) that never finished \(unfinished == 1 ? "is" : "are") deleted too") }
        return "The Keep rule then applies to them: " + parts.joined(separator: "; ") + "."
    }
}

extension BackupJob {
    /// whether the person has let the Keep rule apply to `version`, adopted by the
    /// folder of `libraryID` at `targetID`
    public func confirmsAdoption(of version: String, target targetID: String, library libraryID: String) -> Bool {
        (adoptionConsents ?? []).contains { $0.targetID == targetID && $0.libraryID == libraryID && $0.versions.contains(version) }
    }

    /// this job with `consents` added
    public func adding(_ consents: [AdoptionConsent]) -> BackupJob {
        guard !consents.isEmpty else { return self }
        var j = self
        j.adoptionConsents = (adoptionConsents ?? []) + consents.filter { !$0.versions.isEmpty }
        if j.adoptionConsents?.isEmpty == true { j.adoptionConsents = nil }
        return j
    }
}

extension JobStore {
    /// Record what a run of `jobID` left alone at the destinations it reached
    /// (`reached`, by id): the reviews there are replaced by `reviews`.
    public func recordAdoptionReviews(jobID: String, _ reviews: [AdoptionReview], reached: Set<String>) {
        update { s in
            guard s.jobs.contains(where: { $0.id == jobID }) else { return }
            var list = (s.adoptionReviews[jobID] ?? []).filter { !reached.contains($0.targetID) }
            list += reviews
            s.adoptionReviews[jobID] = list.isEmpty ? nil : list
        }
    }

    /// Say yes to `review`: the job's Keep rule applies to those versions from its
    /// next backup. False when the job is gone.
    @discardableResult
    public func confirm(_ review: AdoptionReview, at date: Date = Date()) -> Bool {
        update { s in
            guard let j = s.jobs.firstIndex(where: { $0.id == review.jobID }) else { return false }
            s.jobs[j] = s.jobs[j].adding([review.consent(at: date)])
            let rest = (s.adoptionReviews[review.jobID] ?? []).filter { $0.id != review.id }
            s.adoptionReviews[review.jobID] = rest.isEmpty ? nil : rest
            return true
        }
    }
}
