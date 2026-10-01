//
//  ContentsSearch.swift
//  CryoframeKit
//
//  "Which version holds this file?": a name or path searched for in each version's
//  file list (see ContentsListing), newest first. Names are compared as people see
//  them: both sides in one Unicode form (NFC) and case-folded, so "café" typed on
//  this Mac finds "café" written decomposed by another app or file system.
//
//  A version whose list is missing, changed, cut short or locked is said to have
//  no list, with "Look inside…" to open it. Only a whole list that checks out may
//  say a file isn't in its version, and the summary never says "not found" while
//  a version that could hold it went unread.
//

import Foundation
import CryptoKit

/// what to look for
public struct ContentsQuery: Sendable, Equatable {
    public let text: String
    /// the query as compared: NFC, case-folded, UTF-8
    let folded: [UInt8]
    /// a query with a "/" in it is looked for in whole paths; otherwise in names
    public let matchesPaths: Bool

    /// nil for a query of nothing but spaces
    public init?(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        self.text = t
        folded = Array(Self.fold(t).utf8)
        matchesPaths = t.contains("/")
    }

    /// one form for comparing: canonical composition, then case folding, then
    /// composition again (folding can leave a sequence that composes)
    static func fold(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
            .precomposedStringWithCanonicalMapping
    }

    /// whether `entry` matches. An ASCII name (most of them) is compared where it
    /// is, ignoring case; any other is folded first.
    public func matches(_ entry: ContentsEntry) -> Bool {
        var path = entry.path
        let ascii: Bool? = path.withUTF8 { all in
            var from = 0
            if !matchesPaths, let slash = all.lastIndex(of: 0x2F) { from = slash + 1 }
            let hay = UnsafeBufferPointer(rebasing: all[from...])
            guard !hay.contains(where: { $0 >= 0x80 }) else { return nil }
            return Self.containsIgnoringASCIICase(hay, folded)
        }
        if let ascii { return ascii }
        return Self.contains(Array(Self.fold(matchesPaths ? entry.path : entry.name).utf8), folded)
    }

    static func containsIgnoringASCIICase(_ hay: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
        guard needle.count <= hay.count else { return false }
        if needle.isEmpty { return true }
        var start = 0
        while start + needle.count <= hay.count {
            var k = 0
            while k < needle.count {
                var c = hay[start + k]
                if c >= 0x41 && c <= 0x5A { c += 0x20 }
                if c != needle[k] { break }
                k += 1
            }
            if k == needle.count { return true }
            start += 1
        }
        return false
    }

    static func contains(_ hay: [UInt8], _ needle: [UInt8]) -> Bool {
        guard needle.count <= hay.count else { return false }
        if needle.isEmpty { return true }
        return hay.withUnsafeBytes { h in
            needle.withUnsafeBytes { n in memmem(h.baseAddress, h.count, n.baseAddress, n.count) != nil }
        }
    }
}

/// one version's answer
public struct VersionSearchResult: Sendable, Identifiable {
    public var id: String { archive.id }
    public let archive: RestorableArchive
    public enum Answer: Sendable, Equatable {
        /// its whole list, read: what matched (at most the search's limit), and
        /// whether more did
        case listed(hits: [ContentsEntry], more: Bool, partial: Bool)
        case noList(ContentsListing.Unavailable)
    }
    public let answer: Answer

    /// read, whole, and nothing matched: the only answer that says it isn't there
    public var isNotInVersion: Bool {
        if case .listed(let hits, _, false) = answer { return hits.isEmpty }
        return false
    }

    public var hits: [ContentsEntry] {
        if case .listed(let hits, _, _) = answer { return hits }
        return []
    }

    /// what the row says
    public var summary: String {
        switch answer {
        case .listed(let hits, let more, let partial):
            if hits.isEmpty {
                return partial ? "No match in its file list, but the list is incomplete (no complete list), so it may still be in this version"
                               : "Not in this version"
            }
            let n = more ? "More than \(hits.count) matches" : "\(hits.count) match\(hits.count == 1 ? "" : "es")"
            return partial ? "\(n); this version's file list is incomplete, so there may be more" : n
        case .noList(let why):
            return "No file list for this version: \(why.reason)"
        }
    }
}

public struct ContentsSearch: Sendable {
    let keyring: ContentsKeyring
    let cloud: CloudDownload
    /// matches kept per version
    let hitLimit: Int
    /// how long a list's download may make no progress
    let quietLimit: TimeInterval

    public init(keyring: ContentsKeyring = ContentsKeyring(), cloud: CloudDownload = .system, hitLimit: Int = 200,
                quietLimit: TimeInterval = 60) {
        self.keyring = keyring; self.cloud = cloud; self.hitLimit = hitLimit; self.quietLimit = quietLimit
    }

    /// the versions a search goes through, newest first: each sealed version, and
    /// each mirror (which has no list, and is looked into instead)
    public static func versions(_ archives: [RestorableArchive]) -> [RestorableArchive] {
        archives.sorted { ($0.version ?? .distantFuture) > ($1.version ?? .distantFuture) }
    }

