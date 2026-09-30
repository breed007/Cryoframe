//
//  PassphraseEscrow.swift
//  CryoframeKit
//
//  The recovery file: every archive passphrase in one place, encrypted with a
//  master password, so encrypted backups survive the Mac that made them. On a new
//  Mac there are no jobs and an empty Keychain, so the file is matched back to
//  archives by LIBRARY NAME — which makes how those names are stored load-bearing.
//
//  They used to be stored as one comma-joined string and split back apart on
//  import. A library whose own name contained a comma ("Client Work, 2026" — a
//  perfectly ordinary folder name, and custom libraries take their name from the
//  folder) came back as two names, neither of which matched anything, so that
//  library could never be unlocked. Names are a list now. The joined string is
//  still written so a file made here stays readable by older builds, and still
//  read as a fallback so their files stay readable here.
//

import Foundation

public enum PassphraseEscrow {

    public struct Entry: Codable, Identifiable, Sendable, Equatable {
        public var id = UUID()
        /// the job the passphrase belongs to; nil in files written before 1.6
        public var jobID: String?
        public var jobName: String
        /// the libraries this passphrase opens.
        public var libraries: [String]
        public var passphrase: String

        /// for display, and for the legacy `library` key on the wire.
        public var libraryList: String { libraries.joined(separator: ", ") }

        public init(jobID: String? = nil, jobName: String, libraries: [String], passphrase: String) {
            self.jobID = jobID; self.jobName = jobName; self.libraries = libraries; self.passphrase = passphrase
        }

        enum CodingKeys: String, CodingKey { case jobID, jobName, libraries, library, passphrase }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            jobID = try c.decodeIfPresent(String.self, forKey: .jobID)
            jobName = try c.decode(String.self, forKey: .jobName)
            passphrase = try c.decode(String.self, forKey: .passphrase)
            if let list = try c.decodeIfPresent([String].self, forKey: .libraries) {
                libraries = list
            } else {
                // pre-1.5 file: one joined string, so a comma inside a name is
                // ambiguous and always was. Split it and accept the old behaviour.
                let joined = try c.decodeIfPresent(String.self, forKey: .library) ?? ""
                libraries = joined.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(jobID, forKey: .jobID)
            try c.encode(jobName, forKey: .jobName)
            try c.encode(libraries, forKey: .libraries)
            try c.encode(libraryList, forKey: .library)   // legacy key, for older builds
            try c.encode(passphrase, forKey: .passphrase)
        }
    }

    // MARK: - file

    public static func exportData(_ entries: [Entry], password: String) -> Data? {
        guard let json = try? JSONEncoder().encode(entries) else { return nil }
        return EscrowCrypto.encrypt(json, password: password)
    }

    public static func importEntries(_ data: Data, password: String) -> [Entry]? {
        guard let json = EscrowCrypto.decrypt(data, password: password) else { return nil }
        return try? JSONDecoder().decode([Entry].self, from: json)
    }

    // MARK: - matching archives to keys

    /// Every passphrase the file holds for `library`, the likeliest first: those of
    /// `preferredJobs` (the jobs known to write the archive, when this Mac still has
    /// them), then the rest in file order. No repeats.
    ///
    /// Recovery used to take one passphrase per library name, the first it found. Two
    /// jobs can back up libraries of the same name (to different drives) with
    /// different passphrases, and a job deleted and made again gets a new one, so the
    /// passphrase taken could be the wrong one, and the wizard said "unlocked" all the
    /// same. Now every candidate is kept, and one counts only once it has opened the
    /// archive (KeyCheck).
    public static func candidates(for library: String, in entries: [Entry], preferring preferredJobs: Set<String> = []) -> [String] {
        let matching = entries.filter { $0.libraries.contains(library) }
        let ordered = matching.filter { $0.jobID.map(preferredJobs.contains) == true }
            + matching.filter { $0.jobID.map(preferredJobs.contains) != true }
        var seen = Set<String>(), out: [String] = []
        for e in ordered where seen.insert(e.passphrase).inserted { out.append(e.passphrase) }
        return out
    }

    /// library name → passphrase, the first entry claiming each library. Only a
    /// guess when two entries claim the same name: see `candidates`.
    public static func passphrasesByLibrary(_ entries: [Entry]) -> [String: String] {
        var map: [String: String] = [:]
        for e in entries {
            for lib in e.libraries where !lib.isEmpty {
                if map[lib] == nil { map[lib] = e.passphrase }
            }
        }
        return map
    }
}

