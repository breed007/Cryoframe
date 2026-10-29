//
//  BandCheck.swift
//  CryoframeKit
//
//  A rolling check of a live mirror's data bands for decay.
//
//  A mirror's checksum is structural (see Checksum.digest): it says which bands an
//  image has, not what is in them, because hashing every band would read the whole
//  drive on every run. A failing drive that changes a block of a band nobody rewrites
//  went unseen until a restore, and APFS keeps no checksums of file data, so on an
//  encrypted image the rotted block decrypts to garbage without an error.
//
//  So each band's size, modification time and SHA-256 are kept beside the manifest
//  (BandTable). At each seal the bands this run changed are read and recorded, and a
//  slice of the unchanged ones is read again, oldest first. An unchanged band whose
//  contents no longer match is decay. The bands are what is on the drive, ciphertext
//  on an encrypted mirror, so the check needs no passphrase and nothing attached.
//

import Foundation

/// What a mirror's data bands were when last recorded, kept beside the manifest as
/// `cryoframe-bands.v1`: one line a band, written whole each time.
///
/// Mirror history keeps a copy of it with each entry, so a history entry can be
/// checked the same way.
public struct BandTable: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var size: UInt64
        /// modification time, in nanoseconds since 1970
        public var mtime: Int64
        /// SHA-256 of the band as last read; nil: recorded, not read yet
        public var sha256: String?
        /// when it was last read and recorded or matched; nil: not read yet
        public var verifiedAt: Date?

        public init(size: UInt64, mtime: Int64, sha256: String? = nil, verifiedAt: Date? = nil) {
            self.size = size; self.mtime = mtime; self.sha256 = sha256; self.verifiedAt = verifiedAt
        }
    }

    /// by band name, as the image names them (hex numbers)
    public var entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) { self.entries = entries }

    public static let fileName = "cryoframe-bands.v1"

    /// the band table in `dir`; nil when there is none. One that is there and can't be
    /// read throws, so the caller can say so rather than start over in silence.
    public static func read(in dir: URL) throws -> BandTable? {
        let url = dir.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.first == Substring(fileName) else { throw BandTableError.unreadable(url.path) }
        lines.removeFirst()
        var entries: [String: Entry] = [:]
        for line in lines {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count == 5, !f[0].isEmpty, let size = UInt64(f[1]), let mtime = Int64(f[2]) else {
                throw BandTableError.unreadable(url.path)
            }
            let sha = f[3] == "-" ? nil : String(f[3])
            let at = f[4] == "-" ? nil : Int64(f[4]).map { Date(timeIntervalSince1970: TimeInterval($0)) }
            guard sha == nil || sha?.count == 64, f[4] == "-" || at != nil else { throw BandTableError.unreadable(url.path) }
            entries[String(f[0])] = Entry(size: size, mtime: mtime, sha256: sha, verifiedAt: at)
        }
        return BandTable(entries: entries)
    }

    /// written to a temporary file and renamed, so a crash never leaves half a table
    public func write(in dir: URL) throws {
        var text = Self.fileName + "\n"
        for name in BandCheck.ordered(Array(entries.keys)) {
            guard let e = entries[name] else { continue }
            let at = e.verifiedAt.map { String(Int64($0.timeIntervalSince1970.rounded(.down))) } ?? "-"
            text += [name, String(e.size), String(e.mtime), e.sha256 ?? "-", at].joined(separator: "\t") + "\n"
        }
        try Data(text.utf8).write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
    }

    public static func remove(in dir: URL) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(fileName))
    }
}

public enum BandTableError: Error, Equatable {
    case unreadable(String)
}

/// one band as found on the drive
public struct BandStat: Sendable, Equatable {
    public var name: String
    public var size: UInt64
    /// nanoseconds since 1970
    public var mtime: Int64
    public init(name: String, size: UInt64, mtime: Int64) { self.name = name; self.size = size; self.mtime = mtime }
}

