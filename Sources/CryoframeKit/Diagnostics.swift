//
//  Diagnostics.swift
//  CryoframeKit
//
//  "Report a problem": a plain-text report to attach to a GitHub issue, with what a
//  fix needs (versions, how the jobs are set up, what the recent runs and checks
//  said) and nothing about what is being backed up.
//
//  The report is public once it is attached, so it is built to hold no file name
//  from a library, no path inside the home folder, no volume, job or folder name
//  the user chose, no user or Mac name, and no passphrase, key, token or alert URL.
//  Jobs, custom libraries and destinations are numbered instead ("job 1", "folder
//  1", "destination 2 (external drive)"); the built-in library names (Photos, Mail)
//  are the same on every Mac and stay. Error text passes through the Redactor, which
//  knows every name above and recognizes paths, URLs and file names. It is a
//  heuristic, so the app shows the report for reading before it is saved, and
//  nothing is ever sent from here.
//

import Foundation

/// Takes what could identify the user, or what they back up, out of free text.
public struct Redactor: Sendable {
    /// exact strings and what they become, longest first
    let replacements: [(String, String)]
    let userWords: [String]

    /// - Parameters:
    ///   - names: known names (jobs, custom libraries, destinations, folders) and
    ///     their stand-ins
    ///   - userWords: the user's account and full name, and this Mac's name
    public init(names: [(String, String)], userWords: [String]) {
        replacements = names.filter { !$0.0.isEmpty }.sorted { $0.0.count > $1.0.count }
        self.userWords = userWords.filter { $0.count >= 2 }.sorted { $0.count > $1.count }
    }

    /// words of our own that hold a slash or look like a file name, left alone
    static let ownWords: Set<String> = ["ntfy/webhook", "and/or", "read/write", "on/off", "cryoframe-manifest.json",
                                        "Info.plist", "e.g.", "i.e.", "etc."]

