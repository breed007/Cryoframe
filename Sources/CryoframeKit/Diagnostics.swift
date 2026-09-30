//
//  Diagnostics.swift
//  CryoframeKit
//
//  "Report a problem": a plain-text report to attach to a GitHub issue, with what a
//  fix needs (versions, how the jobs are set up, what the recent runs and checks
//  said) and nothing about what is being backed up.
//
//  The report is public once it is attached, so it is built to hold no file name
//  from a library, no path, no volume, job or folder name the user chose, no user
//  or Mac name, and no passphrase, key, token or alert URL. Jobs, custom libraries
//  and destinations are numbered instead ("job 1", "folder 1", "destination 2
//  (external drive)"); the built-in library names (Photos, Mail) are the same on
//  every Mac and stay.
//
//  Free text (a run's error, a check's failure) is treated as untrusted. Matching
//  what might be private can't be made complete: Mac file names are words with
//  spaces between them, and a pattern can't tell "Board Minutes" from the message
//  around it. So the Redactor works the other way round. After taking out what it
//  recognizes (URLs, addresses, ids, paths, the names above), it keeps a word only
//  if Cryoframe itself uses it in its messages (DiagnosticsVocabulary, generated
//  from the source) or macOS does in its error messages, and numbers. Everything
//  else becomes "[…]". A file name made only of such words keeps them, and
//  says nothing about the file; what the report says a fix needs survives.
//
//  The app shows the report for reading before it is saved, and nothing is ever
//  sent from here.
//

import Foundation

/// Takes what could identify the user, or what they back up, out of free text.
public struct Redactor: Sendable {
    /// exact strings and what they become, longest first
    let replacements: [(String, String)]
    let userWords: [String]
    /// every word a stand-in above is made of
    let standInWords: Set<String>

    /// - Parameters:
    ///   - names: known names (jobs, custom libraries, destinations, folders) and
    ///     their stand-ins
    ///   - userWords: the user's account and full name, and this Mac's name
    public init(names: [(String, String)], userWords: [String]) {
        replacements = names.filter { !$0.0.isEmpty }.sorted { $0.0.count > $1.0.count }
        self.userWords = userWords.filter { $0.count >= 2 }.sorted { $0.count > $1.count }
        standInWords = Set(names.flatMap { Self.words(in: $0.1) })
    }

    /// what stands in for what was taken out
    static let placeholders: Set<String> = ["[path]", "[url]", "[email]", "[user]", "[drive]", "[temp]", "[id]", "[address]", "[…]"]

    /// words macOS itself writes in its error messages (strerror), and the tools and
    /// phrases the command-line tools Cryoframe runs put in theirs
    static let systemWords: Set<String> = {
        var out: Set<String> = []
        for code in 1..<120 { out.formUnion(words(in: String(cString: strerror(Int32(code))))) }
        out.formUnion(words(in: """
            hdiutil rsync openrsync ditto tmutil diskutil copyfile setxattr fsck_apfs mount_apfs cp split zipinfo
            attach detach create convert compact resize verify failed error errors warning sender receiver opendir
            open read write mkstempsock authentication resource busy temporarily unavailable invalid argument stat
            lstat rename unlink mkdir chmod chown the disk image volume device file files folder
            job folder destination external drive network share cloud this mac ntfy webhook
            bytes kb mb gb tb kib mib gib tib zero
            some were not transferred see previous code exit status signal killed terminated stopped timed out
            sigterm sigkill sigint sighup sigstop sigcont sigpipe sigsegv sigbus sigabrt checksum mismatch
            encrypted encryption passphrase keychain partition scheme apfs hfs exfat smb afp nfs
            jan feb mar apr may jun jul aug sep oct nov dec am pm
            """))
        return out.filter(isVocabularyWord)
    }()

    /// A word the vocabulary may hold: not a single letter other than "a". Every
    /// letter was in it (from "%d" and "\n" in the source), and a name split into
    /// pieces around its accents or another script ("Noël": "no", "l") was kept
    /// piece by piece.
    static func isVocabularyWord(_ word: String) -> Bool {
        word.count > 1 || word == "a"
    }

    /// the few words with a dot in them Cryoframe writes
    static let dottedWords: Set<String> = ["e.g", "i.e", "cryoframe-manifest.json", "info.plist"]