/// Whether a passphrase opens an encrypted archive, proven by opening it.
///
/// The image is attached without mounting and detached at once: about a second, and
/// nothing on it is read. An archive that can't be tried that cheaply (split into
/// parts, which would have to be put back together first; evicted to the cloud,
/// which would have to be downloaded) is left unchecked, and its passphrase is tried
/// when it is restored.
public struct KeyCheck: Sendable {
    public enum Proof: Sendable, Equatable {
        /// the passphrase opened the archive
        case opens
        /// the archive refused it
        case wrongKey
        /// not tried, and why; tried when the archive is restored
        case unchecked(String)
        /// the archive isn't sound, whatever the passphrase: why
        case damaged(String)
    }

    let runner: CommandRunner
    let isEvicted: @Sendable (URL) -> Bool
    public init(runner: CommandRunner = ProcessCommandRunner(),
                isEvicted: @escaping @Sendable (URL) -> Bool = { CloudFile.anyDataless(in: $0) }) {
        self.runner = runner; self.isEvicted = isEvicted
    }

    /// what hdiutil says when the passphrase is wrong
    public static func isWrongKey(_ error: Error) -> Bool {
        guard case .toolFailed(_, _, let stderr)? = error as? ArchiveError else { return false }
        return stderr.localizedCaseInsensitiveContains("Authentication error")
    }

    public func check(_ archive: RestorableArchive, passphrase: String) -> Proof {
        guard archive.encrypted else { return .opens }
        guard archive.format != .sealedZip else { return .unchecked("a zip archive isn't encrypted by Cryoframe") }
        guard archive.artifactNames.count == 1, let name = archive.artifactNames.first else {
            return .unchecked("it is split into parts, so it is tried when it is restored")
        }
        let image = archive.dir.appendingPathComponent(name)
        guard !isEvicted(image) else { return .unchecked("it is in a cloud folder and not downloaded, so it is tried when it is restored") }
        // An image already attached (opened in Finder, as the recovery note says to,
        // or by a drill, a check or a restore) attaches again read-only with ANY
        // passphrase and hands back the holder's own disk, measured on macOS 26.7. That
        // proves nothing, and detaching that disk pulled it from under its reader. So
        // an image that is open anywhere isn't tried, and only a disk that wasn't
        // attached before this attach is counted, or detached.
        let look = runner.forTeardown
        // hdiutil info failing is "can't tell", not "nothing attached": taken for the
        // latter, a holder's disk would be counted as this attach's, and detached.
        let cantTell = Proof.unchecked("whether it is open elsewhere on this Mac couldn't be told, so it is tried when it is restored")
        guard let attached = MirrorMounts.attachedImagesIfKnown(runner: look) else { return cantTell }
        let target = image.resolvingSymlinksInPath().path
        guard !attached.contains(where: { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == target && !$0.devices.isEmpty }) else {
            return .unchecked("it is open elsewhere on this Mac, so it is tried when it is restored")
        }
        // A damaged header makes an encrypted image attach as a plain raw disk, with any
        // passphrase at all (measured: 8 zeroed bytes at the start). hdiutil reads the
        // header without a passphrase; one it doesn't find encrypted is damaged.
        if let r = try? look.run("/usr/bin/hdiutil", ["isencrypted", image.path], stdin: nil), r.ok,
           r.stdout.contains("encrypted: NO") {
            return .damaged("it doesn't read as an encrypted disk image any more, so it is damaged")
        }
        // attached without mounting, so held from before the attach until it is
        // detached (see ImageLock)
        return ImageLock.attaching(image, runner: runner) { () -> Proof in
            guard let before = MirrorMounts.attachedImagesIfKnown(runner: look).map({ Set($0.flatMap(\.devices)) }) else { return cantTell }
            let result: CommandResult
            do {
                result = try DiskImageGate.serialized {
                    try runner.runRetryingBusy("/usr/bin/hdiutil", ["attach", "-nomount", "-readonly", "-noverify", "-noautofsck",
                                                                    "-stdinpass", image.path], stdin: Data(passphrase.utf8))
                }
            } catch {
                return .unchecked(error.localizedDescription)
            }
            guard result.ok else {
                if result.stderr.localizedCaseInsensitiveContains("Authentication error") { return .wrongKey }
                let line = result.stderr.split(separator: "\n").last.map(String.init) ?? "hdiutil failed"
                return .unchecked(line.trimmingCharacters(in: .whitespaces))
            }
            // the first device listed is the image's own disk; detaching it detaches the rest
            guard let device = result.stdout.split(whereSeparator: \.isWhitespace).first(where: { $0.hasPrefix("/dev/disk") }).map(String.init),
                  !before.contains(device) else {
                return .unchecked("it was opened elsewhere on this Mac while it was being tried, so it is tried when it is restored")
            }
            if (try? look.runRetryingBusy("/usr/bin/hdiutil", ["detach", device], stdin: nil))?.ok != true {
                _ = try? look.run("/usr/bin/hdiutil", ["detach", "-force", device], stdin: nil)
            }
            return .opens
        }
    }

