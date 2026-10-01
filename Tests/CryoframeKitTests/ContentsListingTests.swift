//
//  ContentsListingTests.swift
//  CryoframeKitTests
//
//  "Find which version holds a file": each sealed version's file list.
//
//    - the list comes from the run's walk, leaves out what no archive holds, and is
//      named in the manifest's own field, never among the artifacts;
//    - an encrypted job's list is sealed in its own format, bound to its job,
//      library and version, under a fresh file salt each time, and opens only with
//      the right passphrase, whole and in order;
//    - a list that is missing, changed, cut short, locked or another version's is
//      "no list", never "not in this version";
//    - checks, discovery, retention and 1.5.6 see only the archive.
//

import Testing
import Foundation
import CryptoKit
@testable import CryoframeKit

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-list-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

private func sh(_ cmd: String, in dir: URL) throws {
    let r = try ProcessCommandRunner().run("/bin/sh", ["-c", "cd '\(dir.path)' && \(cmd)"])
    try #require(r.ok, "\(cmd): \(r.stderr)")
}

/// one derivation for the whole suite: each takes about a third of a second
private let keyring = ContentsKeyring()
private func master(_ pass: String = "correct horse", job: String = "JOB-1") -> SymmetricKey {
    keyring.master(jobID: job, passphrase: pass)!
}

private let stamp = "2026-10-01-120000"

