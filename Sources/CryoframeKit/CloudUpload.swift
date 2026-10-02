//
//  CloudUpload.swift
//  CryoframeKit
//
//  Whether a backup written into a cloud folder has reached the cloud.
//
//  A run into a cloud folder is finished when the files are in the folder on this
//  Mac; the provider uploads them afterward, maybe hours later, maybe never (signed
//  out, over quota, paused). Until it does, the "offsite" copy is on the same disk
//  as the original.
//
//  This fails safe. macOS has keys for upload state (ubiquitousItemIsUploaded and
//  friends), but no provider's answer is believed until a smoke test against a real
//  account has shown it means what it says: the allowlist below starts empty, iCloud
//  included. Until a provider is on it, the only proof of upload is a file the
//  provider has evicted to a placeholder (it can't drop the local copy of something
//  it doesn't hold). Everything else is "can't tell", shown gray, never as uploaded
//  and never as a problem. "Not offsite yet" is raised only when an allowlisted
//  provider says a version still isn't uploaded a day after its run.
//
//  The versions not yet known to be uploaded are kept in upload-status.json (see
//  UploadLedger), at most 100 per destination; older ones are folded into a count
//  that keeps any warning they carried until the destination is checked again whole.
//

import Foundation

public enum CloudUpload {
    /// Providers whose upload keys have passed the smoke test (cloud-upload-probe,
    /// run against a signed-in account) and are believed. Empty: none has been.
    public static let verifiedProviders: Set<CloudProvider> = []

    /// how long after its run a version a verified provider hasn't uploaded is "not offsite yet"
    public static let attentionAfter: TimeInterval = 24 * 3600

    /// what to say when a provider's word isn't taken
    public static func unknownText(_ provider: CloudProvider) -> String {
        if provider == .iCloud {
            return "iCloud reports whether a file is uploaded, but Cryoframe doesn't rely on that yet; check iCloud Drive in Finder."
        }
        let name = provider == .generic ? "This cloud service" : provider.displayName
        return "\(name) doesn't tell other apps whether a file is uploaded; check its menu."
    }
}

/// a version's (or a file's) upload state
public enum UploadStatus: Codable, Sendable, Equatable {
    /// in the cloud: evicted to a placeholder, or a verified provider says so
    case uploaded
    /// a verified provider says it isn't uploaded yet
    case uploading
    /// a verified provider reports an upload error
    case failed(String)
    /// can't tell: the provider isn't verified, or didn't answer in time. Optional
    /// text is the provider's own (shown gray).
    case unknown(String?)
}

/// What one file's look found.
public enum FileUpload: Sendable, Equatable {
    case status(UploadStatus)
    /// the file isn't there: its version was pruned or deleted
    case gone
}

/// Looks at files in a cloud folder, off the main thread, a few seconds at most each.
public struct UploadProbe: Sendable {
    public let verified: Set<CloudProvider>
    public let timeout: TimeInterval
    let look: @Sendable (URL, CloudProvider, Set<CloudProvider>) -> FileUpload

    public init(verified: Set<CloudProvider> = CloudUpload.verifiedProviders, timeout: TimeInterval = 5,
                look: @escaping @Sendable (URL, CloudProvider, Set<CloudProvider>) -> FileUpload = UploadProbe.systemLook) {
        self.verified = verified; self.timeout = timeout; self.look = look
    }