    /// The first of `candidates` that opens `archive`, with the proof. When none
    /// opens it: nil and `.wrongKey`. When it can't be tried: the first candidate, and
    /// `.unchecked`. No candidates: nil and `.wrongKey`.
    public func firstOpening(_ archive: RestorableArchive, candidates: [String]) -> (passphrase: String?, proof: Proof) {
        var unchecked: Proof?
        for pass in candidates {
            switch check(archive, passphrase: pass) {
            case .opens: return (pass, .opens)
            case .damaged(let why): return (nil, .damaged(why))
            case .wrongKey: continue
            case .unchecked(let why):
                if unchecked == nil { unchecked = .unchecked(why) }
            }
        }
        if let unchecked, let first = candidates.first { return (first, unchecked) }
        return (nil, .wrongKey)
    }
}

/// When the recovery file was last exported, and whether it still covers every
/// encrypted job's passphrase.
///
/// Nothing said when it went stale: a job made or encrypted after the export, or one
/// whose libraries changed, isn't in the file (or is under names a new Mac won't
/// match), and that surfaces only on the day the file is needed.
public enum EscrowFreshness {
    /// what an export covered: kept by the app, with no passphrase in it
    public struct Export: Codable, Sendable, Equatable {
        public var exportedAt: Date
        /// job id → the library names the file holds its passphrase under
        public var jobs: [String: [String]]
        public init(exportedAt: Date, jobs: [String: [String]]) { self.exportedAt = exportedAt; self.jobs = jobs }
    }

    /// an encrypted job with a saved passphrase, as it is now
    public struct Job: Sendable, Equatable {
        public let id: String, name: String, libraries: [String]
        /// when its passphrase was saved (the keychain item's date); nil if unknown
        public let keySavedAt: Date?
        public init(id: String, name: String, libraries: [String], keySavedAt: Date?) {
            self.id = id; self.name = name; self.libraries = libraries; self.keySavedAt = keySavedAt
        }
    }

    public enum Status: Sendable, Equatable {
        /// no encrypted job, nothing to export
        case notNeeded
        /// no export is recorded on this Mac. Not "never exported": exports made before
        /// 1.6 weren't recorded, so someone who exported then has a file all the same.
        case noExportRecorded
        case current(Date)
        /// exported at the date, and these jobs have changed since (plain sentences)
        case outOfDate(Date, [String])
    }

    public static func status(export: Export?, jobs: [Job]) -> Status {
        guard !jobs.isEmpty else { return .notNeeded }
        guard let export else { return .noExportRecorded }
        var reasons: [String] = []
        for job in jobs {
            guard let covered = export.jobs[job.id] else { reasons.append("\(job.name) isn't in it"); continue }
            if Set(covered) != Set(job.libraries) { reasons.append("\(job.name)'s libraries have changed"); continue }
            if let saved = job.keySavedAt, saved > export.exportedAt { reasons.append("\(job.name)'s passphrase was saved after it") }
        }
        return reasons.isEmpty ? .current(export.exportedAt) : .outOfDate(export.exportedAt, reasons)
    }

    /// What the main window says about the recovery file, or nil when all is well.
    public static func notice(_ status: Status) -> String? {
        switch status {
        case .notNeeded, .current: return nil
        case .noExportRecorded:
            return "Cryoframe has no record of your recovery file being exported from this Mac (exports made before version 1.6 weren't recorded). Without an up-to-date one, your encrypted backups can't be opened on another Mac. If you haven't exported it since your encrypted jobs last changed, export it now and keep it apart from the backups."
        case .outOfDate(_, let why):
            return "Your recovery file is out of date (\(why.joined(separator: "; "))). Export a new one so every encrypted backup can be opened on another Mac."
        }
    }

    /// what an export of `entries` covers
    public static func record(_ entries: [PassphraseEscrow.Entry], at date: Date) -> Export {
        var jobs: [String: [String]] = [:]
        for e in entries { if let id = e.jobID { jobs[id] = e.libraries } }
        return Export(exportedAt: date, jobs: jobs)
    }
}