/// What one mirror's check found, for its run record and the destination's health.
public struct BandCheckReport: Codable, Sendable, Equatable {
    public var library: String
    public var destination: String
    /// bands the image has
    public var total: Int
    /// unchanged bands read this run, the rolling part of the check
    public var checked: Int
    /// bands this run changed, read and recorded
    public var recorded: Int
    /// unchanged bands whose contents no longer match: decay
    public var mismatches: Int
    /// the damaged bands, by name
    public var damaged: [String]
    /// bands read within the last 30 days
    public var recent: Int
    /// bands not read since they were last changed (the first month, or a slice cut short)
    public var unverified: Int
    /// when the band read longest ago was read; nil when none has been read
    public var oldestVerified: Date?
    /// the time limit ended the check before its slice was done
    public var stoppedEarly: Bool
    /// why the mirror wasn't checked (a cloud folder whose bands aren't downloaded)
    public var skipped: String?
    /// why the check couldn't be made, or was cut off: a band that couldn't be read,
    /// say. That isn't decay, and the run only says so.
    public var error: String?

    public init(library: String, destination: String = "", total: Int = 0, checked: Int = 0, recorded: Int = 0,
                mismatches: Int = 0, damaged: [String] = [], recent: Int = 0, unverified: Int = 0,
                oldestVerified: Date? = nil, stoppedEarly: Bool = false, skipped: String? = nil, error: String? = nil) {
        self.library = library; self.destination = destination; self.total = total; self.checked = checked
        self.recorded = recorded; self.mismatches = mismatches; self.damaged = damaged; self.recent = recent
        self.unverified = unverified; self.oldestVerified = oldestVerified; self.stoppedEarly = stoppedEarly
        self.skipped = skipped; self.error = error
    }

    /// the check found decay. One that couldn't be made hasn't failed: it says so.
    public var failed: Bool { mismatches > 0 }
}

/// The band checks of one run, as its record keeps them.
public struct BandCheckSummary: Codable, Sendable, Equatable {
    public var copies: [BandCheckReport]
    public init(copies: [BandCheckReport]) { self.copies = copies }

    var made: [BandCheckReport] { copies.filter { $0.skipped == nil && $0.error == nil } }
    public var checked: Int { made.reduce(0) { $0 + $1.checked } }
    public var total: Int { made.reduce(0) { $0 + $1.total } }
    public var mismatches: Int { copies.reduce(0) { $0 + $1.mismatches } }
    public var oldestVerified: Date? { made.compactMap(\.oldestVerified).min() }
    public var failed: Bool { copies.contains(where: \.failed) }

    /// what the run's summary adds: "checked 3% of the mirror for decay; all of it
    /// within the last 29 days"
    public func line(at now: Date) -> String {
        let damaged = copies.filter { $0.mismatches > 0 }
        if !damaged.isEmpty {
            let n = mismatches
            return "found decay in \(n) of the mirror's data bands, so it can't be trusted: start it over"
                + (damaged.count > 1 || copies.count > 1 ? " (\(damaged.map(\.library).joined(separator: ", ")))" : "")
        }
        if let broken = copies.first(where: { $0.error != nil }), let why = broken.error {
            return "the mirror couldn't be checked for decay (\(why))"
        }
        let made = self.made
        guard !made.isEmpty else {
            return "the mirror wasn't checked for decay (\(copies.first?.skipped ?? "nothing to check"))"
        }
        let total = self.total
        let head = "checked \(BandCheck.percent(checked, of: total)) of the mirror for decay"
        return head + "; " + BandCheck.coverage(recent: made.reduce(0) { $0 + $1.recent },
                                                unverified: made.reduce(0) { $0 + $1.unverified },
                                                total: total, oldest: oldestVerified, now: now)
    }
}

/// How much of a mirror has been checked, as a destination's health shows it.
public struct BandCoverage: Codable, Sendable, Equatable {
    public var total: Int
    public var recent: Int
    public var unverified: Int
    public var oldest: Date?
    public init(total: Int, recent: Int, unverified: Int, oldest: Date?) {
        self.total = total; self.recent = recent; self.unverified = unverified; self.oldest = oldest
    }