    /// What `url` is, as far as can be told. A file provider can hang a stat while it
    /// is busy or wedged, so the look runs on its own thread; one that doesn't answer
    /// in time is "can't tell" (and left to finish on its own).
    public func file(_ url: URL, provider: CloudProvider) -> (FileUpload, timedOut: Bool) {
        final class Box: @unchecked Sendable { var value: FileUpload?; let lock = NSLock() }
        let box = Box(), done = DispatchSemaphore(value: 0)
        let look = self.look, verified = self.verified
        Thread.detachNewThread {
            let v = look(url, provider, verified)
            box.lock.withLock { box.value = v }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success, let v = box.lock.withLock({ box.value }) else {
            return (.status(.unknown("\(provider == .generic ? "The cloud folder" : provider.displayName) didn't answer in time.")), true)
        }
        return (v, false)
    }

    /// A version is uploaded only when every one of its files is: each artifact, the
    /// manifest and the file list. nil when any is gone: the version was pruned or
    /// deleted, and is dropped, never counted as uploaded.
    public static func combine(_ files: [FileUpload]) -> UploadStatus? {
        var statuses: [UploadStatus] = []
        for f in files {
            switch f {
            case .gone: return nil
            case .status(let s): statuses.append(s)
            }
        }
        guard !statuses.isEmpty else { return nil }
        if statuses.allSatisfy({ $0 == .uploaded }) { return .uploaded }
        for s in statuses { if case .failed = s { return s } }
        if statuses.contains(.uploading) { return .uploading }
        for s in statuses { if case .unknown(let text?) = s { return .unknown(text) } }
        return .unknown(nil)
    }

    /// The files a version's upload is judged on: everything in its folder but hidden
    /// files (its artifacts or their parts, its manifest, its file list). Found by
    /// listing the folder, not by reading the manifest: reading an evicted manifest
    /// would bring it back down, and the look would undo what it looks for. nil: the
    /// folder is gone.
    public static func files(inVersion dir: URL) -> [URL]? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted().map { dir.appendingPathComponent($0) }
    }

    /// what macOS says about a file, believed only as far as the allowlist goes
    public static let systemLook: @Sendable (URL, CloudProvider, Set<CloudProvider>) -> FileUpload = { url, provider, verified in
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .gone : .status(.unknown(nil))
        }
        // an evicted file: the provider holds it, or it couldn't have let it go
        if CloudFile.anyDataless(in: url) { return .status(.uploaded) }
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey,
                                         .ubiquitousItemIsUploadingKey, .ubiquitousItemUploadingErrorKey]
        let values = try? url.resourceValues(forKeys: keys)
        let error = values?.ubiquitousItemUploadingError?.localizedDescription
        guard verified.contains(provider) else { return .status(.unknown(error)) }
        if let error { return .status(.failed(error)) }
        switch values?.ubiquitousItemIsUploaded {
        case .some(true): return .status(.uploaded)
        case .some(false): return .status(.uploading)
        case .none: return .status(.unknown(nil))
        }
    }
}

// MARK: - the ledger

/// a version not yet known to be uploaded
public struct UploadEntry: Codable, Sendable, Equatable {
    /// the version's folder
    public var version: String
    /// when its run made it (its version stamp)
    public var runAt: Date
    /// what the last look found; nil: not looked at yet
    public var status: UploadStatus?

    public init(version: String, runAt: Date, status: UploadStatus? = nil) {
        self.version = version; self.runAt = runAt; self.status = status
    }

    /// a verified provider has said it isn't uploaded
    var notUploaded: Bool {
        switch status {
        case .uploading?, .failed?: return true
        default: return false
        }
    }

    /// What a new look found, over what the last one did. A look that can't tell
    /// (the provider stopped answering, which is when uploads stall) knows nothing
    /// new: a "not uploaded" it would replace stands.
    func updated(_ found: UploadStatus) -> UploadEntry {
        var e = self
        if case .unknown = found, notUploaded { return e }
        e.status = found
        return e
    }
}

/// versions folded out of the ledger when it passed its cap
public struct UploadUntracked: Codable, Sendable, Equatable {
    public var count: Int
    /// the oldest folded version's run
    public var since: Date
    /// a verified provider had said one of them wasn't uploaded: the warning stands
    public var notUploaded: Bool
    /// the newest folded version's run (nil: a record from before it was kept)
    public var until: Date? = nil
}

/// one destination's versions not yet known to be uploaded
public struct DestinationUploads: Codable, Sendable, Equatable {
    /// oldest first
    public var entries: [UploadEntry] = []
    public var untracked: UploadUntracked?
    /// the destination was last looked at whole (every version on disk); nil: never
    public var scannedAt: Date?
    /// the versions on record were last looked at
    public var checkedAt: Date?
    /// versions found uploaded since the destination was last looked at whole: with
    /// none, an empty record is "nothing to check", never "uploaded"
    public var confirmed: Int = 0
    /// those versions' folders, still on disk when last looked: a version in the
    /// cloud folder that is neither here nor among `entries` hasn't been looked at
    public var uploaded: [String] = []
    public init() {}