    public func redact(_ text: String) -> String {
        var s = text
        // 1. URLs: an alert topic or a webhook's token lives in the path or query
        s = Self.replace(#"[A-Za-z][A-Za-z0-9+.\-]*://[^\s"'<>)\]]+"#, in: s) { _ in "[url]" }
        // 2. email addresses
        s = Self.replace(#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, in: s) { _ in "[email]" }
        // 3. paths under the home folder, on other drives, in temporary folders. A path
        //    can hold spaces, so it runs to the next piece of punctuation that ends one.
        //    (A name can hold an apostrophe: "Jane's T7".) The space before what ends
        //    it stays.
        let end = #"(?:[^\n"()\[\],;]|: (?=\S*/))*?(?=$|[\n"()\[\],;]|: | — | - )"#
        func path(_ standIn: String) -> (String) -> String {
            { found in standIn + String(found.reversed().prefix(while: \.isWhitespace).reversed()) }
        }
        s = Self.replace(#"/Users/[^/\s"]+"# + "(?:/" + end + ")?", in: s, with: path("~/[path]"))
        s = Self.replace(#"/Volumes/[^/\n"]+"# + "(?:/" + end + ")?", in: s, with: path("/Volumes/[drive]/[path]"))
        s = Self.replace(#"(?:/private)?/(?:var/folders|tmp)/"# + end, in: s, with: path("[temp]/[path]"))
        s = Self.replace(#"~/"# + #"(?!\[path\])"# + end, in: s, with: path("~/[path]"))
        // 4. every name the user chose
        for (name, standIn) in replacements { s = s.replacingOccurrences(of: name, with: standIn) }
        // 5. the user's own names and this Mac's, as whole words
        for word in userWords {
            s = Self.replace("(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: word) + "(?![A-Za-z0-9])", in: s) { _ in "[user]" }
        }
        // 6. paths inside a library ("Saved/report.pdf"), and file names
        s = Self.replace(#"(?<![\w/\[])[^\s/"'(),;:\[\]]+(?:/[^\s/"'(),;:\[\]]+)+/?"#, in: s) {
            Self.ownWords.contains($0) ? $0 : "[path]"
        }
        s = Self.replace(#"(?<![\w.\[/])[^\s/"'(),;:\[\]…]*[A-Za-z0-9_\-][.][A-Za-z][A-Za-z0-9]{0,11}(?![\w.])"#, in: s) {
            Self.ownWords.contains($0) ? $0 : "[file]"
        }
        return s
    }

    static func replace(_ pattern: String, in text: String, with make: (String) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var out = "", last = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += make(ns.substring(with: m.range))
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }
}

public enum DiagnosticsReport {
    /// what goes into a report, gathered by the app
    public struct Input: Sendable {
        public var appVersion: String
        public var helperVersion: String?          // nil: not installed or not answering
        public var agentState: String              // "on", "off", "needs approval"
        public var macOS: String
        public var hardware: String
        public var jobs: [BackupJob]
        public var runs: [RunRecord]               // any order
        public var health: [HealthRecord]          // any order
        /// settings that hold nothing private, as label and value (never an alert URL)
        public var settings: [(String, String)]
        public var now: Date

        public init(appVersion: String, helperVersion: String?, agentState: String, macOS: String, hardware: String,
                    jobs: [BackupJob], runs: [RunRecord], health: [HealthRecord], settings: [(String, String)], now: Date) {
            self.appVersion = appVersion; self.helperVersion = helperVersion; self.agentState = agentState
            self.macOS = macOS; self.hardware = hardware; self.jobs = jobs; self.runs = runs; self.health = health
            self.settings = settings; self.now = now
        }
    }

    public static let issuesURL = URL(string: "https://github.com/breed007/Cryoframe/issues/new")!
    static let runsShown = 30, checksShown = 20

    /// The stand-ins for everything the user named: jobs, custom libraries and
    /// destinations (by kind), including the folders they point at. Jobs gone from
    /// the list but still in the history are numbered too.
    public static func redactor(for input: Input, home: String = NSHomeDirectory(), userName: String = NSUserName(),
                                fullName: String = NSFullUserName(), hostName: String = Host.current().localizedName ?? "") -> Redactor {
        var names: [(String, String)] = []
        var jobNumber = 0, folderNumber = 0, destNumber = 0
        var seenJobs = Set<String>(), seenFolders = Set<String>(), seenDests = Set<String>()
        func job(_ name: String) {
            guard seenJobs.insert(name).inserted else { return }
            jobNumber += 1; names.append((name, "job \(jobNumber)"))
        }
        for j in input.jobs {
            job(j.name)
            for lib in j.libraries where !isBuiltIn(lib) && seenFolders.insert(lib.displayName).inserted {
                folderNumber += 1; names.append((lib.displayName, "folder \(folderNumber)"))
            }
            for t in j.targets where seenDests.insert(t.displayName).inserted {
                destNumber += 1; names.append((t.displayName, "destination \(destNumber) (\(kindName(t)))"))
            }
        }
        for r in input.runs { job(r.jobName) }
        for h in input.health { job(h.jobName) }
        // destinations only the history still names (a job since deleted)
        for r in input.runs {
            for l in r.libraries where !l.destination.isEmpty && seenDests.insert(l.destination).inserted {
                destNumber += 1; names.append((l.destination, "destination \(destNumber)"))
            }
        }
        // a folder from history no job holds any more: its name isn't known, but its
        // runs' library names are
        let builtInNames = Set(ContentTypeRegistry.builtIns.map(\.displayName))
        for r in input.runs {
            for l in r.libraries where !builtInNames.contains(l.library) && seenFolders.insert(l.library).inserted {
                folderNumber += 1; names.append((l.library, "folder \(folderNumber)"))
            }
        }
        return Redactor(names: names, userWords: [userName, fullName, hostName] + fullName.split(separator: " ").map(String.init))
    }

    static func isBuiltIn(_ lib: ContentType) -> Bool {
        ContentTypeRegistry.builtIns.contains { $0.id == lib.id && $0.displayName == lib.displayName }
    }

    static func kindName(_ t: Target) -> String {
        switch t.kind {
        case .local: return t.destinationDir.path.hasPrefix("/Volumes/") ? "external drive" : "folder on this Mac"
        case .networkShare: return "network share"
        case .cloudSync: return t.cloudProvider.map { "cloud folder, \($0.displayName)" } ?? "cloud folder"
        }
    }

    static func formatName(_ f: FormatChoice) -> String {
        switch f {
        case .sealedDMG: return "sealed disk image"
        case .sealedZip: return "sealed zip"
        case .liveMirror: return "live mirror"
        }
    }

    static func scheduleName(_ f: BackupFrequency) -> String {
        switch f {
        case .manual: return "manual"
        case .oneTime: return "one time"
        case .everyHours(let h): return "every \(h) hour\(h == 1 ? "" : "s")"
        case .daily(let h, let m): return String(format: "daily at %02d:%02d", h, m)
        }
    }

    static func retentionName(_ r: RetentionPolicy) -> String {
        switch r {
        case .keepAll: return "keep all"
        case .keepLast(let n): return "keep last \(n)"
        case .gfs(let d, let w, let m): return "\(d) daily, \(w) weekly, \(m) monthly"
        }
    }

    /// The report, redacted with `redactor` (see `redactor(for:)`).
    public static func build(_ input: Input, redactor: Redactor) -> String {
        let iso = ISO8601DateFormatter()
        func when(_ d: Date) -> String { iso.string(from: d) }
        func r(_ s: String) -> String { redactor.redact(s) }
        func duration(_ t: TimeInterval) -> String { t < 90 ? "\(Int(t)) s" : "\(Int((t / 60).rounded())) min" }
        var out: [String] = []
        func add(_ line: String) { out.append(line) }

        add("Cryoframe diagnostics")
        add("Made \(when(input.now)). Names of jobs, folders and destinations are replaced by numbers; paths and file names are removed.")
        add("")
        add("App: \(input.appVersion)")
        add("Helper: \(input.helperVersion ?? "not installed or not answering")")
        add("Scheduled agent: \(input.agentState)")
        add("macOS: \(input.macOS)")
        add("Hardware: \(input.hardware)")
        for (label, value) in input.settings { add("\(label): \(r(value))") }
        add("")

        let latest = Dictionary(input.runs.sorted { $0.finishedAt < $1.finishedAt }.map { ($0.jobID, $0) }, uniquingKeysWith: { _, b in b })
        var lastGood: [String: Date] = [:]
        for run in input.runs where run.outcome.isGood { lastGood[run.jobID] = max(lastGood[run.jobID] ?? .distantPast, run.finishedAt) }
        add("JOBS (\(input.jobs.count))")
        for j in input.jobs {
            let libs = j.libraries.map { isBuiltIn($0) ? $0.displayName : r($0.displayName) }.joined(separator: ", ")
            let dests = j.targets.map { r($0.displayName) }.joined(separator: ", ")
            add("- \(r(j.name)): \(formatName(j.format))\(j.encrypted ? ", encrypted" : ""); \(scheduleName(j.frequency))\(j.enabled ? "" : " (paused)")")
            add("  libraries: \(libs)")
            add("  destinations: \(dests)")
            add("  verification: \(j.verification.rawValue); retention: \(retentionName(j.retention)); when an app is open: \(j.runPolicy.rawValue)")
            let standing = ProtectionVerdict.standing(of: j, latest: latest[j.id], lastGood: lastGood[j.id], health: nil, now: input.now)
            add("  status: \(r(standing.reason(now: input.now)))")
        }
        add("")

        let runs = input.runs.sorted { $0.finishedAt > $1.finishedAt }.prefix(runsShown)
        add("RECENT RUNS (newest first, \(runs.count) of \(input.runs.count))")
        for run in runs {
            let deferrals = run.deferrals.map { $0 > 1 ? " ×\($0)" : "" } ?? ""
            add("- \(when(run.finishedAt)) \(r(run.jobName)) [\(run.trigger)] \(run.outcome.rawValue)\(deferrals), took \(duration(run.duration)): \(r(run.summary))")
            for l in run.libraries {
                let lib = r(l.library), dest = l.destination.isEmpty ? "" : " to \(r(l.destination))"
                add("    \(lib)\(dest): \(l.status)\(l.error.map { ": " + r($0) } ?? "")")
            }
            if let w = run.warning { add("    warning: \(r(w))") }
        }
        add("")

        let checks = input.health.sorted { $0.checkedAt > $1.checkedAt }.prefix(checksShown)
        add("RECENT CHECKS (newest first, \(checks.count) of \(input.health.count))")
        for h in checks {
            add("- \(when(h.checkedAt)) \(r(h.jobName)) [\(h.trigger)] \(h.kind): \(h.passed ? "passed" : "FAILED"), \(h.archivesChecked) checked, \(h.skipped) skipped")
            for f in h.failures { add("    \(r(f))") }
        }
        return out.joined(separator: "\n") + "\n"
    }
}
