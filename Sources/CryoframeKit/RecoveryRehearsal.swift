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
    /// free bytes on the drive holding a folder (nil: unknown); injectable for tests
    let freeSpace: @Sendable (URL) -> UInt64?
    public init(runner: CommandRunner = ProcessCommandRunner(),
                freeSpace: @escaping @Sendable (URL) -> UInt64? = { JobExecutor.freeSpace(for: $0) }) {
        self.runner = runner; self.freeSpace = freeSpace
    }

    public struct LibraryOutcome: Sendable, Equatable {
        public let library: String
        /// whose archive it is, from its folder's identity (nil for a 1.5 folder)
        public let key: String?
        public let version: Date?
        public let ok: Bool
        /// encrypted, and no key on this Mac — not a failure of the archive.
        public let locked: Bool
        public let skipped: Bool
        public let detail: String

        public init(library: String, key: String? = nil, version: Date?, ok: Bool, locked: Bool = false,
                    skipped: Bool = false, detail: String) {
            self.library = library; self.key = key; self.version = version; self.ok = ok
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

        /// Stop ended the rehearsal before it opened everything: `outcomes` holds only
        /// the libraries finished before it (see HealthReport.canceled)
        public let canceled: Bool
        /// how many libraries it set out to open
        public let planned: Int

        public var passed: Bool { missing.isEmpty && outcomes.allSatisfy { $0.ok || $0.skipped } }
        public var openedCount: Int { outcomes.filter { $0.ok && !$0.skipped }.count }

        public init(destination: String, moment: Date?, outcomes: [LibraryOutcome], missing: [String],
                    canceled: Bool = false, planned: Int? = nil) {
            self.destination = destination; self.moment = moment
            self.outcomes = outcomes; self.missing = missing
            self.canceled = canceled; self.planned = planned ?? outcomes.count
        }
    }

    /// Rehearse recovering from `destination`, exactly as the recovery flow would.
    ///
    /// - Parameters:
    ///   - expecting: library names the jobs writing here claim to protect, so a
    ///     library that has silently stopped arriving can be named.
    ///   - passphrase: key for an encrypted library, by library name. A library with
    ///     no key is reported locked rather than failed — nothing is wrong with it.
    ///   - alsoKnownAs: other names an expected library may be found under (the
    ///     ones it had before it was renamed, until a run brings its folder up to date)
    ///   - isCloud: skip archives evicted to placeholders instead of pulling gigabytes.
    ///
    /// Stop is the runner's, looked at between libraries; the library it came in the
    /// middle of isn't counted, and the report is marked canceled (see RestoreDriller).
    public func rehearse(destination: URL,
                         expecting: [String],
                         alsoKnownAs: [String: [String]] = [:],
                         isCloud: Bool = false,
                         materializeCloud: Bool = false,
                         passphrase: @Sendable (String) -> String? = { _ in nil }) -> Report {
        rehearse(Self.plan(destination: destination, expecting: expecting, alsoKnownAs: alsoKnownAs),
                 isCloud: isCloud, materializeCloud: materializeCloud, passphrase: passphrase)
    }

    /// what a rehearsal of one destination will look at, found before anything is opened
    public struct Plan: Sendable {
        let destination: URL
        let moment: Date?
        let selections: [RecoveryPlan.Selection]
        let missing: [String]
        /// the libraries it will open, and the ones it can't find
        public var planned: Int { selections.count + missing.count }
    }

    /// Scan `destination` the way a recovery does (see `rehearse`), opening nothing.
    public static func plan(destination: URL, expecting: [String], alsoKnownAs: [String: [String]] = [:]) -> Plan {
        let archives = RestoreDiscovery.scan(destination)     // the recovery entry point
        let found = Set(archives.map(\.displayName))
        let missing = expecting.filter { name in !([name] + (alsoKnownAs[name] ?? [])).contains(where: found.contains) }.sorted()
        let moment = RecoveryPlan.moments(in: archives).last
        let selections = moment.map { RecoveryPlan.selections(at: $0, in: archives) }
            ?? RecoveryPlan.selections(at: Date(), in: archives)
        return Plan(destination: destination, moment: moment, selections: selections, missing: missing)
    }

    /// one destination of a job's rehearsal
    public struct Place: Sendable {
        public let destination: URL
        public let isCloud: Bool
        public init(destination: URL, isCloud: Bool = false) { self.destination = destination; self.isCloud = isCloud }
    }

    /// Rehearse a job's recovery from each of `places` in turn, as one check. Every
    /// destination is scanned first, so a rehearsal Stop ends part-way says how many
    /// libraries it got through of all it set out to look at, not of the destinations
    /// it reached ("of 2" for a job whose second drive held 2 more).
    public func rehearse(_ places: [Place], expecting: [String], alsoKnownAs: [String: [String]] = [:],
                         materializeCloud: Bool = false, multiDestination: Bool,
                         passphrase: @Sendable (String) -> String? = { _ in nil }) -> HealthReport {
        let plans = places.map { Self.plan(destination: $0.destination, expecting: expecting, alsoKnownAs: alsoKnownAs) }
        let all = plans.reduce(0) { $0 + $1.planned }
        var checks: [ArchiveCheck] = []
        for (place, plan) in zip(places, plans) {
            let report = rehearse(plan, isCloud: place.isCloud, materializeCloud: materializeCloud, passphrase: passphrase)
                .asHealthReport(multiDestination: multiDestination)
            checks += report.checks
            if report.canceled { return HealthReport(checks: checks, canceled: true, planned: all) }
        }
        return HealthReport(checks: checks, planned: all)
    }

    func rehearse(_ plan: Plan, isCloud: Bool, materializeCloud: Bool,
                  passphrase: @Sendable (String) -> String?) -> Report {
        let destination = plan.destination, moment = plan.moment, selections = plan.selections, missing = plan.missing

        let control = runner.control
        let quiet = (runner as? ProcessCommandRunner)?.quietLimit ?? control?.quietLimit ?? ToolWatchdog.defaultQuietLimit
        var outcomes: [LibraryOutcome] = []
        for selection in selections {
            if control?.isCancelled == true {
                return Report(destination: destination.lastPathComponent, moment: moment, outcomes: outcomes, missing: missing,
                              canceled: true, planned: selections.count)
            }
            let outcome = rehearseOne(selection.archive, isCloud: isCloud, materializeCloud: materializeCloud,
                                      quiet: quiet, passphrase: passphrase)
            // Stop part-way through: whatever this library's outcome said, it didn't finish
            if control?.isCancelled == true {
                return Report(destination: destination.lastPathComponent, moment: moment, outcomes: outcomes, missing: missing,
                              canceled: true, planned: selections.count)
            }
            outcomes.append(outcome)
        }
        return Report(destination: destination.lastPathComponent, moment: moment,
                      outcomes: outcomes, missing: missing)
    }

    private func rehearseOne(_ a: RestorableArchive, isCloud: Bool, materializeCloud: Bool, quiet: TimeInterval,
                             passphrase: @Sendable (String) -> String?) -> LibraryOutcome {
        if isCloud, CloudFile.anyDataless(of: a) {
            guard materializeCloud else {
                return LibraryOutcome(library: a.libraryName, key: LibraryFolders.checkKey(of: a), version: a.version, ok: true,
                                      skipped: true, detail: "not downloaded — skipped")
            }
            // watched, and ended by Stop (the caller sees that); what came down stays
            do {
                try CloudDownload.system.bringDown(a.archiveResult().artifacts, quietLimit: quiet, control: runner.control)
            } catch {
                return LibraryOutcome(library: a.libraryName, key: LibraryFolders.checkKey(of: a), version: a.version, ok: false,
                                      detail: Self.reason(error, encrypted: a.encrypted))
            }
        }
        let key = a.encrypted ? passphrase(a.displayName) : nil
        if a.encrypted, key == nil {
            return LibraryOutcome(library: a.libraryName, key: LibraryFolders.checkKey(of: a), version: a.version, ok: false, locked: true,
                                  detail: "encrypted, and no passphrase is available on this Mac")
        }
        do {
            // the same three things a recovery does before it copies anything
            let sidecar = a.dir.appendingPathComponent(ArchiveManifest.sidecarName)
            let manifest = try ArchiveManifest.read(sidecar)
            let report = try ChecksumVerifier(control: runner.control).verify(manifest, in: a.dir)
            guard report.passed else {
                return LibraryOutcome(library: a.libraryName, key: LibraryFolders.checkKey(of: a), version: a.version, ok: false,
                                      detail: "checksums don't match — \(report.details)")
            }
            let opened = try ArchiveReader(runner: runner, freeSpace: freeSpace).open(a.archiveResult(), passphrase: key)
            defer { opened.close() }
            // A mirror holds the library at <volume>/<name>, which is what a restore
            // copies. Its volume root is never empty (.fseventsd), so looking there
            // passed a mirror a restore would find nothing in.
            let look = a.format == .liveMirror ? opened.root.appendingPathComponent(a.bundleName) : opened.root
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: look.path)) ?? []
            guard !entries.isEmpty else {
                return LibraryOutcome(library: a.libraryName, key: LibraryFolders.checkKey(of: a), version: a.version, ok: false,
                                      detail: "opened, but there is nothing inside it")
            }
            return LibraryOutcome(library: a.libraryName, key: LibraryFolders.checkKey(of: a), version: a.version, ok: true,
                                  detail: "opened and readable")
        } catch let e as RestoreError {
            // no room on the startup disk to join or unpack it says nothing about the
            // archive (as for a drill, see RestoreDriller): skipped, and why
            if case .notEnoughRoom = e {
                return LibraryOutcome(library: a.libraryName, key: LibraryFolders.checkKey(of: a), version: a.version, ok: true, skipped: true,
                                      detail: "not rehearsed: " + Self.reason(e, encrypted: a.encrypted))
            }
            return LibraryOutcome(library: a.libraryName, key: LibraryFolders.checkKey(of: a), version: a.version, ok: false,
                                  detail: Self.reason(e, encrypted: a.encrypted))
        } catch {
            return LibraryOutcome(library: a.libraryName, key: LibraryFolders.checkKey(of: a), version: a.version, ok: false,
                                  detail: Self.reason(error, encrypted: a.encrypted))
        }
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
                let line = ProcessCommandRunner.meaningful(stderr).split(separator: "\n").last.map(String.init) ?? "no output"
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
            case .notEnoughRoom(let needed, let free, let volume, _):
                let f = ByteCountFormatter()
                return "not enough room on \(volume) to rehearse the restore: it needs about \(f.string(fromByteCount: Int64(clamping: needed))) free and has \(f.string(fromByteCount: Int64(clamping: free)))"
            }
        }
        if let copy = RestoreFailureText.copyFailure(e) { return copy }
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
                         destination: dest, skipped: o.skipped, libraryKey: o.key)
        }
        // Found before anything was opened, so a stopped rehearsal keeps them too: a
        // library a recovery wouldn't find is the finding this exists for, and Stop
        // pressed a moment in shouldn't hide it. A stopped one says how many it got
        // through, of how many (see CanceledCheck).
        checks += missing.map { lib in
            ArchiveCheck(library: lib, version: nil, passed: false,
                         detail: "nothing to recover here — a restore would not find this library",
                         destination: dest)
        }
        return HealthReport(checks: checks, canceled: canceled, planned: planned + missing.count)
    }
}