    /// the band checks a run made at one destination, together
    public init?(_ reports: [BandCheckReport]) {
        let made = reports.filter { $0.skipped == nil && $0.error == nil }
        guard !made.isEmpty else { return nil }
        total = made.reduce(0) { $0 + $1.total }
        recent = made.reduce(0) { $0 + $1.recent }
        unverified = made.reduce(0) { $0 + $1.unverified }
        oldest = made.compactMap(\.oldestVerified).min()
    }

    /// "Whole mirror checked for decay within the last 29 days", or "61% checked for
    /// decay so far" during the first month
    public func line(at now: Date) -> String {
        if total > 0, unverified == 0, recent == total, let oldest {
            return "Whole mirror checked for decay within the last \(BandCheck.days(since: oldest, to: now))"
        }
        if unverified > 0 { return "\(BandCheck.percent(total - unverified, of: total)) of the mirror checked for decay so far" }
        return "\(BandCheck.percent(recent, of: total)) of the mirror checked for decay in the last 30 days"
    }
}

/// How a job executor checks the mirrors it writes, from the app's settings.
public struct BandCheckPolicy: Sendable, Equatable {
    /// how long one mirror's check may read for, each run
    public var timeCap: TimeInterval
    /// "Download cloud archives to check them": a mirror in a cloud folder is read too
    public var downloadCloud: Bool

    public init(timeCap: TimeInterval = BandCheck.defaultTimeCap, downloadCloud: Bool = false) {
        self.timeCap = timeCap; self.downloadCloud = downloadCloud
    }

    public func settings(for job: BackupJob, target: Target) -> BandCheck.Settings {
        BandCheck.Settings(interval: job.frequency.interval ?? BandCheck.manualInterval, timeCap: timeCap,
                           skip: target.kind == .cloudSync && !downloadCloud ? BandCheck.cloudSkip : nil)
    }
}

public enum BandCheck {
    /// what a run's check is allowed
    public struct Settings: Sendable, Equatable {
        /// how often the job runs: each run reads its share of a 30-day round
        public var interval: TimeInterval
        /// how long a run's check may read for
        public var timeCap: TimeInterval
        /// why this mirror isn't checked at all (nil: it is)
        public var skip: String?
        public init(interval: TimeInterval, timeCap: TimeInterval = BandCheck.defaultTimeCap, skip: String? = nil) {
            self.interval = interval; self.timeCap = timeCap; self.skip = skip
        }
    }

    /// every band is read again within this long, when the runs allow it
    public static let window: TimeInterval = 30 * 86_400
    /// the fewest unchanged bands a run reads (512 MB of 8 MB bands)
    public static let floor = 64
    public static let defaultTimeCap: TimeInterval = 600
    /// a job that runs only when asked is taken to run daily
    public static let manualInterval: TimeInterval = 86_400

    /// what a cloud folder's mirror says when its bands would have to be downloaded
    public static let cloudSkip = "it's in a cloud folder, and reading it would download it; turn on Download cloud archives to check them"

    /// How many unchanged bands a run reads: its share of reading them all every 30
    /// days, at least `floor`, never more than there are.
    public static func sliceSize(total: Int, interval: TimeInterval) -> Int {
        guard total > 0 else { return 0 }
        let share = (Double(total) * max(interval, 0) / window).rounded(.up)
        return min(total, max(floor, share >= Double(Int.max) ? Int.max : Int(share)))
    }

    /// what a band found on the drive is, against what the table recorded
    public enum Kind: Equatable, Sendable {
        /// not in the table: the run added it
        case new
        /// its size or modification time moved: written since it was recorded, by this
        /// run or another (a run of an older Cryoframe after a downgrade). Recorded again.
        case changed
        /// as recorded: its contents should be too
        case unchanged
    }

    public static func classify(_ found: BandStat, recorded: BandTable.Entry?) -> Kind {
        guard let recorded else { return .new }
        return recorded.size == found.size && recorded.mtime == found.mtime ? .unchanged : .changed
    }

