//
//  ContentsCostTests.swift
//  CryoframeKitTests
//
//  What a version's file list costs on a 200,000-file library: the walk with and
//  without it, writing it plain and sealed, its size, and searching it. A
//  measurement, not a check, so it runs only when asked:
//    TEST_RUNNER_CRYOFRAME_MEASURE_LISTING=1 xcodebuild test … \
//      -only-testing:'CryoframeKitTests/ContentsCostTests'
//

import Testing
import Foundation
@testable import CryoframeKit

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CRYOFRAME_MEASURE_LISTING"] != nil))
struct ContentsCostTests {
    @Test func aListOfTwoHundredThousandFiles() throws {
        let fm = FileManager.default
        // "keep": the library is made once and kept between runs, to measure again
        let keep = ProcessInfo.processInfo.environment["CRYOFRAME_MEASURE_LISTING"] == "keep"
        let base = fm.temporaryDirectory.appendingPathComponent(keep ? "cf-listcost-kept" : "cf-listcost-\(UUID().uuidString)")
        let lib = base.appendingPathComponent("Library")
        defer {
            for d in ["plain", "sealed"] { try? fm.removeItem(at: base.appendingPathComponent(d)) }
            if !keep { try? fm.removeItem(at: base) }
        }
        let payload = Data("x".utf8)
        if !fm.fileExists(atPath: lib.appendingPathComponent("Folder 199/Sub folder/IMG_199999 résumé.jpg").path) {
            for d in 0..<200 {
                let dir = lib.appendingPathComponent("Folder \(d)/Sub folder", isDirectory: true)
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                for f in 0..<1000 { fm.createFile(atPath: dir.appendingPathComponent("IMG_\(d * 1000 + f) résumé.jpg").path, contents: payload) }
            }
        }
        func time(_ body: () throws -> Void) rethrows -> Double {
            let t = ProcessInfo.processInfo.systemUptime; try body(); return ProcessInfo.processInfo.systemUptime - t
        }
        let binding = ContentsCrypto.Binding(jobID: "JOB", libraryID: "lib", version: "2026-10-01-120000")
        _ = JobExecutor.directoryStats(lib, forZip: true)                     // warm the caches
        let bare = time { _ = JobExecutor.directoryStats(lib, forZip: true) }
        let c = ContentsListing.Collector(binding: binding)
        let listed = time { _ = JobExecutor.directoryStats(lib, forZip: true, listing: c) }
        let plainDir = base.appendingPathComponent("plain"), sealedDir = base.appendingPathComponent("sealed")
        try fm.createDirectory(at: plainDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: sealedDir, withIntermediateDirectories: true)
        var plain: StagedContents?
        let writePlain = time { plain = ContentsListing.write(c, master: nil, encrypted: false, into: plainDir) }
        let keyring = ContentsKeyring()
        var key: Any?
        let derive = time { key = keyring.master(jobID: "JOB", passphrase: "pw") }
        let c2 = ContentsListing.Collector(binding: binding)
        _ = JobExecutor.directoryStats(lib, forZip: true, listing: c2)
        var sealed: StagedContents?
        let writeSealed = time { sealed = ContentsListing.write(c2, master: keyring.master(jobID: "JOB", passphrase: "pw"), encrypted: true, into: sealedDir) }
        let p = try #require(plain), s = try #require(sealed)
        #expect(key != nil && p.digest.entries == 200_400 && !p.digest.partial)
        func archive(_ dir: URL, _ d: ContentsDigest, encrypted: Bool) -> RestorableArchive {
            let v = dir.appendingPathComponent("2026-10-01-120000")
            try? fm.createDirectory(at: v, withIntermediateDirectories: true)
            try? fm.copyItem(at: dir.appendingPathComponent(d.name), to: v.appendingPathComponent(d.name))
            var a = RestorableArchive(dir: v, libraryName: "Library", format: .sealedZip, bytes: 1, artifactNames: ["Library.zip"],
                                      encrypted: encrypted, version: VersionStamp.date("2026-10-01-120000"),
                                      libraryKey: LibraryIdentity.key(jobID: "JOB", libraryID: "lib"))
            a.contents = d
            return a
        }
        let search = ContentsSearch(keyring: keyring)
        var hitsPlain = 0, hitsSealed = 0
        let searchPlain = time { hitsPlain = search.search(ContentsQuery("img_123456")!, in: archive(plainDir, p.digest, encrypted: false), passphrases: { _ in [] })?.hits.count ?? -1 }
        let searchSealed = time { hitsSealed = search.search(ContentsQuery("RÉSUMÉ")!, in: archive(sealedDir, s.digest, encrypted: true), passphrases: { _ in ["pw"] })?.hits.count ?? -1 }
        #expect(hitsPlain == 1 && hitsSealed == 200)
        print(String(format: "LISTING COST 200k: walk %.2fs, walk+list %.2fs, write plain %.2fs (%d bytes), PBKDF2 %.2fs, write sealed %.2fs (%d bytes), search plain %.2fs, search sealed (key cached) %.2fs",
                     bare, listed, writePlain, Int(p.digest.size), derive, writeSealed, Int(s.digest.size), searchPlain, searchSealed))
    }
}
