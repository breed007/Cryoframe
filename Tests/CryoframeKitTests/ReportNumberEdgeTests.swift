//
//  ReportNumberEdgeTests.swift
//  CryoframeKitTests
//
//  The problem report's number rule at its edges. A number is judged whole, its
//  digit groups joined by one space, dash, dot, slash or comma, and a long one is
//  removed. A card, social security or phone number is written with other
//  separators too, typed by hand or pasted from a document: two spaces, a
//  no-break space, an en dash, " - ". Each group on its own is short, so it is kept,
//  and the whole number is in the report.
//

import Testing
import Foundation
@testable import CryoframeKit

private func report(error: String) -> String {
    let dest = Target.localVolume(id: "t7", name: "Backups", dir: URL(fileURLWithPath: "/Volumes/T7/Backups"))
    let work = ContentType.genericFolder(id: "w", displayName: "Work", path: .absolute("/Users/jdoe/Work"))
    let job = BackupJob(name: "Nightly", libraries: [work], target: dest, format: .liveMirror(sizeGB: 1),
                        frequency: .daily(hour: 2, minute: 0), createdAt: Date(timeIntervalSince1970: 0))
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let run = RunRecord(id: "r", jobID: job.id, jobName: job.name, startedAt: now.addingTimeInterval(-60), finishedAt: now,
                        trigger: "scheduled", outcome: .failed, summary: "Work failed",
                        libraries: [LibraryOutcome(from: .failed(library: "Work", destination: "Backups", error: error))],
                        bytes: 0, warning: nil)
    let input = DiagnosticsReport.Input(appVersion: "1.6.0 (160)", helperVersion: "1.6.0", agentState: "on", macOS: "26.7",
                                        hardware: "Mac14,2", jobs: [job], runs: [run], health: [], settings: [], now: now)
    return DiagnosticsReport.build(input, redactor: DiagnosticsReport.redactor(for: input, home: "/Users/jdoe", userName: "jdoe",
                                                                               fullName: "Jane Doe", hostName: "Jane's MacBook Pro"))
}

/// the file names a read-back check lists, as the run's error
private func missing(_ names: [String]) -> String {
    MirrorCopyError.readBackMismatch(count: names.count, examples: names.map { "\($0) is missing" }).localizedDescription
}

@Suite struct ReportNumberEdgeTests {

    // A card number, its groups apart by something other than one plain space or
    // dash. Each separator here is what a keyboard, Word or a web page puts there.
    @Test(arguments: [
        ("two spaces", "4111  5222  6333  7444"),
        ("no-break spaces", "4111\u{00A0}5222\u{00A0}6333\u{00A0}7444"),
        ("thin spaces", "4111\u{2009}5222\u{2009}6333\u{2009}7444"),
        ("en dashes", "4111\u{2013}5222\u{2013}6333\u{2013}7444"),
        ("no-break hyphens", "4111\u{2011}5222\u{2011}6333\u{2011}7444"),
        ("spaced dashes", "4111 - 5222 - 6333 - 7444"),
        ("tabs", "4111\t5222\t6333\t7444"),
        ("plus signs", "4111+5222+6333+7444"),
        ("colons (a slash in Finder)", "4111:5222:6333:7444"),
        ("middle dots", "4111·5222·6333·7444"),
    ])
    func aCardNumberIsRemovedWhateverSeparatesItsGroups(_ how: String, _ card: String) {
        let text = report(error: missing(["Card \(card)"]))
        let left = ["4111", "5222", "6333", "7444"].filter { text.contains($0) }
        #expect(left.count < 2, "\(how): \(left) of the card number in the report:\n\(text)")
    }

    // The same for the other shapes the rule was written for.
    @Test(arguments: [
        ("social security, spaced dashes", "123 - 45 - 6789", ["123", "45", "6789"]),
        ("social security, no-break spaces", "123\u{00A0}45\u{00A0}6789", ["123", "45", "6789"]),
        ("phone, spaced dash", "(404) 555 - 1234", ["404", "555", "1234"]),
        ("phone, spaced slashes", "404 / 555 / 1234", ["404", "555", "1234"]),
        ("phone, en dash", "404\u{2013}555\u{2013}1234", ["404", "555", "1234"]),
    ])
    func otherIdentifyingNumbersAreRemovedWhateverSeparatesThem(_ how: String, _ number: String, _ groups: [String]) {
        let text = report(error: missing(["Scan \(number)"]))
        let left = groups.filter { text.contains($0) }
        #expect(left.count < 2, "\(how): \(left) in the report:\n\(text)")
    }

    // A national identity number written with thousands dots (Argentina's DNI,
    // "12.345.678") has the shape of a version of 8 digits, and was kept as one. No
    // version Cryoframe or macOS writes has groups of three after the first.
    @Test func anIDWrittenWithThousandsDotsIsRemoved() {
        let text = report(error: missing(["DNI 12.345.678"]))
        #expect(!text.contains("12.345.678"), "in the report:\n\(text)")
    }

    // What the rule says it keeps: a long count with its unit ("1234567 bytes").
    // Judged whole it's kept, then each word is judged again on its own, and the
    // number alone is too long.
    @Test func aLongCountWithItsUnitIsKept() {
        let text = report(error: "copied 1234567 bytes of 2345678 bytes")
        #expect(text.contains("1234567 bytes") && text.contains("2345678 bytes"), "in the report:\n\(text)")
    }

    // Short numbers and what the fix needs stay.
    @Test func whatAFixNeedsStays() {
        let text = report(error: "rsync error: some files/attrs were not transferred (see previous errors) (code 23); 72,000 files; 3.5 GB; macOS 26.7; 2026-09-30 14:13:20")
        for kept in ["code 23", "72,000 files", "3.5 GB", "26.7", "2026-09-30 14:13:20"] {
            #expect(text.contains(kept), "\(kept) went:\n\(text)")
        }
    }
}
