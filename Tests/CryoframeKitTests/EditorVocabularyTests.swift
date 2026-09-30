//
//  EditorVocabularyTests.swift
//  CryoframeKitTests
//
//  The job editor speaks one vocabulary: a job backs up libraries and folders to
//  destinations; one is the main destination; drives take turns or are away; each
//  backup keeps one up-to-date copy or dated versions; some are kept; a check is
//  quick or full. The words the engine uses for the same things (target, volume,
//  primary, sealed, mirror, held, archive, resumable, snapshot) never reach it:
//  not in its own text, and not in the Kit messages it shows.
//

import Testing
import Foundation

private let banned = ["target", "volume", "primary", "sealed", "mirror", "held", "archive", "resumable", "snapshot"]

/// the banned words in `text`, their plurals and past forms included
private func violations(_ text: String) -> [String] {
    let words = text.lowercased().split { !$0.isLetter }.map(String.init)
    return words.filter { w in banned.contains { b in [b, b + "s", b + "d", b + "ed", b + "ing"].contains(w) } }
}

/// the text a person reads in a Swift file: literals that are sentences (they hold a
/// space), and single words handed straight to something that shows them
private func shownText(_ file: String) throws -> [String] {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    var text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
    text = text.replacingOccurrences(of: #"//[^\n]*"#, with: "", options: .regularExpression)
    var out: [String] = []
    let literal = try NSRegularExpression(pattern: #"(\w*\(?\.?)\s*"((?:[^"\\\n]|\\.)*)""#)
    let ns = text as NSString
    for m in literal.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        let before = ns.substring(with: m.range(at: 1))
        var s = ns.substring(with: m.range(at: 2))
        // interpolations are names and numbers, not words of ours
        s = s.replacingOccurrences(of: #"\\\((?:[^()]|\([^()]*\))*\)"#, with: " ", options: .regularExpression)
        let showing = ["Text(", "Button(", "Label(", "pill(", "badge(", "help(", ".help("].contains(before)
        if s.contains(" ") || showing { out.append(s) }
    }
    return out
}

@Suite struct EditorVocabularyTests {
    @Test(arguments: [
        "Sources/Cryoframe/JobEditor.swift",
        "Sources/Cryoframe/JobEditorSheets.swift",
        "Sources/Cryoframe/JobDeleteSheet.swift",
        "Sources/CryoframeKit/JobEditImpact.swift",
        "Sources/CryoframeKit/DrivePairing.swift",
        "Sources/CryoframeKit/DriveRename.swift",
        "Sources/CryoframeKit/JobRemoval.swift",
        "Sources/CryoframeKit/JobDraftState.swift",
        "Sources/CryoframeKit/Source.swift",
        "Sources/CryoframeKit/LibraryNames.swift",
    ])
    func theEditorSpeaksOneVocabulary(file: String) throws {
        let shown = try shownText(file)
        #expect(!shown.isEmpty, "read nothing from \(file)")
        for s in shown {
            #expect(violations(s).isEmpty, "\(file): “\(s)” says \(violations(s))")
        }
    }

    @Test func theCheckCatchesTheWordsAndTheirForms() {
        #expect(violations("Two archives were sealed on the primary volume") == ["archives", "sealed", "primary", "volume"])
        #expect(violations("One up-to-date copy; dated versions, kept.").isEmpty)
        #expect(violations("archivebox externaldrive").isEmpty)
    }
}
