//
//  RecoveryRehearsal.swift
//  CryoframeKit
//
//  A restore drill proves an archive opens. It does not prove a RECOVERY works,
//  because it looks where the job config says the archive should be. A rehearsal
//  looks where a recovery looks: it scans the destination the way someone with a
//  new Mac would, and finds out whether what is actually sitting there adds up to
//  the Mac you think you are protecting.
//
//  That catches the failure a drill cannot. A destination reorganised, a library
//  folder renamed or removed, a job quietly writing somewhere else — the drill
//  keeps passing on the paths it derives from the job, while a real recovery would
//  come up empty.
//
//  It stops short of copying everything back. The expensive part of a recovery is
//  moving the bytes; the parts that go wrong are finding the archives, matching
//  the keys, choosing versions, and opening them. Those are what get exercised.
//

import Foundation

public struct RecoveryRehearsal: Sendable {
    let runner: CommandRunner
    public init(runner: CommandRunner = ProcessCommandRunner()) { self.runner = runner }

    public struct LibraryOutcome: Sendable, Equatable {
        public let library: String
        public let version: Date?
        public let ok: Bool
        /// encrypted, and no key on this Mac — not a failure of the archive.
        public let locked: Bool
        public let skipped: Bool
        public let detail: String

        public init(library: String, version: Date?, ok: Bool, locked: Bool = false,
                    skipped: Bool = false, detail: String) {
            self.library = library; self.version = version; self.ok = ok
            self.locked = locked; self.skipped = skipped; self.detail = detail
        }
    }

    public struct Report: Sendable {
        public let destination: String
        public let moment: Date?
        public let outcomes: [LibraryOutcome]
        /// libraries a job claims to protect that a recovery would not find here.
        /// The quiet failure this whole thing exists to catch.
        public let missing: [String]

        public var passed: Bool { missing.isEmpty && outcomes.allSatisfy { $0.ok || $0.skipped } }
        public var openedCount: Int { outcomes.filter { $0.ok && !$0.skipped }.count }

        public init(destination: String, moment: Date?, outcomes: [LibraryOutcome], missing: [String]) {
            self.destination = destination; self.moment = moment
            self.outcomes = outcomes; self.missing = missing
        }
    }

    /// Rehearse recovering from `destination`, exactly as the recovery flow would.
    ///
    /// - Parameters:
    ///   - expecting: library names the jobs writing here claim to protect, so a
    ///     library that has silently stopped arriving can be named.
    ///   - passphrase: key for an encrypted library, by library name. A library with
    ///     no key is reported locked rather than failed — nothing is wrong with it.
    ///   - isCloud: skip archives evicted to placeholders instead of pulling gigabytes.
    public func rehearse(destination: URL,
                         expecting: [String],
                         isCloud: Bool = false,
                         materializeCloud: Bool = false,
                         passphrase: @Sendable (String) -> String? = { _ in nil }) -> Report {
        let archives = RestoreDiscovery.scan(destination)     // the recovery entry point
        let found = Set(archives.map(\.libraryName))
        let missing = expecting.filter { !found.contains($0) }.sorted()

        let moment = RecoveryPlan.moments(in: archives).last
        let selections = moment.map { RecoveryPlan.selections(at: $0, in: archives) }
            ?? RecoveryPlan.selections(at: Date(), in: archives)

        let outcomes = selections.map { selection -> LibraryOutcome in
            let a = selection.archive
            if isCloud, CloudFile.anyDataless(in: a.dir) {
                guard materializeCloud else {
                    return LibraryOutcome(library: a.libraryName, version: a.version, ok: true,
                                          skipped: true, detail: "not downloaded — skipped")
                }
                CloudFile.materialize(a.dir)
            }
            let key = a.encrypted ? passphrase(a.libraryName) : nil
            if a.encrypted, key == nil {
                return LibraryOutcome(library: a.libraryName, version: a.version, ok: false, locked: true,
                                      detail: "encrypted, and no passphrase is available on this Mac")
            }
            do {
                // the same three things a recovery does before it copies anything
                let sidecar = a.dir.appendingPathComponent(ArchiveManifest.sidecarName)
                let manifest = try ArchiveManifest.read(sidecar)
                let report = try ChecksumVerifier().verify(manifest, in: a.dir)
                guard report.passed else {
                    return LibraryOutcome(library: a.libraryName, version: a.version, ok: false,
                                          detail: "checksums don't match — \(report.details)")
                }
                let opened = try ArchiveReader(runner: runner).open(a.archiveResult(), passphrase: key)
                defer { opened.close() }
                let entries = (try? FileManager.default.contentsOfDirectory(atPath: opened.root.path)) ?? []
                guard !entries.isEmpty else {
                    return LibraryOutcome(library: a.libraryName, version: a.version, ok: false,
                                          detail: "opened, but there is nothing inside it")
                }
                return LibraryOutcome(library: a.libraryName, version: a.version, ok: true,
                                      detail: "opened and readable")
            } catch {
                return LibraryOutcome(library: a.libraryName, version: a.version, ok: false,
                                      detail: Self.reason(error, encrypted: a.encrypted))
            }
        }
        return Report(destination: destination.lastPathComponent, moment: moment,
                      outcomes: outcomes, missing: missing)
    }

