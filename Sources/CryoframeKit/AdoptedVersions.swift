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
//  dashboard. The go-ahead is kept on the job, version by version: it names the
//  versions the person was shown and, of them, exactly those they were told the
//  Keep rule deletes, under the Keep rule they were counted with. That is what the
//  next backup deletes and, under a rule that keeps the last so many, also those
//  later backups delete one at a time: all of them, as new versions push them out,
//  so one yes covers them all rather than asking again at every backup. A run
//  deletes an adopted version only when a go-ahead names it as deleted and the Keep
//  rule wants it gone, so it never deletes more than the person was told, whatever
//  the date it runs. Once the job's Keep rule changes, a go-ahead given under the
//  old one no longer holds, and the person is asked again. A version adopted
//  without one is left as it is, and every run says so, whichever path led there.
//

import Foundation

/// The person's go-ahead for a job's Keep rule to apply to versions a library
/// folder at one destination adopted.
public struct AdoptionConsent: Codable, Sendable, Equatable {
    public var targetID: String
    public var libraryID: String
    /// the version folders' names the person was shown: under `rule`, they take
    /// their places among the versions the Keep rule keeps
    public var versions: [String]
    /// of them, those the person was told the Keep rule deletes (finished or not, at
    /// the next backup or, one at a time, at later ones): the only ones it may delete
    public var allows: [String]
    /// the Keep rule they were counted under: once the job's is another, this
    /// go-ahead no longer holds
    public var rule: RetentionPolicy
    public var confirmedAt: Date

    /// how many of them the person was told the Keep rule deletes
    public var deletes: Int { allows.count }

    public init(targetID: String, libraryID: String, versions: [String], allows: [String], rule: RetentionPolicy, confirmedAt: Date) {
        self.targetID = targetID; self.libraryID = libraryID; self.versions = versions
        self.allows = allows; self.rule = rule; self.confirmedAt = confirmedAt
    }

    /// whether it still holds for a job keeping by `policy`
    public func holds(under policy: RetentionPolicy) -> Bool { rule == policy }
}

/// What to ask about the versions one library folder adopted: every one of them
/// there, and of them those the Keep rule deletes once it applies.
public struct AdoptionQuestion: Sendable, Equatable {
    public var versions: [String]
    /// finished versions the next backup deletes
    public var deletes: [String]
    /// dated folders that never finished, deleted then too
    public var unfinished: [String]
    /// finished versions later backups delete, one at a time as new ones push them
    /// out: only under a rule that keeps the last so many, where that order is known
    /// (under one that keeps so many a day, week and month, which go depends on when
    /// the backups are made, so each is asked about when the next backup deletes it)
    public var later: [String] = []

    /// every one of them the Keep rule deletes: what saying yes lets it delete
    public var allows: [String] { deletes + unfinished + later }

    /// the go-ahead saying yes gives, for `library` at `target` under `rule`
    func consent(target: String, library: String, rule: RetentionPolicy, at date: Date) -> AdoptionConsent {
        AdoptionConsent(targetID: target, libraryID: library, versions: versions, allows: allows, rule: rule, confirmedAt: date)
    }

