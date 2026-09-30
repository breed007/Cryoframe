//
//  DiagnosticsTests.swift
//  CryoframeKitTests
//
//  The "Report a problem" file is public once attached to an issue. These pin that
//  it holds no path in the home folder, no user or Mac name, no URL (an alert
//  topic or a webhook token), no name the user chose, and no file name from a
//  library, while keeping what a fix needs.
//

import Testing
import Foundation
@testable import CryoframeKit

private let home = "/Users/jdoe"

private func redactor(names: [(String, String)] = []) -> Redactor {
    Redactor(names: names, userWords: ["jdoe", "Jane Doe", "Jane", "Doe", "Jane's MacBook Pro"])
}

private func run(_ job: BackupJob, _ outcome: RunOutcomeKind, at: Date, summary: String,
                 libraries: [LibraryOutcome] = [], warning: String? = nil) -> RunRecord {
    RunRecord(id: UUID().uuidString, jobID: job.id, jobName: job.name, startedAt: at.addingTimeInterval(-120), finishedAt: at,
              trigger: "scheduled", outcome: outcome, summary: summary, libraries: libraries, bytes: 0, warning: warning)
}

@Suite struct DiagnosticsTests {

    @Test func pathsInTheHomeFolderOnDrivesAndInTempAreRemoved() {
        let r = redactor()
        #expect(r.redact("couldn't read /Users/jdoe/Documents/Client Work/plan.pdf: Permission denied")
                == "couldn't read ~/[path]: Permission denied")
        #expect(r.redact("the mirror at /Volumes/Jane's T7/Backups/Photos was busy")
                == "the mirror at /Volumes/[drive]/[path]")
        #expect(r.redact("staging /private/var/folders/8t/cz5m/T/cf-mirror-1/mnt (Resource busy)")
                == "staging [temp]/[path] (Resource busy)")
        #expect(r.redact("see ~/Library/Logs/x.log") == "see ~/[path]")
        // system tools stay: they say which tool failed
        #expect(r.redact("/usr/bin/hdiutil failed") == "/usr/bin/hdiutil failed")
    }

    @Test func urlsAndEmailsAreRemoved() {
        let r = redactor()
        #expect(r.redact("alert to https://ntfy.sh/jdoe-backups-7f3k failed") == "[…] to [url] failed")
        #expect(r.redact("webhook https://hooks.example.com/services/T000/B000/XXXXsecret?token=abc refused")
                == "webhook [url] refused")
        #expect(r.redact("smb://nas.local/Backups") == "[url]")
        #expect(r.redact("mail jane.doe@example.com") == "mail [email]")
    }

    @Test func theUsersNamesAndTheMacsAreRemoved() {
        let r = redactor()
        #expect(r.redact("owned by jdoe") == "owned by [user]")
        #expect(r.redact("Jane Doe's files on Jane's MacBook Pro") == "[user]'s files on [user]")
        // not inside other words (which, not being Cryoframe's, go anyway)
        #expect(r.redact("jdoes and Janet") == "[…] and […]")
    }

    @Test func namesTheUserChoseAndLibraryFilesAreRemoved() {
        let r = redactor(names: [("Client Work, 2026", "folder 1"), ("Nightly to T7", "job 1"), ("T7", "destination 1 (external drive)")])
        #expect(r.redact("Client Work, 2026: 2 items (report.pdf, taxes 2025.xlsx) didn't read back")
                == "folder 1: 2 items ([…]) didn't read back")
        #expect(r.redact("Nightly to T7 finished") == "job 1 finished")
        #expect(r.redact("tools/deep.pipe has the wrong size") == "[path] has the wrong size")
        #expect(r.redact("see cryoframe-manifest.json, via ntfy/webhook") == "see cryoframe-manifest.json, […] ntfy/webhook")
        #expect(r.redact("version 1.6.0 on macOS 26.7") == "version 1.6.0 on macOS 26.7")
    }

    // Text that isn't Cryoframe's own is untrusted: a drive's name outside a path, an
    // id, a network address, a token. Only Cryoframe's and macOS's words, and numbers,
    // are kept.
    @Test func onlyCryoframesAndMacOSsWordsSurvive() {
        let r = redactor()
        #expect(r.redact("not enough room on Fortress SSD to rehearse the restore: it needs about 12 GB free and has 3.5 GB")
                == "not enough room on […] to rehearse the restore: it needs about 12 GB free and has 3.5 GB")
        #expect(r.redact("job 8E3C2F7A-1B2C-4D5E-9F00-112233445566 at 192.168.1.20 and fe80::1c2d:3e4f token ghp_x9Y8z7W6v5") ==
                "job [id] at [address] and [address] […]")
        #expect(r.redact("hdiutil: attach failed - Resource busy") == "hdiutil: attach failed - Resource busy")
        #expect(r.redact("the new copy of the mirror didn't read back the same as the library")
                == "the new copy of the mirror didn't read back the same as the library")
        #expect(r.redact("Board Minutes.pages is missing") == "[…] is missing")
        #expect(r.redact("/usr/bin/rsync failed: Operation not permitted") == "/usr/bin/rsync failed: Operation not permitted")
    }

    // Every word of every message Cryoframe writes is in the vocabulary the report
    // keeps: a message changed without running scripts/diagnostics-vocabulary.py
    // would lose its words from the report (never leak more).
    @Test func theVocabularyHasEveryWordOfCryoframesMessages() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Sources/CryoframeKit").path)
            .filter { $0.hasSuffix(".swift") && $0 != "DiagnosticsVocabulary.swift" }.map { "Sources/CryoframeKit/" + $0 }
        files += ["Sources/Cryoframe/AgentMain.swift", "Sources/Cryoframe/HealthSchedule.swift", "Sources/Cryoframe/RehearsalSchedule.swift"]
        var missing = Set<String>()
        for f in files {
            let text = try String(contentsOf: root.appendingPathComponent(f), encoding: .utf8)
                .replacingOccurrences(of: #"//[^\n]*"#, with: "", options: .regularExpression)
            let literals = try NSRegularExpression(pattern: #""((?:[^"\\\n]|\\.)*)""#)
            for m in literals.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let literal = (text as NSString).substring(with: m.range(at: 1))
                    .replacingOccurrences(of: #"\\\((?:[^()]|\([^()]*\))*\)"#, with: " ", options: .regularExpression)
                for w in Redactor.words(in: literal) where Redactor.isVocabularyWord(w) && !Redactor.productWords.contains(w) {
                    missing.insert(w)   // split and filtered as the script does
                }
            }
        }
        #expect(missing.isEmpty, "run scripts/diagnostics-vocabulary.py: missing \(missing.sorted())")
    }

    // A whole report, from jobs and history full of private names: none of them
    // survive, and what a fix needs does.
    @Test func aReportHoldsWhatAFixNeedsAndNothingPrivate() {
        let dest = Target.localVolume(id: "t7", name: "Jane's T7", dir: URL(fileURLWithPath: "/Volumes/Jane's T7/Backups"))
        let custom = ContentType.genericFolder(id: "c1", displayName: "Tax Returns", path: .absolute(home + "/Documents/Tax Returns"))
        var job = BackupJob(name: "Jane nightly", libraries: [.photos, custom], target: dest,
                            format: .sealedDMG, frequency: .daily(hour: 2, minute: 0), createdAt: Date(timeIntervalSince1970: 0))
        job.encrypted = true
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let failed = run(job, .failed, at: now.addingTimeInterval(-3600), summary: "Tax Returns failed",
                         libraries: [LibraryOutcome(from: .failed(library: "Tax Returns", destination: "Jane's T7",
                                                                  error: "couldn't read \(home)/Documents/Tax Returns/2025/return.pdf: Permission denied"))],
                         warning: "Tax Returns: left 1 named pipe, socket or device out of the mirror (agent.sock).")
        let gone = RunRecord(id: "x", jobID: "old", jobName: "Old Secret Job", startedAt: now, finishedAt: now, trigger: "manual",
                             outcome: .completed, summary: "Wedding Photos archived", libraries: [
                                LibraryOutcome(from: .completed(library: "Wedding Photos", destination: "NAS", parts: 1, bytes: 10, verified: nil))],
                             bytes: 10, warning: nil)
        let check = HealthRecord(id: "h", jobID: job.id, jobName: job.name, checkedAt: now, archivesChecked: 2,
                                 failures: ["Tax Returns (2026-09-01): checksum mismatch in /Volumes/Jane's T7/Backups/Tax Returns"],
                                 kind: "drill", skipped: 0, verified: [], trigger: "scheduled")
        let input = DiagnosticsReport.Input(appVersion: "1.6.0 (160)", helperVersion: "1.6.0", agentState: "on",
                                            macOS: "26.7 (25H100)", hardware: "arm64", jobs: [job], runs: [failed, gone],
                                            health: [check], settings: [("Alerts", "ntfy (https://ntfy.sh/jane-secret)")], now: now)
        let redactor = DiagnosticsReport.redactor(for: input, home: home, userName: "jdoe", fullName: "Jane Doe",
                                                  hostName: "Jane's MacBook Pro")
        let report = DiagnosticsReport.build(input, redactor: redactor)
        for secret in ["Jane", "jdoe", "T7", "Tax Returns", "return.pdf", "agent.sock", "Wedding Photos", "Old Secret Job",
                       "NAS", "jane-secret", "/Volumes/", "/Users/", "Documents", "Backups"] where secret != "/Volumes/" {
            #expect(!report.contains(secret), "\(secret) is in the report:\n\(report)")
        }
        #expect(!report.contains("/Volumes/Jane"))
        for kept in ["1.6.0 (160)", "26.7 (25H100)", "sealed disk image, encrypted", "daily at 02:00", "Photos",
                     "job 1", "folder 1", "destination 1 (external drive)", "failed", "Permission denied", "drill: FAILED",
                     "checksum mismatch", "left 1 named pipe"] {
            #expect(report.contains(kept), "\(kept) is missing:\n\(report)")
        }
    }
}
