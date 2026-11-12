//
//  SharedJSONFileTests.swift
//  CryoframeKitTests
//
//  A shared file that is there but can't be decoded (see SharedJSONFile) used to read
//  as empty, and the next change wrote that back with one record in it. What it held
//  is now kept beside it before it is replaced, and a file whose bytes can't be read
//  is never written over.
//

import Testing
import Foundation
@testable import CryoframeKit

private func scratch(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-shared-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return TempTracker.track(d)
}

private func shared(_ url: URL) -> SharedJSONFile<[String]> {
    SharedJSONFile(url: url, lockName: "records.lock", empty: { [] })
}

private func add(_ record: String, to file: SharedJSONFile<[String]>) {
    file.update { (records: inout [String]) -> (changed: Bool, result: Void) in
        records.append(record)
        return (true, ())
    }
}

private func copies(of url: URL) throws -> [URL] {
    let dir = url.deletingLastPathComponent()
    return try FileManager.default.contentsOfDirectory(atPath: dir.path)
        .filter { $0.hasPrefix(url.lastPathComponent + ".unreadable-") }.map { dir.appendingPathComponent($0) }
}

@Suite struct SharedJSONFileTests {

    @Test func aMissingFileIsMadeAndAReadableOneIsAddedTo() throws {
        let url = scratch("plain").appendingPathComponent("records.json")
        let file = shared(url)
        #expect(file.read().isEmpty)
        add("one", to: file)
        add("two", to: file)
        #expect(file.read() == ["one", "two"])
        #expect(try copies(of: url).isEmpty)
    }

    @Test func whatAFileThatCantBeDecodedHeldIsKeptBesideItBeforeItIsReplaced() throws {
        let url = scratch("future").appendingPathComponent("records.json")
        let future = Data(#"{"records": "as a later version writes them"}"#.utf8)
        try future.write(to: url)
        let file = shared(url)

        // reading changes nothing, and keeps no copy
        #expect(file.read().isEmpty)
        #expect(try Data(contentsOf: url) == future)
        #expect(try copies(of: url).isEmpty)
        // a change that changes nothing writes nothing
        file.update { (_: inout [String]) -> (changed: Bool, result: Void) in (false, ()) }
        #expect(try Data(contentsOf: url) == future)

        add("one", to: file)
        add("two", to: file)
        #expect(file.read() == ["one", "two"])
        let kept = try copies(of: url)
        #expect(kept.count == 1, "\(kept.map(\.lastPathComponent))")
        #expect(try kept.first.map { try Data(contentsOf: $0) } == future)
    }

    @Test func aFileWhoseBytesCantBeReadIsNeverWrittenOver() throws {
        // root reads any file: nothing to test
        try #require(getuid() != 0)
        let url = scratch("locked").appendingPathComponent("records.json")
        let file = shared(url)
        add("one", to: file)
        let before = try Data(contentsOf: url)
        #expect(chmod(url.path, 0) == 0)
        defer { chmod(url.path, 0o644) }

        #expect(file.read().isEmpty)
        add("two", to: file)
        #expect(chmod(url.path, 0o644) == 0)
        #expect(try Data(contentsOf: url) == before)
        #expect(file.read() == ["one"])
        #expect(try copies(of: url).isEmpty)
    }
}