/// a version folder holding only a list, and the archive record discovery would make of it
private func version(_ base: URL, entries: [(String, ContentsEntry.Kind)], job: String = "JOB-1", lib: String = "lib-1",
                     version: String = stamp, pass: String? = nil, collector: ContentsListing.Collector? = nil) throws -> RestorableArchive {
    let dir = base.appendingPathComponent("Library/\(version)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let c = collector ?? ContentsListing.Collector(binding: .init(jobID: job, libraryID: lib, version: version))
    for (p, k) in entries { c.add(p, size: 10, modified: Date(timeIntervalSince1970: 1_700_000_000), kind: k) }
    let staged = try #require(ContentsListing.write(c, master: pass.map { master($0, job: job) }, encrypted: pass != nil, into: dir))
    var a = RestorableArchive(dir: dir, libraryName: "Library", format: .sealedDMG, bytes: 1, artifactNames: ["Library.dmg"],
                              encrypted: pass != nil, version: VersionStamp.date(version),
                              libraryKey: LibraryIdentity.key(jobID: job, libraryID: lib))
    a.contents = staged.digest
    return a
}

private func read(_ a: RestorableArchive, passes: [String] = [], job: String = "JOB-1") -> (ContentsListing.ReadOutcome, [ContentsEntry]) {
    var seen: [ContentsEntry] = []
    let out = ContentsListing.read(a, master: { j in passes.compactMap { keyring.master(jobID: j, passphrase: $0) } }) { seen.append($0) }
    return (out, seen)
}

private func search(_ q: String, _ a: RestorableArchive, passes: [String] = []) -> VersionSearchResult? {
    ContentsSearch(keyring: keyring).search(ContentsQuery(q)!, in: a, passphrases: { _ in passes })
}

/// rewrite the manifest's record of a list to match the file as it is now, as
/// someone who changes both would
private func rerecord(_ a: inout RestorableArchive) throws {
    let url = a.dir.appendingPathComponent(a.contents!.name)
    a.contents!.size = Checksum.byteSize(of: url)
    a.contents!.sha256 = try Checksum.digest(of: url)
}

@Suite(.serialized) struct ContentsListingTests {

    // MARK: the list

    // A plain job's list is gzip of JSON lines: gunzip and any JSON reader read it.
    // It holds folders, files and links from the library's top, and no socket or pipe.
    @Test func aPlainListIsReadableJSONLinesWithoutWhatNoArchiveHolds() throws {
        let base = folder("plain")
        defer { try? FileManager.default.removeItem(at: base) }
        let lib = base.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try sh(#"mkdir -p 'a "quoted"/sub' && echo x > 'a "quoted"/sub/back\slash.txt' && echo y > top.txt && ln -s top.txt link && printf 'z' > "$(printf 'tab\tname')""#, in: lib)
        try #require(mkfifo(lib.appendingPathComponent("build.pipe").path, 0o644) == 0)
        let bound = try ProcessCommandRunner().run("/bin/sh", ["-c", "cd '\(lib.path)' && /usr/bin/python3 -c \"import socket; socket.socket(socket.AF_UNIX).bind('agent.sock')\""])
        try #require(bound.ok, "\(bound.stderr)")
        let c = ContentsListing.Collector(binding: .init(jobID: "JOB-1", libraryID: "lib-1", version: stamp))
        let stats = JobExecutor.directoryStats(lib, forZip: true, listing: c)
        #expect(stats.readable)
        let dir = base.appendingPathComponent("v")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let staged = try #require(ContentsListing.write(c, master: nil, encrypted: false, into: dir))
        #expect(staged.url.lastPathComponent == ContentsListing.plainName && !staged.digest.partial)
        let out = try ProcessCommandRunner().run("/usr/bin/gunzip", ["-c", staged.url.path])
        try #require(out.ok, "\(out.stderr)")
        let lines = out.stdout.split(separator: "\n").map(String.init)
        let objects = try lines.map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        #expect(objects.first?["cryoframe"] as? String == "contents" && objects.first?["version"] as? String == stamp)
        #expect(objects.last?["end"] as? Bool == true && objects.last?["partial"] as? Bool == false)
        let paths = Set(objects.dropFirst().dropLast().compactMap { $0["p"] as? String })
        #expect(paths == ["a \"quoted\"", "a \"quoted\"/sub", "a \"quoted\"/sub/back\\slash.txt", "top.txt", "link", "tab\tname"], "\(paths)")
        #expect(objects.last?["n"] as? Int == paths.count && staged.digest.entries == paths.count)
        let types = Dictionary(uniqueKeysWithValues: objects.dropFirst().dropLast().map { ($0["p"] as! String, $0["t"] as! String) })
        #expect(types["link"] == "l" && types["top.txt"] == "f" && types["a \"quoted\""] == "d")
    }

    // A whole list is read back item for item; a search finds by name, and only a
    // whole list says a file isn't in its version.
    @Test func aWholeListReadsBackAndSaysWhatIsntThere() throws {
        let base = folder("whole")
        defer { try? FileManager.default.removeItem(at: base) }
        let a = try version(base, entries: [("Docs", .folder), ("Docs/Taxes 2024.pdf", .file), ("notes.txt", .file)])
        let (out, seen) = read(a)
        #expect(out == .read(entries: 3, partial: false))
        #expect(seen.map(\.path) == ["Docs", "Docs/Taxes 2024.pdf", "notes.txt"])
        #expect(search("taxes", a)?.hits.map(\.path) == ["Docs/Taxes 2024.pdf"])
        #expect(search("docs/tax", a)?.hits.map(\.path) == ["Docs/Taxes 2024.pdf"])      // a path, with a slash
        #expect(search("docs", a)?.hits.map(\.path) == ["Docs"])                         // a name, without
        let none = try #require(search("passport", a))
        #expect(none.isNotInVersion && none.summary == "Not in this version")
    }

    // A name written decomposed (as some file systems and apps do) is found by the
    // same name typed composed, and case doesn't matter.
    @Test func aDecomposedNameIsFoundByAComposedQuery() throws {
        let base = folder("nfd")
        defer { try? FileManager.default.removeItem(at: base) }
        let nfd = "Cafe\u{301} Re\u{301}sume\u{301}.txt"
        let a = try version(base, entries: [(nfd, .file), ("STRASSE.txt", .file)])
        #expect(search("café résumé", a)?.hits.count == 1)
        #expect(search("CAFÉ", a)?.hits.count == 1)
        #expect(search("Caf\u{E9}", a)?.hits.first?.path == nfd)                         // the name as it is on disk
        #expect(search("strasse", a)?.hits.count == 1)
    }

    // Past its cap the list stops and says so: matches are shown, and no match is
    // never "not in this version".
    @Test func aListPastItsCapIsPartialAndNeverSaysNotThere() throws {
        let base = folder("cap")
        defer { try? FileManager.default.removeItem(at: base) }
        let c = ContentsListing.Collector(binding: .init(jobID: "JOB-1", libraryID: "lib-1", version: stamp), entryLimit: 2)
        let a = try version(base, entries: [("one.txt", .file), ("two.txt", .file), ("three.txt", .file)], collector: c)
        #expect(a.contents?.partial == true && a.contents?.entries == 2)
        #expect(read(a).0 == .read(entries: 2, partial: true))
        let hit = try #require(search("one", a))
        #expect(hit.hits.count == 1 && hit.summary.contains("incomplete"))
        let miss = try #require(search("three", a))
        #expect(!miss.isNotInVersion && miss.summary.contains("incomplete"), "\(miss.summary)")
        #expect(!ContentsSearch.summary([miss], of: 1).contains("Not in"), "\(ContentsSearch.summary([miss], of: 1))")
    }

    // A walk that couldn't see part of the tree lists what it saw, as partial.
    @Test func aWalkThatCouldntSeeEverythingIsPartial() throws {
        let base = folder("unreadable")
        defer {
            _ = try? ProcessCommandRunner().run("/bin/chmod", ["-R", "u+rwx", base.path])
            try? FileManager.default.removeItem(at: base)
        }
        try sh("mkdir -p lib/closed && echo x > lib/closed/in.txt && echo y > lib/open.txt && chmod 000 lib/closed", in: base)
        let c = ContentsListing.Collector(binding: .init(jobID: "j", libraryID: "l", version: stamp))
        _ = JobExecutor.directoryStats(base.appendingPathComponent("lib"), listing: c)
        #expect(c.partial)
    }

    // Names that need escaping, dates before 1970 and names in any script read back
    // exactly as they were written.
    @Test func oddNamesAndDatesReadBackExactly() throws {
        let base = folder("odd")
        defer { try? FileManager.default.removeItem(at: base) }
        let names = ["a \"quoted\" name", "back\\slash", "tab\there", "new\nline", "ctrl\u{1}x", "emoji 📷.heic",
                     "Cafe\u{301}", "日本語/ファイル.txt", "plain.txt"]
        let c = ContentsListing.Collector(binding: .init(jobID: "JOB-1", libraryID: "lib-1", version: stamp))
        for (i, n) in names.enumerated() { c.add(n, size: UInt64(i), modified: Date(timeIntervalSince1970: -86_400 * Double(i)), kind: .file) }
        let a = try version(base, entries: [], collector: c)
        let (out, seen) = read(a)
        #expect(out == .read(entries: names.count, partial: false))
        #expect(seen.map(\.path) == names)
        #expect(seen.map(\.modified) == names.indices.map { Int64(-86_400 * $0) })
        #expect(seen.map(\.size) == names.indices.map { UInt64($0) })
    }

    // A list longer than one sealed chunk, with lines split across chunks and across
    // what gzip hands out, reads back whole; Stop part-way counts for nothing.
    @Test func aBigSealedListReadsBackAcrossChunks() throws {
        let base = folder("big")
        defer { try? FileManager.default.removeItem(at: base) }
        let names = (0..<60_000).map { _ in "\(UUID().uuidString)/\(UUID().uuidString).dat" }
        let c = ContentsListing.Collector(binding: .init(jobID: "JOB-1", libraryID: "lib-1", version: stamp))
        for n in names { c.add(n, size: 1, modified: nil, kind: .file) }
        let a = try version(base, entries: [], pass: "correct horse", collector: c)
        #expect((a.contents?.size ?? 0) > UInt64(2 * ContentsCrypto.chunkSize), "\(a.contents?.size ?? 0)")
        let (out, seen) = read(a, passes: ["correct horse"])
        #expect(out == .read(entries: names.count, partial: false))
        #expect(seen.map(\.path) == names)
        let control = RunControl()
        var n = 0
        let stopped = ContentsListing.read(a, master: { j in [keyring.master(jobID: j, passphrase: "correct horse")!] }, control: control) { _ in
            n += 1; if n == 10 { control.cancel() }
        }
        #expect(stopped == .stopped)
        #expect(ContentsSearch(keyring: keyring).search(ContentsQuery(names[59_999])!, in: a, passphrases: { _ in ["correct horse"] },
                                                        control: control) == nil)
    }

    // MARK: no list is not "not found"

    @Test func everyWayAListCanBeMissingIsNoList() throws {
        let base = folder("nolist")
        defer { try? FileManager.default.removeItem(at: base) }
        let a = try version(base, entries: [("notes.txt", .file)])
        let file = a.dir.appendingPathComponent(ContentsListing.plainName)

        var unrecorded = a; unrecorded.contents = nil
        #expect(search("notes", unrecorded)?.answer == .noList(.notRecorded))

        var mirror = a; mirror.format = .liveMirror
        #expect(search("notes", mirror)?.answer == .noList(.mirror))

        // changed: one byte different, the manifest not
        var bytes = try Data(contentsOf: file)
        bytes[bytes.count / 2] ^= 0xff
        try bytes.write(to: file)
        #expect(search("notes", a)?.answer == .noList(.changed))
        // and with the manifest made to agree: a broken gzip is damaged, never a miss
        var agreed = a; try rerecord(&agreed)
        #expect(search("notes", agreed)?.answer == .noList(.damaged))

        try FileManager.default.removeItem(at: file)
        #expect(search("notes", a)?.answer == .noList(.missing))
    }

    // A list cut before its last line, or run on past it, isn't a whole list.
    @Test func aListWithoutItsLastLineOrWithMoreAfterItIsDamaged() throws {
        let base = folder("lines")
        defer { try? FileManager.default.removeItem(at: base) }
        let a = try version(base, entries: [("notes.txt", .file)])
        let file = a.dir.appendingPathComponent(ContentsListing.plainName)
        let text = try ProcessCommandRunner().run("/usr/bin/gunzip", ["-c", file.path]).stdout
        func regzip(_ s: String) throws -> RestorableArchive {
            let raw = base.appendingPathComponent("raw")
            try s.write(to: raw, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: file)
            let r = try ProcessCommandRunner().run("/bin/sh", ["-c", "/usr/bin/gzip -c '\(raw.path)' > '\(file.path)'"])
            try #require(r.ok)
            var b = a; try rerecord(&b); return b
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let noEnd = lines.dropLast(2).joined(separator: "\n") + "\n"
        #expect(search("notes", try regzip(noEnd))?.answer == .noList(.damaged))
        #expect(search("notes", try regzip(text + #"{"p":"extra.txt","s":1,"m":1,"t":"f"}"# + "\n"))?.answer == .noList(.damaged))
        // a count that disagrees with the manifest's
        let more = lines.dropLast(2).joined(separator: "\n") + "\n" + #"{"p":"extra.txt","s":1,"m":1,"t":"f"}"#
            + "\n" + #"{"end":true,"n":2,"partial":false}"# + "\n"
        #expect(search("notes", try regzip(more))?.answer == .noList(.damaged))
    }

    // A list moved to another version's folder (manifest and all) is that version's
    // no longer: no list, never its answer.
    @Test func aListInAnotherVersionsFolderIsNoList() throws {
        let base = folder("moved")
        defer { try? FileManager.default.removeItem(at: base) }
        for pass in [nil, "correct horse"] as [String?] {
            let a = try version(base, entries: [("notes.txt", .file)], version: "2026-09-01-120000", pass: pass)
            let other = base.appendingPathComponent("Library/2026-09-02-120000")
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: a.dir.appendingPathComponent(a.contents!.name), to: other.appendingPathComponent(a.contents!.name))
            var moved = a; moved.dir = other
            #expect(search("notes", moved, passes: ["correct horse"])?.answer == .noList(.elsewhere))
            // another library's folder of the same job
            var lib = a; lib.libraryKey = LibraryIdentity.key(jobID: "JOB-1", libraryID: "lib-2")
            #expect(search("notes", lib, passes: ["correct horse"])?.answer == .noList(.elsewhere))
            try FileManager.default.removeItem(at: base.appendingPathComponent("Library"))
        }
    }

    // MARK: encrypted lists

    // An encrypted job's list is sealed: no plaintext name in it, its own magic, and
    // it opens with the passphrase and only with it.
    @Test func anEncryptedListOpensOnlyWithItsPassphrase() throws {
        let base = folder("enc")
        defer { try? FileManager.default.removeItem(at: base) }
        let a = try version(base, entries: [("Secret Plans.txt", .file)], pass: "correct horse")
        let file = a.dir.appendingPathComponent(ContentsListing.encryptedName)
        let bytes = try Data(contentsOf: file)
        #expect(bytes.prefix(9) == Data("CRYOLIST1".utf8))
        #expect(bytes.range(of: Data("Secret".utf8)) == nil)
        #expect(!FileManager.default.fileExists(atPath: a.dir.appendingPathComponent(ContentsListing.plainName).path))
        #expect(search("secret", a, passes: ["correct horse"])?.hits.count == 1)
        #expect(search("secret", a, passes: ["wrong", "correct horse"])?.hits.count == 1)     // the one that opens it
        let wrong = try #require(search("secret", a, passes: ["Correct horse"]))
        #expect(wrong.answer == .noList(.wrongPassphrase) && wrong.summary.contains("passphrase"))
        #expect(search("secret", a, passes: [])?.answer == .noList(.locked))
        // a plain list where the manifest says encrypted wasn't written by Cryoframe
        var plain = try version(base.appendingPathComponent("p"), entries: [("x", .file)])
        plain.encrypted = true
        #expect(search("x", plain, passes: ["correct horse"])?.answer == .noList(.damaged))
    }

    // Each write draws a fresh file salt: the same list at the same version, written
    // twice, is two different files, under two different keys.
    @Test func eachWriteOfAnEncryptedListHasItsOwnSalt() throws {
        let b = ContentsCrypto.Binding(jobID: "JOB-1", libraryID: "lib-1", version: stamp)
        let base = folder("salt")
        defer { try? FileManager.default.removeItem(at: base) }
        let one = base.appendingPathComponent("1"), two = base.appendingPathComponent("2")
        try ContentsCrypto.seal(Data("same".utf8), binding: b, master: master(), to: one)
        try ContentsCrypto.seal(Data("same".utf8), binding: b, master: master(), to: two)
        let h1 = try ContentsCrypto.parseHeader(Data(contentsOf: one)), h2 = try ContentsCrypto.parseHeader(Data(contentsOf: two))
        #expect(h1.fileSalt != h2.fileSalt)
        #expect(try Data(contentsOf: one) != Data(contentsOf: two))
        #expect(h1.binding == b)
    }

    // Cut short, run on, reordered, a byte flipped, or its header changed: it doesn't
    // open, and none of it is handed out as if it had.
    @Test func aSealedListThatWasTamperedWithNeverOpens() throws {
        let b = ContentsCrypto.Binding(jobID: "JOB-1", libraryID: "lib-1", version: stamp)
        var plain = Data(count: 3 * ContentsCrypto.chunkSize + 1000)
        for i in plain.indices { plain[i] = UInt8(truncatingIfNeeded: i &* 31) }
        let base = folder("tamper")
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("l")
        try ContentsCrypto.seal(plain, binding: b, master: master(), to: url)
        let good = try Data(contentsOf: url)
        func opens(_ d: Data) -> Result<Data, Error> {
            var got = Data()
            do {
                try ContentsCrypto.open(d, master: { _ in [master()] }) { got += $0; return true }
                return .success(got)
            } catch { return .failure(error) }
        }
        guard case .success(let back) = opens(good) else { Issue.record("the good file didn't open"); return }
        #expect(back == plain)
        let header = try ContentsCrypto.parseHeader(good).bytes.count
        let whole = ContentsCrypto.chunkSize + ContentsCrypto.tagLength
        let cases: [(String, Data)] = [
            ("cut at a chunk boundary", good.prefix(header + 3 * whole)),
            ("cut to its first chunk", good.prefix(header + whole)),
            ("cut mid-chunk", good.prefix(good.count - 500)),
            ("run on", good + Data([1, 2, 3])),
            ("run on by a chunk", good + good.suffix(whole)),
            ("reordered", good.prefix(header) + good.dropFirst(header + whole).prefix(whole) + good.dropFirst(header).prefix(whole)
                + good.dropFirst(header + 2 * whole)),
            ("byte flipped", { var d = good; d[header + whole + 7] ^= 1; return d }()),
            ("tag flipped", { var d = good; d[d.count - 1] ^= 1; return d }()),
            ("library changed", { var d = good; let r = d.range(of: Data("lib-1".utf8))!; d.replaceSubrange(r, with: Data("lib-2".utf8)); return d }()),
        ]
        for (what, d) in cases {
            guard case .failure = opens(d) else { Issue.record("\(what): it opened"); continue }
        }
        // a whole file whose header names another version opens to nothing
        var wrongVersion = good
        let r = wrongVersion.range(of: Data(stamp.utf8))!
        wrongVersion.replaceSubrange(r, with: Data("2026-10-02-120000".utf8))
        guard case .failure = opens(wrongVersion) else { Issue.record("another version's header opened"); return }
        // and a key derived for another job doesn't open it
        #expect(throws: ContentsCrypto.Failure.wrongPassphrase) {
            try ContentsCrypto.open(good, master: { _ in [master(job: "JOB-2")] }) { _ in true }
        }
        #expect(throws: ContentsCrypto.Failure.damaged) {
            try ContentsCrypto.open(good.prefix(header + whole), master: { _ in [master()] }) { _ in true }
        }
    }

    // A reader takes only the KDF, iteration count and chunk size Cryoframe writes,
    // and only the job's own KDF salt: a file can't ask for a cheaper derivation.
    @Test func aReaderAcceptsOnlyOurKeyDerivation() throws {
        let b = ContentsCrypto.Binding(jobID: "JOB-1", libraryID: "lib-1", version: stamp)
        let base = folder("kdf")
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("l")
        try ContentsCrypto.seal(Data("x".utf8), binding: b, master: master(), to: url)
        let good = try Data(contentsOf: url)
        let m = ContentsCrypto.magic.count
        func patched(_ at: Int, _ bytes: [UInt8]) -> Data { var d = good; d.replaceSubrange(at ..< at + bytes.count, with: bytes); return d }
        let variants = [
            patched(m, [2]),                                          // another KDF
            patched(m + 1, ContentsCrypto.be32(600_000)),             // fewer iterations
            patched(m + 1, ContentsCrypto.be32(1)),
            patched(m + 5, [UInt8](repeating: 7, count: 32)),         // a salt not the job's
            patched(m + 5 + 64, ContentsCrypto.be32(16)),             // another chunk size
            patched(0, Array("CRYOKEYS1".utf8)),                      // the escrow file's magic
        ]
        for v in variants {
            #expect(throws: ContentsCrypto.Failure.unsupported) { try ContentsCrypto.open(v, master: { _ in [master()] }) { _ in true } }
        }
        #expect(ContentsCrypto.iterations == 1_000_000)
    }

    // On a Mac with no job, the list says whose it is: the job ID comes from its
    // (authenticated) header, and a typed passphrase opens it.
    @Test func aListIsReadOnAMacWithNoJob() throws {
        let base = folder("nojob")
        defer { try? FileManager.default.removeItem(at: base) }
        var a = try version(base, entries: [("photo.heic", .file)], job: "NEWMAC-JOB", pass: "typed")
        a.libraryKey = nil                                  // no identity to compare with
        let data = try Data(contentsOf: a.dir.appendingPathComponent(ContentsListing.encryptedName))
        #expect(ContentsCrypto.claimedBinding(data)?.jobID == "NEWMAC-JOB")
        var asked: [String] = []
        let r = ContentsSearch(keyring: keyring).search(ContentsQuery("photo")!, in: a, passphrases: { asked.append($0); return ["typed"] })
        #expect(r?.hits.count == 1 && asked.contains("NEWMAC-JOB"))
    }

    // MARK: the manifest, and what reads it

    // The list's digest is its own field: discovery's bytes and artifacts, the
    // checksum check, and a 1.5.6-shaped reader see only the archive.
    @Test func theManifestKeepsTheListApartFromTheArchive() throws {
        let base = folder("manifest")
        defer { try? FileManager.default.removeItem(at: base) }
        let src = base.appendingPathComponent("Docs.bundle")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: src.appendingPathComponent("a.txt"))
        let built = try SealedArchiveEngine(.zip).archive(ArchiveSource(name: src.lastPathComponent, root: src), to: base.appendingPathComponent("build"))
        let c = ContentsListing.Collector(binding: .init(jobID: "J", libraryID: "docs", version: stamp))
        _ = JobExecutor.directoryStats(src, forZip: true, listing: c)
        let staged = try #require(ContentsListing.write(c, master: nil, encrypted: false, into: base.appendingPathComponent("build")))
        let dest = base.appendingPathComponent("dest/Docs/\(stamp)")
        let result = try SealedArchiveEngine(.zip).distribute(builtFile: built.artifacts[0], into: dest, encrypted: false, contents: staged)
        let manifestURL = dest.appendingPathComponent(ArchiveManifest.sidecarName)
        let m = try ArchiveManifest.read(manifestURL)
        #expect(m.contents == staged.digest)
        #expect(m.artifacts.map(\.name) == result.artifacts.map(\.lastPathComponent) && !m.artifacts.contains { ContentsListing.names.contains($0.name) })
        #expect(try ChecksumVerifier().reverify(archiveDir: dest).passed)
        let a = try #require(RestoreDiscovery.archive(at: dest))
        #expect(a.contents == staged.digest && a.artifactNames == m.artifacts.map(\.name))
        #expect(a.bytes == m.artifacts.reduce(0) { $0 + $1.size })
        #expect(search("a.txt", a)?.hits.count == 1)

        // 1.5.6's manifest type: synthesized Codable over these four fields
        struct Manifest156: Codable { let format: ArchiveFormat; let artifacts: [ArtifactDigest]; var encrypted: Bool?; var sealedBands: String? }
        let old = try JSONDecoder().decode(Manifest156.self, from: Data(contentsOf: manifestURL))
        #expect(old.artifacts.map(\.name) == m.artifacts.map(\.name))
        // and a manifest 1.5.6 wrote reads here with no list
        let written156 = try JSONEncoder().encode(Manifest156(format: .sealedZip, artifacts: m.artifacts, encrypted: nil, sealedBands: nil))
        #expect(try JSONDecoder().decode(VerificationManifest.self, from: written156).contents == nil)
        // a list record this version can't read leaves the manifest readable
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        json["contents"] = ["name": 5]
        let odd = try JSONDecoder().decode(VerificationManifest.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(odd.contents == nil && odd.artifacts.count == m.artifacts.count)
    }

    // A staged list that isn't the one recorded (a later run made its own at the same
    // path) isn't copied, and the manifest names none.
    @Test func aStagedListThatChangedIsNotCopied() throws {
        let base = folder("place")
        defer { try? FileManager.default.removeItem(at: base) }
        let c = ContentsListing.Collector(binding: .init(jobID: "J", libraryID: "l", version: stamp))
        c.add("a.txt", size: 1, modified: nil, kind: .file)
        let staged = try #require(ContentsListing.write(c, master: nil, encrypted: false, into: base))
        let dest = base.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        #expect(ContentsListing.place(staged, into: dest) == staged.digest)
        try Data("rebuilt".utf8).write(to: staged.url)
        #expect(ContentsListing.place(staged, into: dest) == nil)
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent(ContentsListing.plainName).path))
    }

    // A resumable transfer carries the list's digest from when it began: a resume
    // after the staged list was made again writes the manifest without one.
    @Test func aResumedTransferShipsItsListOnlyIfItIsUnchanged() throws {
        let base = folder("resume")
        defer { try? FileManager.default.removeItem(at: base) }
        let stage = base.appendingPathComponent("stage")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let artifact = stage.appendingPathComponent("Docs.zip")
        try Data(repeating: 7, count: 3000).write(to: artifact)
        let c = ContentsListing.Collector(binding: .init(jobID: "J", libraryID: "l", version: stamp))
        c.add("a.txt", size: 1, modified: nil, kind: .file)
        let staged = try #require(ContentsListing.write(c, master: nil, encrypted: false, into: stage))
        func pending(_ target: URL) -> PendingTransfer {
            var p = PendingTransfer(jobID: "J:d:l", sourceFile: artifact.path, baseName: "Docs.zip", totalBytes: 3000,
                                    chunkSize: 1000, targetDir: target.path, format: .sealedZip)
            p.contents = staged.digest
            return p
        }
        // it survives the record being saved and read back
        let store = PendingTransferStore(url: base.appendingPathComponent("pending.json"))
        store.save(pending(base.appendingPathComponent("t0")))
        #expect(store.all().first?.contents == staged.digest)

        let t1 = base.appendingPathComponent("t1")
        let m1 = try ChunkedShipper().ship(pending(t1), persist: { _ in })
        #expect(m1.contents == staged.digest)
        #expect(FileManager.default.fileExists(atPath: t1.appendingPathComponent(ContentsListing.plainName).path))

        // the next run made its own list at the same path
        let c2 = ContentsListing.Collector(binding: .init(jobID: "J", libraryID: "l", version: "2026-10-02-120000"))
        c2.add("b.txt", size: 1, modified: nil, kind: .file)
        _ = try #require(ContentsListing.write(c2, master: nil, encrypted: false, into: stage))
        let t2 = base.appendingPathComponent("t2")
        let m2 = try ChunkedShipper().ship(pending(t2), persist: { _ in })
        #expect(m2.contents == nil)
        #expect(!FileManager.default.fileExists(atPath: t2.appendingPathComponent(ContentsListing.plainName).path))
        #expect(try ArchiveManifest.read(t2.appendingPathComponent(ArchiveManifest.sidecarName)).contents == nil)
    }

    // A version in a cloud folder whose list alone is evicted is still on this Mac:
    // the check reads it, not "not downloaded, skipped".
    @Test func anEvictedListAloneDoesntSkipTheVersion() throws {
        let base = folder("evicted")
        defer { try? FileManager.default.removeItem(at: base) }
        let lib = base.appendingPathComponent("Docs.bundle")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: lib.appendingPathComponent("a.txt"))
        let target = base.appendingPathComponent("cloud")
        let dir = target.appendingPathComponent("Docs/\(stamp)")
        let built = try SealedArchiveEngine(.zip).archive(ArchiveSource(name: lib.lastPathComponent, root: lib), to: dir)
        // a hollow list beside it: 2 MB long, nothing on disk
        let list = dir.appendingPathComponent(ContentsListing.plainName)
        FileManager.default.createFile(atPath: list.path, contents: nil)
        let fh = try FileHandle(forWritingTo: list); try fh.truncate(atOffset: 2_000_000); try fh.close()
        #expect(CloudFile.isDataless(list))
        try ArchiveManifest.write(ArchiveManifest.build(for: built, contents: ContentsDigest(name: ContentsListing.plainName, size: 2_000_000,
                                                                                             sha256: "00", entries: 1, partial: false)), toDir: dir)
        let type = ContentType.genericFolder(id: "docs", displayName: "Docs", path: .absolute(lib.path))
        let job = BackupJob(name: "J", libraries: [type], target: .cloudSyncFolder(id: "c", name: "Box", dir: target, provider: .box),
                            format: .sealedZip, frequency: .manual, createdAt: Date(timeIntervalSince1970: 0))
        let report = HealthChecker().check(job: job, materializeCloud: false)
        #expect(report.checks.count == 1 && report.checks.first?.skipped == false && report.passed, "\(report.checks.map(\.detail))")
        let drill = RestoreDriller().drill(job: job)
        #expect(drill.checks.first?.skipped == false && drill.passed, "\(drill.checks.map(\.detail))")
        let a = try #require(RestoreDiscovery.archive(at: dir))
        #expect(!CloudFile.anyDataless(of: a))
    }

    // MARK: a run

    // A sealed run writes the list beside the archive, before the manifest that names
    // it; a library read live (not from a snapshot) gets a list that can't say what
    // isn't there. The hit opens at the item inside the archive. An encrypted run's
    // list is sealed, and no plaintext list is left anywhere.
    @Test(arguments: [(FormatChoice.sealedZip, false), (.sealedDMG, true)])
    func aSealedRunWritesItsList(_ format: FormatChoice, _ encrypted: Bool) async throws {
        let base = folder("run")
        defer { try? FileManager.default.removeItem(at: base) }
        // on a non-APFS volume, so the run reads it where it is (the fake helper can't snapshot)
        let mnt = base.appendingPathComponent("vol")
        try FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)
        let made = try ProcessCommandRunner().run("/usr/bin/hdiutil", ["create", "-size", "20m", "-fs", "HFS+", "-volname", "Src",
                                                                       base.appendingPathComponent("src.dmg").path])
        try #require(made.ok, "\(made.stderr)")
        let attached = try DiskImageGate.serialized {
            try ProcessCommandRunner().runRetryingBusy("/usr/bin/hdiutil", ["attach", base.appendingPathComponent("src.dmg").path,
                                                                            "-mountpoint", mnt.path, "-nobrowse", "-owners", "on"])
        }
        try #require(attached.ok && MountPoint.isMounted(mnt), "\(attached.stderr)")
        defer { MountPoint.detach(mnt, runner: ProcessCommandRunner()) }
        let lib = mnt.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: lib.appendingPathComponent("Taxes/2024"), withIntermediateDirectories: true)
        try Data("w2".utf8).write(to: lib.appendingPathComponent("Taxes/2024/W-2 form.pdf"))
        try Data("n".utf8).write(to: lib.appendingPathComponent("notes.txt"))
        let bound = try ProcessCommandRunner().run("/bin/sh", ["-c", "cd '\(lib.path)' && /usr/bin/python3 -c \"import socket; socket.socket(socket.AF_UNIX).bind('agent.sock')\""])
        try #require(bound.ok, "\(bound.stderr)")
        let dest = base.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let projects = ContentType.genericFolder(id: "projects", displayName: "Projects", path: .absolute(lib.path))
        let job = BackupJob(name: "Projects", libraries: [projects], target: .localVolume(id: "d", name: "Dest", dir: dest),
                            format: format, frequency: .manual, encrypted: encrypted, createdAt: Date(timeIntervalSince1970: 0))
        let scratch = base.appendingPathComponent("scratch")
        let exec = JobExecutor(helper: FakePrivilegedHelper(), detector: FakeProcessDetector(), scratchBase: scratch,
                               passphraseProvider: { _ in encrypted ? "pw" : nil })
        let outcome = try await exec.run(job, ownerUID: getuid(), now: Date(), control: RunControl(quietLimit: 20))
        guard case .finished(let results, _) = outcome, case .completed? = results.first else {
            Issue.record("expected a completed library, got \(outcome)"); return
        }
        let a = try #require(RestoreDiscovery.scan(dest).first)
        let digest = try #require(a.contents)
        #expect(digest.name == (encrypted ? ContentsListing.encryptedName : ContentsListing.plainName))
        #expect(digest.partial, "a live read can't promise what isn't there")
        #expect(digest.entries == 4, "folders, files, no socket: \(digest.entries)")
        // the binding is the version folder the run chose
        let listData = try Data(contentsOf: a.dir.appendingPathComponent(digest.name))
        if encrypted { #expect(ContentsCrypto.claimedBinding(listData)?.version == a.dir.lastPathComponent) }
        let leftovers = FileManager.default.enumerator(atPath: base.path)?.compactMap { $0 as? String }
            .filter { $0.hasSuffix(ContentsListing.plainName) } ?? []
        #expect(encrypted ? leftovers.isEmpty : leftovers.count == 1, "\(leftovers)")

        let hit = try #require(ContentsSearch(keyring: keyring).search(ContentsQuery("w-2")!, in: a, passphrases: { _ in ["pw"] }))
        #expect(hit.hits.map(\.path) == ["Taxes/2024/W-2 form.pdf"], "\(hit.answer)")
        let miss = try #require(ContentsSearch(keyring: keyring).search(ContentsQuery("agent.sock")!, in: a, passphrases: { _ in ["pw"] }))
        #expect(!miss.isNotInVersion && miss.hits.isEmpty)

        // macOS itself briefly attaches a fresh image: wait it out
        let until = Date().addingTimeInterval(60)
        var openedArchive: OpenedArchive?
        while openedArchive == nil {
            do { openedArchive = try ArchiveReader().open(a.archiveResult(), passphrase: encrypted ? "pw" : nil) }
            catch let e as DiskImageInUse where e.attachedWithoutMount && Date() < until { try await Task.sleep(nanoseconds: 1_000_000_000) }
        }
        let opened = try #require(openedArchive)
        defer { opened.close() }
        let item = ArchiveLayout.item(hit.hits[0].path, in: opened.root, for: a)
        #expect(try String(contentsOf: item, encoding: .utf8) == "w2")
        // the browser opens in the item's folder, with the item as it lists it
        let at = try #require(ArchiveLayout.opening(at: item, under: opened.root))
        #expect(at.folders.last?.lastPathComponent == "2024" && at.name == "W-2 form.pdf")
        #expect(at.folders.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        let listed = try FileManager.default.contentsOfDirectory(at: try #require(at.folders.last), includingPropertiesForKeys: nil)
        #expect(listed.map(\.lastPathComponent).contains(at.name), "\(listed.map(\.path)) vs \(at.name)")
        #expect(ArchiveLayout.opening(at: URL(fileURLWithPath: "/elsewhere/x"), under: opened.root) == nil)
    }

    // MARK: wording

    // The summary never says a file isn't there while a version that could hold it
    // went unread.
    @Test func theSummaryNeverSaysNotFoundOverAnUnreadVersion() {
        func r(_ answer: VersionSearchResult.Answer, _ v: String) -> VersionSearchResult {
            VersionSearchResult(archive: RestorableArchive(dir: URL(fileURLWithPath: "/x/\(v)"), libraryName: "L", format: .sealedZip,
                                                           bytes: 1, artifactNames: ["L.zip"]), answer: answer)
        }
        let clear = r(.listed(hits: [], more: false, partial: false), "a")
        let none = r(.noList(.notRecorded), "b")
        let found = r(.listed(hits: [ContentsEntry(path: "x", size: 1, modified: 0, kind: .file)], more: false, partial: false), "c")
        #expect(ContentsSearch.summary([clear, clear], of: 2) == "Not in any of the 2 versions.")
        let mixed = ContentsSearch.summary([clear, none], of: 2)
        #expect(!mixed.contains("Not in any") && mixed.contains("1 version with a complete file list") && mixed.contains("Look inside"), "\(mixed)")
        #expect(ContentsSearch.summary([none], of: 1).contains("may still hold it"))
        #expect(ContentsSearch.summary([found, none], of: 2).hasPrefix("Found in 1 version."))
        let stopped = ContentsSearch.summary([clear], of: 3, stopped: true)
        #expect(!stopped.contains("Not in any") && stopped.contains("Stopped before 2 versions"), "\(stopped)")
    }
}