    enum CodingKeys: String, CodingKey { case entries, untracked, scannedAt, checkedAt, confirmed, uploaded }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.decodeIfPresent([UploadEntry].self, forKey: .entries) ?? []
        untracked = try c.decodeIfPresent(UploadUntracked.self, forKey: .untracked)
        scannedAt = try c.decodeIfPresent(Date.self, forKey: .scannedAt)
        checkedAt = try c.decodeIfPresent(Date.self, forKey: .checkedAt)
        confirmed = try c.decodeIfPresent(Int.self, forKey: .confirmed) ?? 0
        uploaded = try c.decodeIfPresent([String].self, forKey: .uploaded) ?? []
    }
}

/// What the Storage window says about a cloud destination's uploads.
public enum UploadSummary: Sendable, Equatable {
    /// nothing looked at yet
    case notChecked
    /// every version found is in the cloud
    case uploaded
    /// a verified provider says these versions aren't uploaded yet (and its error, if any)
    case uploading(count: Int, error: String?)
    /// a verified provider says these versions still aren't uploaded a day after their run
    case notOffsite(count: Int, since: Date)
    /// can't tell (gray)
    case unknown(String?)

    public static func of(_ d: DestinationUploads?, now: Date) -> UploadSummary {
        guard let d else { return .notChecked }
        let late = { (date: Date) in now.timeIntervalSince(date) >= CloudUpload.attentionAfter }
        let pending = d.entries.filter(\.notUploaded)
        var overdue = pending.filter { late($0.runAt) }.map(\.runAt)
        var overdueCount = overdue.count
        if let u = d.untracked, u.notUploaded, late(u.since) { overdue.append(u.since); overdueCount += u.count }
        if let since = overdue.min() { return .notOffsite(count: overdueCount, since: since) }
        if !pending.isEmpty || d.untracked?.notUploaded == true {
            let error = pending.lazy.compactMap { e -> String? in if case .failed(let t)? = e.status { return t }; return nil }.first
            return .uploading(count: pending.count + (d.untracked?.notUploaded == true ? d.untracked!.count : 0), error: error)
        }
        if d.untracked != nil || !d.entries.isEmpty {
            let text = d.entries.lazy.compactMap { e -> String? in if case .unknown(let t?)? = e.status { return t }; return nil }.first
            return .unknown(text)
        }
        return d.confirmed > 0 ? .uploaded : .notChecked
    }
}

/// upload-status.json: per destination, the versions not yet known to be uploaded.
public final class UploadLedger: @unchecked Sendable {
    struct File: Codable {
        /// "jobID|targetID" → its versions
        var destinations: [String: DestinationUploads] = [:]
    }

    private let file: SharedJSONFile<File>
    let cap: Int
    public var fileURL: URL { file.url }

    public static let defaultCap = 100

    public init(url: URL, cap: Int = UploadLedger.defaultCap) {
        file = SharedJSONFile(url: url, lockName: "upload-status.lock", empty: { File() })
        self.cap = cap
    }

    public static func standard() -> UploadLedger {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.cryoframe", isDirectory: true)
        return UploadLedger(url: base.appendingPathComponent("upload-status.json"))
    }

    public func destination(_ key: DestinationKey) -> DestinationUploads? {
        file.read().destinations[key.string]
    }

    /// add versions a run made (those already on record are left as they are)
    public func record(_ versions: [UploadEntry], for key: DestinationKey) {
        guard !versions.isEmpty else { return }
        file.update { f in
            var d = f.destinations[key.string] ?? DestinationUploads()
            let known = Set(d.entries.map(\.version))
            d.entries += versions.filter { !known.contains($0.version) }
            fold(&d)
            f.destinations[key.string] = d
            return (true, ())
        }
    }

    /// What a look at the versions on record found, by version folder: an uploaded
    /// or gone (nil) version leaves the ledger, the rest keep what was found (see
    /// UploadEntry.updated). `present`: every version on disk, when the look listed
    /// them; an uploaded version no longer among them is forgotten.
    public func apply(_ found: [String: UploadStatus?], present: Set<String>? = nil, for key: DestinationKey, at now: Date) {
        file.update { f in
            guard var d = f.destinations[key.string] else { return (false, ()) }
            var confirmed: [String] = []
            d.entries = d.entries.compactMap { e in
                guard let result = found[e.version] else { return e }      // added since the look began
                guard let status = result else { return nil }               // gone
                if status == .uploaded { confirmed.append(e.version); return nil }
                return e.updated(status)
            }
            d.confirmed += confirmed.count
            d.uploaded += confirmed.filter { !d.uploaded.contains($0) }
            if let present { d.uploaded = d.uploaded.filter { present.contains($0) } }
            d.checkedAt = now
            f.destinations[key.string] = d
            return (true, ())
        }
    }

