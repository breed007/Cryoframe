//
//  CoverageAdvisor.swift
//  CryoframeKit
//
//  "What am I NOT protecting?" A backup tool that only reports on the jobs you
//  remembered to create can't answer the question that actually matters. This
//  finds libraries sitting on this Mac that no job covers.
//
//  The whole design constraint is not nagging. Someone who deliberately doesn't
//  back up GarageBand should be told once, dismiss it, and never hear about it
//  again — so dismissal is an input here, and the caller persists it. A job counts
//  as coverage even when its schedule is disabled: that's a choice the user made,
//  not an oversight to prod them about.
//

import Foundation

public enum CoverageAdvisor {

    /// a library that exists on this Mac but isn't in any job.
    public struct Gap: Sendable, Equatable, Identifiable {
        public var id: String { typeID }
        public let typeID: String
        public let displayName: String
        public let root: URL

        public init(typeID: String, displayName: String, root: URL) {
            self.typeID = typeID; self.displayName = displayName; self.root = root
        }
    }

    /// Libraries present on disk that no job protects, in the registry's own order
    /// (which runs most-valuable-first: Photos, Music, then the rest).
    ///
    /// - Parameters:
    ///   - types: the known library types to consider — only ones with a fixed,
    ///     detectable location can be found this way; template libraries live
    ///     anywhere, so their absence proves nothing.
    ///   - jobs: every job, enabled or not.
    ///   - dismissed: type ids the user has waved off.
    ///   - resolve: the library's live root if it exists on this Mac, else nil.
    ///     Injected so this stays testable without touching the file system.
    public static func gaps(types: [ContentType],
                            jobs: [BackupJob],
                            dismissed: Set<String> = [],
                            resolve: (ContentType) -> URL?) -> [Gap] {
        let covered = Set(jobs.flatMap { $0.libraries.map(\.id) })
        return types.compactMap { type in
            guard !covered.contains(type.id), !dismissed.contains(type.id),
                  let root = resolve(type) else { return nil }
            return Gap(typeID: type.id, displayName: type.displayName, root: root)
        }
    }
}
