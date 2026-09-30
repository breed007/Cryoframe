//
//  Rotation.swift
//  CryoframeKit
//
//  Drives that take turns: two (or more) external drives swapped every week or so,
//  one of them kept away from home. That's the off-site copy for anyone without a
//  cloud plan, and the app used to punish it. The drive that was away made every
//  run partial, a partial run didn't count as a good one, and after a week the job
//  was called critical, for doing what the README recommends.
//
//  A job's destinations can include a rotation: drives marked with the same group.
//  The rotation is one place the backups go. A run writes to whichever of its
//  drives is connected; a drive that's away isn't a fault and isn't mentioned as a
//  failure. Each drive keeps its own "last copy" date, and one that hasn't had a
//  copy for longer than the rotation allows is named, with its age, so you know
//  which drive to bring home. Drives are recognized by their volume UUID (see
//  VolumeIdentity), so a renamed drive is still itself, and another drive with the
//  same name isn't part of the rotation.
//

import Foundation

/// A destination's place in a rotation of drives.
public struct Rotation: Codable, Sendable, Equatable, Hashable {
    /// drives with the same group take turns
    public var group: String
    /// how long a drive may go without a copy before it is named on the dashboard
    public var maxAwayDays: Int
    /// when the drive joined the rotation: a drive not yet connected since then
    /// isn't "gone too long" before its first chance
    public var addedAt: Date?

    public static let defaultMaxAwayDays = 14

    public init(group: String, maxAwayDays: Int = Rotation.defaultMaxAwayDays, addedAt: Date? = nil) {
        self.group = group; self.maxAwayDays = maxAwayDays; self.addedAt = addedAt
    }
}

public extension BackupJob {
    /// The places this job's backups go: each destination on its own, and each
    /// rotation as one place holding its drives, in the order they first appear. The
    /// first is the primary: a run fails if none of it can be reached.
    var places: [[Target]] {
        var out: [[Target]] = []
        var groupIndex: [String: Int] = [:]
        for t in targets {
            if let g = t.rotation?.group {
                if let i = groupIndex[g] { out[i].append(t) } else { groupIndex[g] = out.count; out.append([t]) }
            } else {
                out.append([t])
            }
        }
        return out
    }

    /// the drives in rotations
    var rotatingTargets: [Target] { targets.filter { $0.rotation != nil } }

    /// Each destination's name, by target id, told apart from another of the job's
    /// with the same name by its drive: two drives bought together carry the name
    /// they came with, so a rotation of them was "Backups on T7" twice, and "hasn't
    /// had a copy on Backups on T7 in 19 days" couldn't say which to bring home. The
    /// drive is named by the start of its volume UUID ("Backups on T7 (drive 4F2A)"),
    /// which Disk Utility shows; one without a UUID on record, by its place in the list.
    var destinationLabels: [String: String] {
        var out: [String: String] = [:]
        let groups = Dictionary(grouping: targets.indices, by: { targets[$0].displayName })
        for (name, indices) in groups {
            guard indices.count > 1 else { out[targets[indices[0]].id] = name; continue }
            let uuids = indices.map { i in targets[i].volume.map { $0.uuid.uppercased().filter { $0.isLetter || $0.isNumber } } }
            let length = [4, 8, 12].first { n in
                let tags = uuids.map { $0.map { String($0.prefix(n)) } }
                return !tags.contains(nil) && Set(tags).count == tags.count
            }
            for (k, i) in indices.enumerated() {
                let tag = length.flatMap { n in uuids[k].map { "drive " + $0.prefix(n) } } ?? "\(k + 1) of \(indices.count)"
                out[targets[i].id] = "\(name) (\(tag))"
            }
        }
        return out
    }
}

public enum RotationRules {
    /// A rotating drive that has gone too long without a copy.
    public struct AwayTooLong: Sendable, Equatable {
        public var name: String
        public var lastCopy: Date?
        /// since when it has gone without one (its last copy, or when it joined)
        public var since: Date
    }

    /// The rotating drives of `job` that have gone longer than their rotation allows
    /// without a copy, the longest first. `lastCopies`: when each of the job's
    /// destinations (by target id) last got a complete copy of every library.
    public static func awayTooLong(_ job: BackupJob, lastCopies: [String: Date], now: Date) -> [AwayTooLong] {
        var out: [AwayTooLong] = []
        let labels = job.destinationLabels
        for t in job.rotatingTargets {
            guard let r = t.rotation else { continue }
            let last = lastCopies[t.id]
            let since = last ?? r.addedAt ?? job.createdAt
            if now.timeIntervalSince(since) > TimeInterval(r.maxAwayDays) * 86_400 {
                out.append(AwayTooLong(name: labels[t.id] ?? t.displayName, lastCopy: last, since: since))
            }
        }
        return out.sorted { $0.since < $1.since }
    }

    /// "T7 B" or "T7 A or T7 B": a rotation, by its drives
    public static func name(of place: [Target]) -> String {
        let names = place.map(\.displayName)
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " or " + names.last!
    }
}