    /// tool words with digits in them (a word mixing letters and digits is otherwise
    /// taken for an id or a name)
    static let toolTokens: Set<String> = ["sha256", "sha-256", "sha1", "aes-128", "aes-256", "aes128", "aes256",
                                          "arm64", "x86_64", "utf-8", "utf8", "ipv4", "ipv6", "fat32", "udzo", "ulfo", "ulmo", "udbz"]

    /// the words of `text` as the vocabulary holds them: runs of ASCII letters and
    /// apostrophes starting with a letter, lowercased (scripts/diagnostics-vocabulary.py
    /// splits the same way)
    static func words(in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "[A-Za-z][A-Za-z'\u{2019}]*") else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range).lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        }
    }

    public func redact(_ text: String) -> String {
        var s = text
        // 1. URLs (an alert topic or a webhook's token lives in the path or query),
        //    email addresses, ids, network addresses
        s = Self.replace(#"[A-Za-z][A-Za-z0-9+.\-]*://[^\s"'<>)\]]+"#, in: s) { _ in "[url]" }
        s = Self.replace(#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, in: s) { _ in "[email]" }
        s = Self.replace(#"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#, in: s) { _ in "[id]" }
        s = Self.replace(#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, in: s) { _ in "[address]" }
        s = Self.replace(#"(?i)(?<![\w:])[0-9a-f]{0,4}(?::[0-9a-f]{0,4}){2,7}(?![\w:])"#, in: s) {
            // a time of day ("14:13:20") has neither hex letters nor "::"
            $0.range(of: "[a-fA-F]|::", options: .regularExpression) == nil ? $0 : "[address]"
        }
        // 2. paths. A path can hold spaces (and an apostrophe: "Jane's T7"), so it runs
        //    to the next piece of punctuation that ends one; the space before that
        //    stays. The command-line tools keep their paths (/usr/bin/hdiutil): they
        //    say which one failed, and hold nothing of the user's.
        let end = #"(?:[^\n"“”()\[\],;]|: (?=\S*/))*?(?=$|[\n"“”()\[\],;]|: | — | - )"#
        func path(_ standIn: String) -> (String) -> String {
            { found in standIn + String(found.reversed().prefix(while: \.isWhitespace).reversed()) }
        }
        s = Self.replace(#"/Users/[^/\s"]+"# + "(?:/" + end + ")?", in: s, with: path("~/[path]"))
        s = Self.replace(#"/Volumes/[^/\n"]+"# + "(?:/" + end + ")?", in: s, with: path("/Volumes/[drive]/[path]"))
        s = Self.replace(#"(?:/private)?/(?:var|tmp)/"# + end, in: s, with: path("[temp]/[path]"))
        s = Self.replace(#"~/"# + #"(?!\[path\])"# + end, in: s, with: path("~/[path]"))
        s = Self.replace(#"(?<![\w/\]~])/(?!(?:usr|bin|sbin|System)/|Volumes/\[drive\])(?=[^\s/])"# + end, in: s, with: path("[path]"))
        // 3. every name the user chose, and the user's own names and this Mac's
        for (name, standIn) in replacements { s = s.replacingOccurrences(of: name, with: standIn) }
        for word in userWords {
            s = Self.replace("(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: word) + "(?![A-Za-z0-9])", in: s) { _ in "[user]" }
        }
        // 4. paths inside a library ("Saved/report.pdf")
        s = Self.replace(#"(?<![\w/\[~])[^\s/"'“”(),;:\[\]]+(?:/[^\s/"'“”(),;:\[\]]+)+/?"#, in: s) {
            $0.hasPrefix("/") || ["and/or", "ntfy/webhook", "files/attrs"].contains($0) ? $0 : "[path]"
        }
        // 5. numbers: see keepsNumber
        s = Self.replace(Self.numberRun, in: s) { Self.keepsNumber($0) ? $0 : "[…]" }
        // 6. then only words Cryoframe or macOS write, and numbers, are kept
        return keepingKnownWords(s)
    }

    /// A number with whatever follows it that makes it one number: groups of digits
    /// joined by a space, dash, slash, dot or comma ("4111 1111 1111 1111",
    /// "(404) 555-1234"), and a unit. A date, with its time, comes first as a whole.
    static let numberRun = #"[0-9]{4}-[0-9]{2}-[0-9]{2}(?:[ T][0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?)?|(?<![\p{L}\p{N}_.,:])\(?[0-9]+(?:\)?[ \-/.,]\(?[0-9]+)*\)?"#
        + #"(?:\s?(?i:%|[kmgt]i?b|bytes?|b|files?|items?|parts?|blocks?|folders?|versions?|times|ms|s|sec|seconds?|min|minutes?|h|hours?|days?|weeks?)(?![\p{L}\p{N}]))?"#

    /// Whether a number is kept. The ones a fix needs are short, or carry a unit:
    /// sizes, counts, durations, error and status codes, versions, dates and times.
    /// A long run of digits, or digits in groups, is how a social security, phone or
    /// card number is written, and a file named by one names who it is about.
    static func keepsNumber(_ text: String) -> Bool {
        if text.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}(?:[ T][0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?)?$"#, options: .regularExpression) != nil { return true }
        // the number, without a unit after it
        guard let m = text.range(of: #"^\(?[0-9][0-9 ()\-/.,]*"#, options: .regularExpression) else { return false }
        let number = text[m].trimmingCharacters(in: CharacterSet(charactersIn: " ()"))
        let hasUnit = !text[m.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty
        let digits = number.filter { ("0"..."9").contains($0) }.count
        if !number.contains(where: { !("0"..."9").contains($0) }) { return digits <= 6 || hasUnit }   // 72000, 1234567 bytes
        if number.range(of: #"^[0-9]+(?:\.[0-9]+)+$"#, options: .regularExpression) != nil { return digits <= 8 }    // 1.6.0, 3.5, 26.7
        if number.range(of: #"^[0-9]{1,3}(?:,[0-9]{3})+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil {         // 72,000
            return digits <= 6 || hasUnit
        }
        return digits <= 6                                                                                    // 3/5, 12-34
    }

    /// every word that isn't Cryoframe's own, macOS's, a stand-in's, or a number,
    /// replaced by "[…]", and a run of those by one
    func keepingKnownWords(_ text: String) -> String {
        let token = #"\[[^\[\]\s]+\](?:['’]s\b)?|/(?:usr|bin|sbin|System)/[^\s"'“”(),;:]+|[\p{L}\p{N}][\p{L}\p{N}'’_.\-]*"#
        var out = Self.replace(token, in: text) { t in
            if t.hasPrefix("/") { return t }
            if t.hasPrefix("[") {       // a stand-in, possibly with its possessive ("[user]'s")
                let bare = t.hasSuffix("s") && !t.hasSuffix("]") ? String(t.dropLast(2)) : t
                return Self.placeholders.contains(bare) ? t : "[…]"
            }
            return isKnown(t) ? t : "[…]"
        }
        out = Self.replace(#"\[…\](?:[\s,.;:'’\-]*\[…\])+"#, in: out) { _ in "[…]" }
        return out
    }

    func isKnown(_ token: String) -> Bool {
        var t = token
        while let last = t.last, ".'’-_".contains(last) { t.removeLast() }
        if t.isEmpty { return true }
        // numbers, sizes, dates and times, counts (see keepsNumber), a unit joined on
        if let n = t.range(of: #"^[0-9][0-9.,\-]*"#, options: .regularExpression),
           t[n.upperBound...].range(of: #"^(?:%|[KMGT]i?B|[KMGT]|s|ms|h|x)?$"#, options: .regularExpression) != nil {
            return Self.keepsNumber(String(t[n]) + (n.upperBound < t.endIndex ? " B" : ""))
        }
        if Self.toolTokens.contains(t.lowercased()) { return true }
        // A letter outside ASCII: a name with an accent or in another script. The
        // words are looked up by their ASCII letters only, so its pieces could be
        // Cryoframe's words ("Noël": "no", "l") while the name as a whole is someone's.
        // Cryoframe's own messages are in plain English.
        if t.unicodeScalars.contains(where: { !$0.isASCII && CharacterSet.letters.contains($0) }) { return false }
        // a dot inside a word makes a file name ("Notes.pipe"), whatever its words
        if t.contains(".") { return Self.dottedWords.contains(t.lowercased()) }
        let parts = Self.words(in: t)
        guard !parts.isEmpty else { return false }        // digits mixed with other characters: an id, a name
        guard t.range(of: #"\d"#, options: .regularExpression) == nil else { return false }
        return parts.allSatisfy {
            Self.isVocabularyWord($0) && (Self.productWords.contains($0) || Self.systemWords.contains($0) || standInWords.contains($0))
        }
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
        add("Made \(when(input.now)). Jobs, folders and destinations are numbered instead of named. Messages keep only the")
        add("words Cryoframe and macOS use in their own messages, and short numbers; paths, web addresses and everything")
        add("else become [path], [url] or […].")
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