    /// Look for `query` in one version's list. `passphrases`: what to try on an
    /// encrypted list, for the job its header names (a passphrase saved on this Mac
    /// for that job, one typed in). nil when stopped part-way.
    public func search(_ query: ContentsQuery, in archive: RestorableArchive,
                       passphrases: (String) -> [String], control: RunControl? = nil) -> VersionSearchResult? {
        // a list in a cloud folder comes down first, watched, and Stop ends the wait
        if let d = archive.contents, ContentsListing.names.contains(d.name), archive.format != .liveMirror {
            let url = archive.dir.appendingPathComponent(d.name)
            do {
                try cloud.bringDown([url], quietLimit: quietLimit, control: control)
            } catch is CancelledError {
                return nil
            } catch {
                return VersionSearchResult(archive: archive, answer: .noList(.notDownloaded(Self.short(error))))
            }
        }
        var hits: [ContentsEntry] = []
        var more = false
        let keyring = self.keyring, limit = hitLimit
        let outcome = ContentsListing.read(archive, master: { job in
            passphrases(job).filter { !$0.isEmpty }.compactMap { keyring.master(jobID: job, passphrase: $0) }
        }, control: control) { entry in
            guard query.matches(entry) else { return }
            if hits.count < limit { hits.append(entry) } else { more = true }
        }
        switch outcome {
        case .stopped: return nil
        case .unavailable(let why): return VersionSearchResult(archive: archive, answer: .noList(why))
        case .read(_, let partial): return VersionSearchResult(archive: archive, answer: .listed(hits: hits, more: more, partial: partial))
        }
    }

    static func short(_ error: Error) -> String {
        if error is CloudDownloadStalled { return "the download made no progress" }
        if error is CloudDownloadIncomplete { return "it isn't on this Mac and didn't download" }
        return error.localizedDescription
    }

    /// What a finished (or stopped) search says over its results. "Not found" only
    /// for versions whose whole list was read; any version that could still hold it
    /// is counted and pointed at.
    public static func summary(_ results: [VersionSearchResult], of total: Int, stopped: Bool = false) -> String {
        let found = results.filter { !$0.hits.isEmpty }.count
        let clear = results.filter(\.isNotInVersion).count
        let unknown = results.count - found - clear
        let unread = total - results.count
        func versions(_ n: Int) -> String { "\(n) version\(n == 1 ? "" : "s")" }
        var parts: [String] = []
        if found > 0 {
            parts.append("Found in \(versions(found)).")
        } else if clear > 0, unknown == 0, unread == 0 {
            parts.append(clear == 1 ? "Not in the one version searched." : "Not in any of the \(clear) versions.")
        } else if clear > 0 {
            parts.append("Not in the \(versions(clear)) with a complete file list.")
        }
        if unknown > 0 {
            parts.append("\(versions(unknown).prefix(1).uppercased() + versions(unknown).dropFirst()) couldn't be fully searched by \(unknown == 1 ? "its" : "their") file list, so \(unknown == 1 ? "it" : "they") may still hold it: use Look inside… to check.")
        }
        if unread > 0 {
            parts.append(stopped ? "Stopped before \(versions(unread)) were searched." : "\(versions(unread)) not searched yet.")
        }
        if parts.isEmpty { return total == 0 ? "No versions here to search." : "Nothing searched." }
        return parts.joined(separator: " ")
    }
}

/// Where a library is inside an opened archive (see ArchiveReader), the same way a
/// restore finds it: a sealed disk image holds a package as one item at its top and
/// spreads a plain folder over its top; a zip and a mirror hold the library one
/// level down.
public enum ArchiveLayout {
    public static func libraryRoot(in opened: URL, for archive: RestorableArchive) -> URL {
        let named = opened.appendingPathComponent(archive.bundleName)
        switch archive.format {
        case .sealedDMG:
            return (try? named.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true ? named : opened
        case .sealedZip, .liveMirror:
            return named
        }
    }

    /// the item a list's `path` names, in an opened archive
    public static func item(_ path: String, in opened: URL, for archive: RestorableArchive) -> URL {
        libraryRoot(in: opened, for: archive).appendingPathComponent(path)
    }

    /// For the file browser opened at a match: the folders from `root` down to the
    /// one holding `item`, each built on `root` as the browser goes into them, and the
    /// item's name in the last. By name, not path: a folder's listing names its items
    /// by their real path ("/private/var/…" for "/var/…"), never the one built here.
    /// nil when `item` isn't under `root`. Packages are gone into too: a match can be
    /// inside one.
    public static func opening(at item: URL, under root: URL) -> (folders: [URL], name: String)? {
        let top = root.standardizedFileURL.pathComponents, parts = item.standardizedFileURL.pathComponents
        guard parts.count > top.count, Array(parts.prefix(top.count)) == top else { return nil }
        var folders: [URL] = [], at = root
        for name in parts.dropFirst(top.count).dropLast() {
            at = at.appendingPathComponent(name, isDirectory: true)
            folders.append(at)
        }
        return (folders, parts[parts.count - 1])
    }
}