    public struct Plan: Equatable, Sendable {
        /// the table with every band as found: changed ones not read yet, gone ones dropped
        public var table: BandTable
        /// bands to read and record, in band order
        public var rehash: [String]
        /// unchanged bands to read again, oldest-read first
        public var slice: [String]
        /// bands the table had that the image no longer has (compact removed them)
        public var dropped: [String]
    }

    /// What a check reads. Without a table (the mirror's first check), every band is
    /// recorded unread, and the rolling slices read them in turn; the first month says
    /// how far that has got.
    public static func plan(table: BandTable?, found: [BandStat], sliceSize: Int) -> Plan {
        var next = BandTable()
        var rehash: [String] = []
        var candidates: [String] = []
        for band in found {
            guard let table else {
                next.entries[band.name] = .init(size: band.size, mtime: band.mtime)
                candidates.append(band.name)
                continue
            }
            let recorded = table.entries[band.name]
            switch classify(band, recorded: recorded) {
            case .new, .changed:
                next.entries[band.name] = .init(size: band.size, mtime: band.mtime)
                rehash.append(band.name)
            case .unchanged:
                next.entries[band.name] = recorded
                candidates.append(band.name)
            }
        }
        let dropped = table.map { t in ordered(t.entries.keys.filter { next.entries[$0] == nil }) } ?? []
        let slice = oldestFirst(candidates, in: next).prefix(max(sliceSize, 0))
        return Plan(table: next, rehash: ordered(rehash), slice: Array(slice), dropped: dropped)
    }

    /// never-read bands first, then by when each was last read; band order among equals.
    /// The table is the cursor: what a run doesn't get to is first in line at the next.
    static func oldestFirst(_ names: [String], in table: BandTable) -> [String] {
        let keyed = names.map { ($0, table.entries[$0]?.verifiedAt ?? .distantPast, number($0)) }
        return keyed.sorted { a, b in a.1 != b.1 ? a.1 < b.1 : (a.2, a.0) < (b.2, b.0) }.map(\.0)
    }

    /// band names in band order (they are hex numbers)
    static func ordered(_ names: [String]) -> [String] {
        names.sorted { (number($0), $0) < (number($1), $1) }
    }

    private static func number(_ name: String) -> Int { Int(name, radix: 16) ?? Int.max }

