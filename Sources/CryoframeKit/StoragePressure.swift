//
//  StoragePressure.swift
//  CryoframeKit
//
//  A destination that fills up doesn't degrade — it stops. The run fails on a
//  free-space check and keeps failing every night after, which is the worst way
//  for a backup to end: quietly, while the dashboard still shows yesterday's
//  success.
//
//  Cryoframe made that likelier than it needed to be. Retention defaulted to
//  "keep every version", so a sealed job grew without limit while promising, in
//  the README, that retention was what kept the disk from filling. This works out
//  what is actually going to run out, and what would give it room.
//

import Foundation

public enum StoragePressure {

    public struct Finding: Sendable, Equatable, Identifiable {
        public enum Kind: String, Sendable, Equatable {
            /// there may not be room for another run of this job here.
            case tight
            /// this job keeps every version, so it grows until something stops it.
            case unbounded
        }

        public var id: String { kind.rawValue + ":" + jobID + "@" + destination }
        public let kind: Kind
        public let jobID: String
        public let jobName: String
        public let destination: String
        public let free: UInt64
        /// what one more run of this job has historically taken.
        public let runBytes: UInt64
        public let versionCount: Int
        /// bytes that keeping only the most recent versions would give back.
        public let reclaimable: UInt64

        public init(kind: Kind, jobID: String, jobName: String, destination: String,
                    free: UInt64, runBytes: UInt64, versionCount: Int, reclaimable: UInt64) {
            self.kind = kind; self.jobID = jobID; self.jobName = jobName; self.destination = destination
            self.free = free; self.runBytes = runBytes; self.versionCount = versionCount
            self.reclaimable = reclaimable
        }
    }

    /// how many versions a "keep the recent ones" suggestion should offer to keep.
    public static let suggestedKeep = 7

    /// What is going to run out, and what would help.
    ///
    /// `tight` is deliberately not a percentage. On a 4 TB NAS ten percent is huge and
    /// on a 500 GB drive it is nothing; what actually matters is whether the next run
    /// of THIS job still fits, so that is what gets measured.
    public static func findings(storage: [JobStorage],
                                retention: [String: RetentionPolicy],
                                keeping: Int = suggestedKeep) -> [Finding] {
        storage.compactMap { s -> Finding? in
            guard let free = s.volumeFree else { return nil }
            let policy = retention[s.jobID] ?? .keepAll
            let runBytes = typicalRunBytes(s.archives)
            let reclaim = reclaimable(s.archives, keeping: .keepLast(keeping))

            // no room for another run like the last one
            if runBytes > 0, free < runBytes {
                return Finding(kind: .tight, jobID: s.jobID, jobName: s.jobName, destination: s.targetName,
                               free: free, runBytes: runBytes, versionCount: s.versionCount, reclaimable: reclaim)
            }
            // growing without limit, and already big enough that it matters
            if case .keepAll = policy, s.versionCount > keeping, reclaim > 0 {
                return Finding(kind: .unbounded, jobID: s.jobID, jobName: s.jobName, destination: s.targetName,
                               free: free, runBytes: runBytes, versionCount: s.versionCount, reclaimable: reclaim)
            }
            return nil
        }
    }

    /// bytes that applying `policy` would free, using the same pruning rule the
    /// engine uses after a run — so the number quoted is the number delivered.
    public static func reclaimable(_ archives: [ArchiveSize], keeping policy: RetentionPolicy) -> UInt64 {
        var total: UInt64 = 0
        for (_, entries) in Dictionary(grouping: archives.filter { $0.version != nil }, by: \.library) {
            let doomed = retentionPrune(entries.compactMap(\.version), policy: policy)
            total += entries.filter { $0.version.map { doomed.contains($0) } ?? false }
                            .reduce(0) { $0 + $1.bytes }
        }
        return total
    }

    /// what one run costs here: the newest version of every library, added up. Sizes
    /// drift, so the newest is a better guide to the next run than an average over
    /// versions written when the library was half the size.
    static func typicalRunBytes(_ archives: [ArchiveSize]) -> UInt64 {
        Dictionary(grouping: archives, by: \.library).values.reduce(0) { sum, entries in
            sum + (entries.max(by: { ($0.version ?? .distantPast) < ($1.version ?? .distantPast) })?.bytes ?? 0)
        }
    }
}