    /// Say what actually went wrong. These are Swift enums, so localizedDescription
    /// renders them as "error 0" — useless in the one place someone needs to know why
    /// their recovery would fail.
    static func reason(_ e: Error, encrypted: Bool) -> String {
        if let a = e as? ArchiveError {
            switch a {
            case .toolFailed(let tool, _, let stderr):
                // A saturated disk-image subsystem fails an encrypted attach exactly the
                // way a bad key does. Blaming the passphrase for contention is the worst
                // wrong answer available here: it sends someone hunting for a recovery
                // key, and doubting the backup, over a machine that was merely busy.
                if ProcessCommandRunner.isTransient(stderr) {
                    return "couldn't be opened right now — the disk-image system was busy. Worth rehearsing again."
                }
                if encrypted { return "wouldn't open — the passphrase on this Mac may no longer match" }
                let line = stderr.split(separator: "\n").last.map(String.init) ?? "no output"
                return "wouldn't open — \(tool): \(line)"
            case .noArtifactProduced:    return "the archive has no files in it"
            case .sourceMissing(let s):  return "part of the archive is missing — \(s)"
            case .passphraseUnavailable: return "encrypted, and no passphrase is available on this Mac"
            }
        }
        if let r = e as? RestoreError {
            switch r {
            case .noManifest:                return "no checksum manifest beside the archive"
            case .verificationFailed(let d): return "checksums don't match — \(d)"
            case .libraryNotFound:           return "the archive didn't contain the library"
            case .destinationExists:         return "something is already in the way"
            }
        }
        return "wouldn't open — \((e as NSError).localizedDescription)"
    }
}

extension RecoveryRehearsal.Report {
    /// Express a rehearsal in the same shape as a health check, so it travels the
    /// paths that already exist — run history, the job row, notifications, remote
    /// alerts — instead of growing a second reporting system beside them.
    ///
    /// A library the jobs expect but that isn't there becomes a failed check with no
    /// version, because that is exactly what it is: nothing to check.
    public func asHealthReport(multiDestination: Bool) -> HealthReport {
        let dest = multiDestination ? destination : nil
        var checks = outcomes.map { o in
            ArchiveCheck(library: o.library, version: o.version,
                         passed: o.ok || o.skipped, detail: o.detail,
                         destination: dest, skipped: o.skipped)
        }
        checks += missing.map { lib in
            ArchiveCheck(library: lib, version: nil, passed: false,
                         detail: "nothing to recover here — a restore would not find this library",
                         destination: dest)
        }
        return HealthReport(checks: checks)
    }
}