    /// what saying yes does, said the same way wherever it is asked: "none of them
    /// are deleted at the next backup; 2 more are deleted one at a time …"
    public static func effect(deletes: Int, unfinished: Int, later: Int, total: Int) -> [String] {
        var parts: [String] = []
        parts.append(deletes == 0 ? "none of them are deleted at the next backup"
                     : "\(deletes) \(deletes == 1 ? "is" : "are") deleted at the next backup")
        if later > 0 {
            let who = deletes == 0 && later == total ? (later == 1 ? "it is" : "all \(later) are")
                : deletes == 0 ? "\(later) \(later == 1 ? "is" : "are")" : "\(later) more \(later == 1 ? "is" : "are")"
            parts.append("\(who) deleted one at a time as new backups are made")
        }
        if unfinished > 0 { parts.append("\(unfinished) that never finished \(unfinished == 1 ? "is" : "are") deleted too") }
        return parts
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
    /// the names of those counted in `deletes` and `unfinished`, and of those later
    /// backups delete one at a time (see AdoptionQuestion.later): all saying yes lets
    /// the Keep rule delete
    public var allows: [String]
    /// the Keep rule they were counted under
    public var rule: RetentionPolicy
    public var foundAt: Date

    public init(jobID: String, targetID: String, libraryID: String, destination: String, library: String,
                question: AdoptionQuestion, rule: RetentionPolicy, foundAt: Date) {
        self.jobID = jobID; self.targetID = targetID; self.libraryID = libraryID
        self.destination = destination; self.library = library; self.versions = question.versions
        self.deletes = question.deletes.count; self.unfinished = question.unfinished.count
        self.allows = question.allows; self.rule = rule; self.foundAt = foundAt
    }

    /// of them, how many later backups delete one at a time (see AdoptionQuestion.later)
    public var later: Int { max(0, allows.count - deletes - unfinished) }

    /// the go-ahead saying yes records
    public func consent(at date: Date) -> AdoptionConsent {
        AdoptionConsent(targetID: targetID, libraryID: libraryID, versions: versions, allows: allows, rule: rule, confirmedAt: date)
    }

    /// whether `other` asks the same: the same versions, the same of them deleted,
    /// under the same Keep rule (when it was found aside)
    public func asksTheSame(as other: AdoptionReview) -> Bool {
        id == other.id && versions == other.versions && allows == other.allows && rule == other.rule
            && deletes == other.deletes && unfinished == other.unfinished
    }

    /// what the run and the dashboard say of it
    public var text: String {
        let n = versions.count
        return "\(n) earlier backup\(n == 1 ? "" : "s") of \(library) at \(destination) \(n == 1 ? "is" : "are") kept for now: this job didn't make \(n == 1 ? "it" : "them"). Review \(n == 1 ? "it" : "them") on the dashboard to let the Keep rule apply."
    }

    /// what saying yes does, at the next backup and after it
    public var effect: String {
        let parts = AdoptionQuestion.effect(deletes: deletes, unfinished: unfinished, later: later, total: versions.count)
        var rule = "The Keep rule"
        if case .keepLast(let n) = self.rule { rule = "Keep last \(n)" }
        return "\(rule) then applies to them: " + parts.joined(separator: "; ") + "."
    }
}

extension BackupJob {
    /// the go-ahead given for the versions the folder of `libraryID` at `targetID`
    /// adopted that still holds under the job's Keep rule
    public func adoptionConsents(target targetID: String, library libraryID: String) -> [AdoptionConsent] {
        (adoptionConsents ?? []).filter { $0.targetID == targetID && $0.libraryID == libraryID && $0.holds(under: retention) }
    }

    /// whether the person was told the next backup deletes `version`, adopted by the
    /// folder of `libraryID` at `targetID`, and said yes, under the job's Keep rule:
    /// the only adopted versions retention may delete
    public func confirmsAdoption(of version: String, target targetID: String, library libraryID: String) -> Bool {
        adoptionConsents(target: targetID, library: libraryID).contains { $0.allows.contains(version) }
    }

    /// whether the person was shown `version` under the job's Keep rule and said yes:
    /// it takes its place among the versions the rule keeps, deleted or not
    public func hasShownAdoption(of version: String, target targetID: String, library libraryID: String) -> Bool {
        adoptionConsents(target: targetID, library: libraryID).contains { $0.versions.contains(version) }
    }

    /// This job with `consents` added. One given for a folder replaces any earlier one
    /// for it (they share a version), and none given under another Keep rule than the
    /// job's is kept: it no longer holds.
    public func adding(_ consents: [AdoptionConsent]) -> BackupJob {
        var j = self
        var list = (adoptionConsents ?? []).filter { $0.holds(under: retention) }
        for c in consents where !c.versions.isEmpty && c.holds(under: retention) {
            list.removeAll { $0.targetID == c.targetID && $0.libraryID == c.libraryID && !Set($0.versions).isDisjoint(with: c.versions) }
            list.append(c)
        }
        j.adoptionConsents = list.isEmpty ? nil : list
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
    /// next backup, deleting no more of them than it said. False, and nothing
    /// changed, when the job is gone, or `review` is no longer what there is to ask:
    /// the job's Keep rule changed since it was counted, or a run counted again.
    @discardableResult
    public func confirm(_ review: AdoptionReview, at date: Date = Date()) -> Bool {
        update { s in
            guard let j = s.jobs.firstIndex(where: { $0.id == review.jobID }), s.jobs[j].retention == review.rule,
                  (s.adoptionReviews[review.jobID] ?? []).contains(where: { $0.asksTheSame(as: review) }) else { return false }
            s.jobs[j] = s.jobs[j].adding([review.consent(at: date)])
            let rest = (s.adoptionReviews[review.jobID] ?? []).filter { $0.id != review.id }
            s.adoptionReviews[review.jobID] = rest.isEmpty ? nil : rest
            return true
        }
    }
}