    /// the bands of `bundle` as they are on the drive. Throws when they can't be listed.
    public static func stats(of bundle: URL) throws -> [BandStat] {
        let dir = bundle.appendingPathComponent("bands", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        var out: [BandStat] = []
        for name in names where Int(name, radix: 16) != nil {
            var st = stat()
            guard lstat(dir.appendingPathComponent(name).path, &st) == 0 else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: dir.appendingPathComponent(name).path,
                                                             NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)])
            }
            guard (st.st_mode & S_IFMT) == S_IFREG else { continue }
            out.append(BandStat(name: name, size: UInt64(st.st_size),
                                mtime: Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)))
        }
        return out
    }

    /// Check the bands of the sealed mirror `bundle`, whose table is in `dir`, and
    /// record what was read. Nothing may write to the image meanwhile: the caller holds
    /// the job's run lock, with the image detached.
    ///
    /// The time cap covers the whole check. Bands this run changed are read first,
    /// since a band not read until later could rot unseen in between; any the cap
    /// leaves unread are recorded unread, and are first in line next time.
    ///
    /// Only an unchanged band that reads back other than it was recorded is decay. One
    /// that can't be read isn't: an unplugged drive, a share that timed out and a cloud
    /// file that couldn't be fetched all fail that way. The first such band ends the
    /// check, which says why, and the table is left as it was, so nothing this run read
    /// counts and the next run tries again. Stop ends the check where it is, and what
    /// was read is kept.
    public static func run(bundle: URL, in dir: URL, library: String, settings: Settings, now: Date = Date(),
                           clock: () -> Date = Date.init, control: RunControl? = nil,
                           hash: (URL, RunControl?) throws -> String = { try Checksum.sha256(of: $0, control: $1) }) -> BandCheckReport {
        var report = BandCheckReport(library: library)
        if let skip = settings.skip { report.skipped = skip; return report }
        let found: [BandStat]
        do { found = try stats(of: bundle) } catch {
            report.error = "its data bands couldn't be listed: \(error.localizedDescription)"
            return report
        }
        var table: BandTable?
        var unreadable = false
        do { table = try BandTable.read(in: dir) } catch { unreadable = true }
        let size = sliceSize(total: found.count, interval: settings.interval)
        var work = Self.plan(table: table, found: found, sliceSize: size)
        let bands = bundle.appendingPathComponent("bands", isDirectory: true)
        let deadline = clock().addingTimeInterval(settings.timeCap)
        let bytes = (work.rehash + work.slice).reduce(UInt64(0)) { $0 + (work.table.entries[$1]?.size ?? 0) }
        control?.begin("Checking the mirror for decay", stage: .verifying, unit: .bytes, total: bytes)
        defer { control?.endStep() }

        var damaged: [String] = []
        var stopped = false
        var unread: (band: String, why: Error)?
        func readBand(_ name: String) -> String? {
            if stopped || control?.isCancelled == true || clock() >= deadline { stopped = true; return nil }
            defer { control?.advance(by: work.table.entries[name]?.size ?? 0) }
            do { return try hash(bands.appendingPathComponent(name), control) }
            catch is CancelledError { stopped = true; return nil }
            catch { unread = (name, error); stopped = true; return nil }
        }
        for name in work.rehash {
            guard let sha = readBand(name) else { break }
            work.table.entries[name]?.sha256 = sha
            work.table.entries[name]?.verifiedAt = now
            report.recorded += 1
        }
        for name in work.slice {
            guard let sha = readBand(name) else { break }
            report.checked += 1
            if let recorded = work.table.entries[name]?.sha256, recorded != sha {
                damaged.append(name)            // the recorded hash is kept: it is what the band should hold
                continue
            }
            work.table.entries[name]?.sha256 = sha
            work.table.entries[name]?.verifiedAt = now
        }
        report.stoppedEarly = stopped && unread == nil && clock() >= deadline
        if let unread {
            // the table stays as it was: what this run read counts for nothing
            report.error = FileManager.default.fileExists(atPath: bands.path)
                ? "data band \(unread.band) couldn't be read (\(unread.why.localizedDescription))"
                : "the mirror's drive went away during the check"
        } else {
            do { try work.table.write(in: dir) } catch {
                report.error = "what was read couldn't be recorded beside the mirror: \(error.localizedDescription)"
            }
        }
        if unreadable, report.error == nil {
            // what was recorded is lost, and the file sits on the same drive: said, and
            // checking starts over from the table just written
            report.error = "the record of its data bands couldn't be read, so checking them has started over"
        }
        report.total = work.table.entries.count
        report.mismatches = damaged.count
        report.damaged = ordered(damaged)
        let since = now.addingTimeInterval(-window)
        let hashed = work.table.entries.values.filter { $0.sha256 != nil }
        report.unverified = work.table.entries.count - hashed.count
        report.recent = hashed.filter { ($0.verifiedAt ?? .distantPast) >= since }.count
        report.oldestVerified = hashed.compactMap(\.verifiedAt).min()
        return report
    }

    /// "3%", "under 1%" for a few bands of many, "100%"
    static func percent(_ part: Int, of whole: Int) -> String {
        guard whole > 0 else { return "0%" }
        let p = part * 100 / whole
        return p == 0 && part > 0 ? "under 1%" : "\(p)%"
    }

    /// "29 days", "day" (as in "within the last day")
    static func days(since: Date, to now: Date) -> String {
        let n = max(1, Int((now.timeIntervalSince(since) / 86_400).rounded(.up)))
        return n == 1 ? "day" : "\(n) days"
    }

    /// what the summary says after what this run read
    static func coverage(recent: Int, unverified: Int, total: Int, oldest: Date?, now: Date) -> String {
        if total > 0, unverified == 0, recent == total, let oldest {
            return "all of it within the last \(days(since: oldest, to: now))"
        }
        if unverified > 0 { return "\(percent(total - unverified, of: total)) checked so far" }
        return "\(percent(recent, of: total)) of it within the last 30 days"
    }
}