    /// What a look at every version on disk found: the ones not uploaded replace the
    /// record, and the folded count is cleared, being looked at again. A version a
    /// run recorded while the look went on (not among `looked`) stays. A version the
    /// look couldn't tell about keeps a "not uploaded" it had; so does the folded
    /// count, holding the versions in its span the look couldn't tell about.
    public func replace(with unconfirmed: [UploadEntry], confirmed: [String], looked: Set<String>,
                        for key: DestinationKey, at now: Date) {
        file.update { f in
            var d = f.destinations[key.string] ?? DestinationUploads()
            let before = Dictionary(d.entries.map { ($0.version, $0) }, uniquingKeysWith: { a, _ in a })
            var unconfirmed = unconfirmed.map { e in
                guard let old = before[e.version], let status = e.status else { return e }
                return old.updated(status)
            }
            let kept = d.entries.filter { !looked.contains($0.version) }
            if let u = d.untracked, u.notUploaded {
                let inSpan = { (e: UploadEntry) -> Bool in
                    guard before[e.version] == nil, e.runAt <= (u.until ?? u.since), case .unknown? = e.status else { return false }
                    return true
                }
                if unconfirmed.contains(where: inSpan) {
                    unconfirmed.removeAll(where: inSpan)
                } else {
                    d.untracked = nil
                }
            } else {
                d.untracked = nil
            }
            let fresh = Set(unconfirmed.map(\.version))
            d.entries = (unconfirmed + kept.filter { !fresh.contains($0.version) }).sorted { $0.runAt < $1.runAt }
            d.confirmed = confirmed.count
            d.uploaded = confirmed
            d.scannedAt = now; d.checkedAt = now
            fold(&d)
            f.destinations[key.string] = d
            return (true, ())
        }
    }

    /// drop the destinations of jobs and destinations that are gone
    public func prune(keeping keys: Set<DestinationKey>) {
        let wanted = Set(keys.map(\.string))
        file.update { f in
            let before = f.destinations.count
            f.destinations = f.destinations.filter { wanted.contains($0.key) }
            return (f.destinations.count != before, ())
        }
    }

    /// Past the cap, the oldest versions are folded into a count. A warning one of
    /// them carried stays with the count until the destination is looked at whole.
    private func fold(_ d: inout DestinationUploads) {
        d.entries.sort { $0.runAt < $1.runAt }
        guard d.entries.count > cap else { return }
        let out = d.entries.prefix(d.entries.count - cap)
        d.entries.removeFirst(out.count)
        var u = d.untracked ?? UploadUntracked(count: 0, since: out.first!.runAt, notUploaded: false)
        u.count += out.count
        u.since = min(u.since, out.first!.runAt)
        u.until = max(u.until ?? u.since, out.last!.runAt)
        u.notUploaded = u.notUploaded || out.contains(where: \.notUploaded)
        d.untracked = u
    }
}

// MARK: - checking

/// Looks at a cloud destination's versions and records what it found.
public struct UploadCheck: Sendable {
    public let ledger: UploadLedger
    public let probe: UploadProbe

    public init(ledger: UploadLedger, probe: UploadProbe = UploadProbe()) { self.ledger = ledger; self.probe = probe }

    /// Look again at the versions on record, and at any version on disk there that
    /// no look has seen (one a run didn't record), so "uploaded" covers every version
    /// in the folder. A destination never looked at whole is scanned from disk
    /// instead (a cloud folder backed up before this check existed).
    public func refresh(job: BackupJob, target: Target, now: Date = Date()) -> UploadSummary {
        let key = DestinationKey(jobID: job.id, targetID: target.id)
        if let plain = Self.plainFiles(job) { return plain }
        if let away = Self.folderAway(target) { return away }
        guard let d = ledger.destination(key), d.scannedAt != nil else { return rescan(job: job, target: target, now: now) }
        let provider = target.cloudProvider ?? CloudProvider.identify(target.destinationDir)
        let versions = Self.versions(job: job, target: target)
        let seen = Set(d.entries.map(\.version) + d.uploaded)
        let foldedUntil = d.untracked.map { $0.until ?? $0.since }
        let unseen = versions.filter { v in
            guard !seen.contains(v.dir.path) else { return false }
            // a folded version is in neither list: one inside the folded span is counted there
            if let foldedUntil, let made = v.version, made <= foldedUntil { return false }
            return true
        }
        ledger.record(unseen.map { UploadEntry(version: $0.dir.path, runAt: $0.version ?? now) }, for: key)
        var stalled = false
        var found: [String: UploadStatus?] = [:]
        for e in ledger.destination(key)?.entries ?? [] {
            found.updateValue(look(URL(fileURLWithPath: e.version), provider: provider, stalled: &stalled), forKey: e.version)
        }
        ledger.apply(found, present: Set(versions.map(\.dir.path)), for: key, at: now)
        return UploadSummary.of(ledger.destination(key), now: now)
    }

