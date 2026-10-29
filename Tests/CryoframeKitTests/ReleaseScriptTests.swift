//
//  ReleaseScriptTests.swift
//  CryoframeKitTests
//
//  scripts/appcast.sh signs every update with the key in the login keychain, using
//  Sparkle's sign_update. It used to download that tool to /tmp, where any local
//  user can make the folder first, and run whatever it found there, with no check
//  of what was downloaded. These read the script, since running it signs a release.
//

import Testing
import Foundation

private func appcastScript() throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent("scripts/appcast.sh"), encoding: .utf8)
}

/// the script's lines that run something, comments left out
private func code(_ script: String) -> [String] {
    script.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.hasPrefix("#") }
}

@Suite struct ReleaseScriptTests {
    @Test func theSigningToolIsNeverKeptInASharedTemporaryFolder() throws {
        let lines = code(try appcastScript())
        #expect(!lines.contains { $0.contains("/tmp") }, "\(lines.filter { $0.contains("/tmp") })")
        #expect(lines.contains { $0.hasPrefix("CACHE=") && $0.contains("$HOME/Library/Caches/") })
    }

    @Test func theDownloadIsCheckedAgainstAPinnedHashBeforeItIsUnpacked() throws {
        let lines = code(try appcastScript())
        let pin = try #require(lines.first { $0.hasPrefix("SPARKLE_SHA256=") })
        #expect(pin.range(of: #"^SPARKLE_SHA256="[0-9a-f]{64}"$"#, options: .regularExpression) != nil)
        let check = try #require(lines.firstIndex { $0.contains("shasum -a 256") })
        let unpack = try #require(lines.firstIndex { $0.contains("tar -x") })
        #expect(check < unpack)
        #expect(!lines.contains { $0.contains("| tar") })            // never straight from the network
    }

    @Test func aToolsFolderSomeoneElseCouldChangeIsRefused() throws {
        let lines = code(try appcastScript())
        #expect(lines.contains { $0.contains("stat -f") && $0.contains("%u") })
    }
}
