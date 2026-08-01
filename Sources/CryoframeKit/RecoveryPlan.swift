//
//  RecoveryPlan.swift
//  CryoframeKit
//
//  "Rebuild this Mac as it was on <date>." One moment, every library — each one
//  restoring the version that represents its state at that moment.
//
//  The subtle part is WHICH version a library contributes. Libraries don't all run
//  on the same nights, so a chosen moment rarely lands on every library's schedule.
//  We pick the newest version AT OR BEFORE the moment, not merely the closest one:
//  a version written after the moment contains changes that hadn't happened yet, so
//  restoring it would rebuild a Mac that never existed. Only when a library has
//  nothing that old do we fall back to its oldest version, flagged so the UI can
//  say so.
//

import Foundation

public enum RecoveryPlan {

    /// what one library contributes to the recovery.
    public struct Selection: Sendable, Equatable, Identifiable {
        public var id: String { library }
        public let library: String
        public let archive: RestorableArchive
        /// true when the library has no version at or before the moment, so this is
        /// its oldest available one — newer than the moment asked for.
        public let isAfterMoment: Bool
        /// a live mirror has a single current state, not a point in time.
        public var isCurrentOnly: Bool { archive.version == nil }

        public init(library: String, archive: RestorableArchive, isAfterMoment: Bool) {
            self.library = library; self.archive = archive; self.isAfterMoment = isAfterMoment
        }
    }

    /// every distinct moment that can be recovered to, oldest first — the slider's stops.
    /// Mirrors contribute nothing: they have no history to slide through.
    public static func moments(in archives: [RestorableArchive]) -> [Date] {
        var seen = Set<String>(), out: [Date] = []
        for a in archives {
            guard let v = a.version else { continue }
            if seen.insert(VersionStamp.string(v)).inserted { out.append(v) }
        }
        return out.sorted()
    }

    /// for each library, the version that represents its state at `moment`.
    /// Libraries are returned in the order they appear in `archives`.
    public static func selections(at moment: Date, in archives: [RestorableArchive]) -> [Selection] {
        RestoreDiscovery.libraries(in: archives).compactMap { lib in
            let versions = RestoreDiscovery.versions(of: lib, in: archives)   // newest first
            guard !versions.isEmpty else { return nil }

            // a mirror has one state — "current" — regardless of the moment.
            if versions.count == 1, versions[0].version == nil {
                return Selection(library: lib, archive: versions[0], isAfterMoment: false)
            }
            let dated = versions.filter { $0.version != nil }
            guard !dated.isEmpty else {
                return Selection(library: lib, archive: versions[0], isAfterMoment: false)
            }
            // newest at or before the moment…
            if let atOrBefore = dated.first(where: { $0.version! <= moment }) {
                return Selection(library: lib, archive: atOrBefore, isAfterMoment: false)
            }
            // …otherwise the library didn't exist yet: offer its oldest, and say so.
            return Selection(library: lib, archive: dated.last!, isAfterMoment: true)
        }
    }

    /// total bytes the plan will read — for the "will it fit?" check.
    public static func totalBytes(_ selections: [Selection]) -> UInt64 {
        selections.reduce(0) { $0 + $1.archive.bytes }
    }
}