    /// "Check again": look at every version of the job on disk there, and start the
    /// record over from what is found.
    public func rescan(job: BackupJob, target: Target, now: Date = Date()) -> UploadSummary {
        let key = DestinationKey(jobID: job.id, targetID: target.id)
        if let plain = Self.plainFiles(job) { return plain }
        if let away = Self.folderAway(target) { return away }
        let provider = target.cloudProvider ?? CloudProvider.identify(target.destinationDir)
        let versions = Self.versions(job: job, target: target)
        var stalled = false
        var unconfirmed: [UploadEntry] = []
        var confirmed: [String] = []
        for v in versions {
            guard let status = look(v.dir, provider: provider, stalled: &stalled) else { continue }    // gone
            if status == .uploaded { confirmed.append(v.dir.path); continue }
            unconfirmed.append(UploadEntry(version: v.dir.path, runAt: v.version ?? now, status: status))
        }
        let looked = Set(versions.map(\.dir.path))
        ledger.replace(with: unconfirmed, confirmed: confirmed, looked: looked, for: key, at: now)
        // what the record holds that the scan didn't find (a run's, recorded since it
        // began, or a folder the job no longer reads): looked at on its own, so one
        // that is gone doesn't stay
        var found: [String: UploadStatus?] = [:]
        for e in ledger.destination(key)?.entries ?? [] where !looked.contains(e.version) {
            found.updateValue(look(URL(fileURLWithPath: e.version), provider: provider, stalled: &stalled), forKey: e.version)
        }
        if !found.isEmpty { ledger.apply(found, for: key, at: now) }
        return UploadSummary.of(ledger.destination(key), now: now)
    }

    /// The job's versions on disk there, found without reading an evicted manifest
    /// (that would download it, and undo what the look looks for).
    static func versions(job: BackupJob, target: Target) -> [RestorableArchive] {
        job.libraries.flatMap { LibraryFolders.archives(job: job, library: $0, in: target.destinationDir, downloading: false) }
            .filter { $0.version != nil }
    }

    /// Plain files (see PlainCopy) are many files, each uploaded on its own, with no
    /// version to follow: never recorded, and said to be unknown.
    static func plainFiles(_ job: BackupJob) -> UploadSummary? {
        job.format.isPlainFiles ? .unknown("Plain files are uploaded one by one, so whether all of them are uploaded can't be told here.") : nil
    }

    /// A cloud folder that isn't there (the provider signed out or removed, the folder
    /// moved) makes every version look gone. That proves nothing about the cloud, so
    /// nothing is looked at and the record is left as it is.
    static func folderAway(_ target: Target) -> UploadSummary? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.destinationDir.path, isDirectory: &isDir), isDir.boolValue else {
            return .unknown("The cloud folder isn't on this Mac right now.")
        }
        return nil
    }

    /// One version's state. After one file goes unanswered, the provider is taken to
    /// be stuck and the rest of this look is "can't tell" without asking. nil: gone.
    /// A folder without its manifest isn't a whole version (being written, or being
    /// deleted): "can't tell".
    private func look(_ dir: URL, provider: CloudProvider, stalled: inout Bool) -> UploadStatus? {
        guard let urls = UploadProbe.files(inVersion: dir) else { return nil }
        guard urls.contains(where: { $0.lastPathComponent == ArchiveManifest.sidecarName }) else { return .unknown(nil) }
        var files: [FileUpload] = []
        for url in urls {
            if stalled { files.append(.status(.unknown(nil))); continue }
            let (f, timedOut) = probe.file(url, provider: provider)
            if timedOut { stalled = true }
            files.append(f)
        }
        return UploadProbe.combine(files)
    }
}
