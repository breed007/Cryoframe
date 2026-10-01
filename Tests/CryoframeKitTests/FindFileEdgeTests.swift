//
//  FindFileEdgeTests.swift
//  CryoframeKitTests
//
//  Edge cases for Find a File (each sealed version's file list):
//
//    - a list's chunks swapped in from another list, its header edited, or the
//      list cut to its first chunk never opens, and never reads as a miss;
//    - two runs in the same second each keep a list bound to their own version,
//      and a version folder that turns up mid-run drops the list, not the run;
//    - an encrypted run leaves no file name in plaintext anywhere it writes;
//    - a resume whose staged list is gone names no list, and clears a stale one;
//    - a query pasted as the file's whole path isn't told "not in this version".
//

import Testing
import Foundation
import CryptoKit
@testable import CryoframeKit

private func edgeFolder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-ffe-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

private let edgeKeys = ContentsKeyring()
private let edgeStamp = "2026-10-01-120000"

/// a version folder holding only a list, and the archive record discovery would make of it
private func edgeVersion(_ base: URL, entries: [String], pass: String? = nil, job: String = "JOB-E", lib: String = "lib-e",
                         version: String = edgeStamp) throws -> RestorableArchive {
    let dir = base.appendingPathComponent("Library/\(version)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let c = ContentsListing.Collector(binding: .init(jobID: job, libraryID: lib, version: version))
    for p in entries { c.add(p, size: 10, modified: Date(timeIntervalSince1970: 1_700_000_000), kind: .file) }
    let staged = try #require(ContentsListing.write(c, master: pass.map { edgeKeys.master(jobID: job, passphrase: $0)! },
                                                    encrypted: pass != nil, into: dir))
    var a = RestorableArchive(dir: dir, libraryName: "Library", format: .sealedDMG, bytes: 1, artifactNames: ["Library.dmg"],
                              encrypted: pass != nil, version: VersionStamp.date(version),
                              libraryKey: LibraryIdentity.key(jobID: job, libraryID: lib))
    a.contents = staged.digest
    return a
}

/// make the manifest's record agree with the list as it is now, as someone who changes both would
private func agree(_ a: inout RestorableArchive) throws {
    let url = a.dir.appendingPathComponent(a.contents!.name)
    a.contents!.size = Checksum.byteSize(of: url)
    a.contents!.sha256 = try Checksum.digest(of: url)
}

private func edgeSearch(_ q: String, _ a: RestorableArchive, passes: [String] = []) -> VersionSearchResult? {
    ContentsSearch(keyring: edgeKeys).search(ContentsQuery(q)!, in: a, passphrases: { _ in passes })
}

/// names random enough that the gzip'd list runs past one sealed chunk
private func manyNames(_ n: Int) -> [String] {
    (0..<n).map { "Photos/\($0 % 97)/\(UUID().uuidString)-\(UUID().uuidString).jpg" }
}

/// a 20 MB HFS+ image mounted at `base`/vol, so a run reads it live (the fake helper can't snapshot)
private func hfsSource(_ base: URL) throws -> URL {
    let mnt = base.appendingPathComponent("vol")
    try FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)
    let image = base.appendingPathComponent("src.dmg")
    let made = try ProcessCommandRunner().run("/usr/bin/hdiutil", ["create", "-size", "20m", "-fs", "HFS+", "-volname", "Src", image.path])
    try #require(made.ok, "\(made.stderr)")
    let attached = try DiskImageGate.serialized {
        try ProcessCommandRunner().runRetryingBusy("/usr/bin/hdiutil", ["attach", image.path, "-mountpoint", mnt.path,
                                                                        "-nobrowse", "-owners", "on"])
    }
    try #require(attached.ok && MountPoint.isMounted(mnt), "\(attached.stderr)")
    return mnt
}

private func projectsJob(_ lib: URL, dest: URL, format: FormatChoice, encrypted: Bool) -> BackupJob {
    let projects = ContentType.genericFolder(id: "projects", displayName: "Projects", path: .absolute(lib.path))
    return BackupJob(name: "Projects", libraries: [projects], target: .localVolume(id: "d", name: "Dest", dir: dest),
                     format: format, frequency: .manual, encrypted: encrypted, createdAt: Date(timeIntervalSince1970: 0))
}

@Suite(.serialized) struct FindFileEdgeTests {

    // MARK: crypto

    // A chunk from another list of the same job, under the same passphrase, is
    // damage: the first chunk opens, so the passphrase is known good. A first chunk
    // swapped in can't be told from a wrong passphrase (no key check value), but it
    // must still never read as a list, or as a miss.
    @Test func aChunkSwappedInFromAnotherListNeverOpens() throws {
        let base = edgeFolder("swap")
        defer { try? FileManager.default.removeItem(at: base) }
        let b = ContentsCrypto.Binding(jobID: "JOB-E", libraryID: "lib-e", version: edgeStamp)
        let key = edgeKeys.master(jobID: "JOB-E", passphrase: "pw")!
        var plain = Data(count: 2 * ContentsCrypto.chunkSize + 77)
        for i in plain.indices { plain[i] = UInt8(truncatingIfNeeded: i &* 13) }
        let u1 = base.appendingPathComponent("one"), u2 = base.appendingPathComponent("two")
        try ContentsCrypto.seal(plain, binding: b, master: key, to: u1)
        try ContentsCrypto.seal(plain, binding: b, master: key, to: u2)
        let one = try Data(contentsOf: u1), two = try Data(contentsOf: u2)
        let header = try ContentsCrypto.parseHeader(one).bytes.count
        let whole = ContentsCrypto.chunkSize + ContentsCrypto.tagLength
        func swapped(_ i: Int) -> Data {
            var d = one
            let r = (header + i * whole) ..< (header + (i + 1) * whole)
            d.replaceSubrange(r, with: two[r])
            return d
        }
        func outcome(_ d: Data) -> String {
            do { try ContentsCrypto.open(d, master: { _ in [key] }) { _ in true }; return "opened" }
            catch { return "\(error)" }
        }
        #expect(outcome(one) == "opened")
        #expect(outcome(swapped(1)) == "damaged", "a later chunk from another list")
        let first = outcome(swapped(0))
        #expect(first != "opened", "a first chunk from another list: \(first)")
    }

    // A header edited to name another version, then the manifest made to agree:
    // never read, never a miss, and never "another backup's" with the list's own
    // items handed over.
    @Test func aHeaderEditedToAnotherVersionNeverReads() throws {
        let base = edgeFolder("header")
        defer { try? FileManager.default.removeItem(at: base) }
        var a = try edgeVersion(base, entries: ["Taxes/W-2.pdf"], pass: "pw")
        let url = a.dir.appendingPathComponent(a.contents!.name)
        var d = try Data(contentsOf: url)
        let r = try #require(d.range(of: Data(edgeStamp.utf8)))
        d.replaceSubrange(r, with: Data("2026-10-01-120001".utf8))
        try d.write(to: url)
        try agree(&a)
        let res = try #require(edgeSearch("w-2", a, passes: ["pw"]))
        #expect(!res.isNotInVersion && res.hits.isEmpty, "\(res.answer)")
        guard case .noList = res.answer else { Issue.record("read as a list: \(res.answer)"); return }
    }

    // A real multi-chunk list cut to its first chunk, with the manifest made to
    // agree, reads "damaged" through the search, not "wrong passphrase"; the wrong
    // passphrase alone says so, none at all says locked, and the right one after a
    // wrong one (typed wrong, saved right) opens it.
    @Test func aListCutToItsFirstChunkIsDamagedNotAWrongPassphrase() throws {
        let base = edgeFolder("cut")
        defer { try? FileManager.default.removeItem(at: base) }
        let names = manyNames(60_000) + ["Taxes/W-2 form.pdf"]
        var a = try edgeVersion(base, entries: names, pass: "pw")
        let url = a.dir.appendingPathComponent(a.contents!.name)
        let good = try Data(contentsOf: url)
        let header = try ContentsCrypto.parseHeader(good).bytes.count
        let whole = ContentsCrypto.chunkSize + ContentsCrypto.tagLength
        try #require(good.count > header + whole, "the list must span chunks: \(good.count)")

        #expect(edgeSearch("w-2", a, passes: ["nope"])?.answer == .noList(.wrongPassphrase))
        #expect(edgeSearch("w-2", a, passes: [])?.answer == .noList(.locked))
        #expect(edgeSearch("w-2", a, passes: ["nope", "pw"])?.hits.map(\.path) == ["Taxes/W-2 form.pdf"])

        try good.prefix(header + whole).write(to: url)
        try agree(&a)
        #expect(edgeSearch("w-2", a, passes: ["pw"])?.answer == .noList(.damaged))
    }

    // MARK: the version's name

    // Two runs of a job in the same second: the second takes the next second, and
    // each version's list is bound to its own folder and reads back.
    @Test func twoRunsInTheSameSecondEachKeepTheirOwnList() async throws {
        let base = edgeFolder("samesec")
        defer { try? FileManager.default.removeItem(at: base) }
        let mnt = try hfsSource(base)
        defer { MountPoint.detach(mnt, runner: ProcessCommandRunner()) }
        let lib = mnt.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try Data("n".utf8).write(to: lib.appendingPathComponent("notes.txt"))
        let dest = base.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let job = projectsJob(lib, dest: dest, format: .sealedZip, encrypted: false)
        let exec = JobExecutor(helper: FakePrivilegedHelper(), detector: FakeProcessDetector(),
                               scratchBase: base.appendingPathComponent("scratch"), passphraseProvider: { _ in nil })
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        for _ in 0..<2 {
            let out = try await exec.run(job, ownerUID: getuid(), now: now, control: RunControl(quietLimit: 20))
            guard case .finished(let results, _) = out, case .completed? = results.first else {
                Issue.record("expected a completed run, got \(out)"); return
            }
        }
        let versions = RestoreDiscovery.scan(dest).sorted { $0.dir.lastPathComponent < $1.dir.lastPathComponent }
        #expect(versions.map(\.dir.lastPathComponent) == [VersionStamp.string(now), VersionStamp.string(now.addingTimeInterval(1))])
        for v in versions {
            let res = try #require(edgeSearch("notes", v))
            #expect(res.hits.map(\.path) == ["notes.txt"], "\(v.dir.lastPathComponent): \(res.answer)")
        }
    }

    // A folder of the planned version's name turns up while the run builds: the run
    // takes the next free name and copies no list (its list names the other); the
    // version has no list, and says so.
    @Test func aVersionFolderThatTurnsUpMidRunDropsOnlyTheList() async throws {
        let base = edgeFolder("midrun")
        defer { try? FileManager.default.removeItem(at: base) }
        let mnt = try hfsSource(base)
        defer { MountPoint.detach(mnt, runner: ProcessCommandRunner()) }
        let lib = mnt.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try Data("n".utf8).write(to: lib.appendingPathComponent("notes.txt"))
        let dest = base.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let job = projectsJob(lib, dest: dest, format: .sealedZip, encrypted: false)
        let exec = JobExecutor(helper: FakePrivilegedHelper(), detector: FakeProcessDetector(),
                               scratchBase: base.appendingPathComponent("scratch"), passphraseProvider: { _ in nil })
        let first = Date(timeIntervalSince1970: 1_790_000_000)
        _ = try await exec.run(job, ownerUID: getuid(), now: first, control: RunControl(quietLimit: 20))
        let libFolder = try #require(RestoreDiscovery.scan(dest).first?.dir.deletingLastPathComponent())
        let second = first.addingTimeInterval(100)
        let squatter = libFolder.appendingPathComponent(VersionStamp.string(second))
        let out = try await exec.run(job, ownerUID: getuid(), now: second, control: RunControl(quietLimit: 20), onStage: { stage in
            if stage == .archiving { try? FileManager.default.createDirectory(at: squatter, withIntermediateDirectories: true) }
        })
        guard case .finished(let results, _) = out, case .completed? = results.first else {
            Issue.record("expected a completed run, got \(out)"); return
        }
        let moved = libFolder.appendingPathComponent(VersionStamp.string(second.addingTimeInterval(1)))
        let v = try #require(RestoreDiscovery.archive(at: moved), "no version at \(moved.lastPathComponent)")
        #expect(v.contents == nil)
        for n in ContentsListing.names { #expect(!FileManager.default.fileExists(atPath: moved.appendingPathComponent(n).path)) }
        #expect(edgeSearch("notes", v)?.answer == .noList(.notRecorded))
    }

    // MARK: no plaintext

    // An encrypted run (a socket in the library, so the build reads a filtered
    // copy) leaves no file named like the library's anywhere it wrote, and no
    // file holding one of its names in the clear.
    @Test func anEncryptedRunLeavesNoNameInPlaintext() async throws {
        let base = edgeFolder("plaintext")
        defer { try? FileManager.default.removeItem(at: base) }
        let mnt = try hfsSource(base)
        defer { MountPoint.detach(mnt, runner: ProcessCommandRunner()) }
        let token = "Qz7TaxToken"
        let lib = mnt.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: lib.appendingPathComponent("\(token)-dir"), withIntermediateDirectories: true)
        try Data("w2".utf8).write(to: lib.appendingPathComponent("\(token)-dir/\(token)-file.pdf"))
        let bound = try ProcessCommandRunner().run("/bin/sh", ["-c", "cd '\(lib.path)' && /usr/bin/python3 -c \"import socket; socket.socket(socket.AF_UNIX).bind('agent.sock')\""])
        try #require(bound.ok, "\(bound.stderr)")
        let dest = base.appendingPathComponent("dest"), scratch = base.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let job = projectsJob(lib, dest: dest, format: .sealedDMG, encrypted: true)
        let exec = JobExecutor(helper: FakePrivilegedHelper(), detector: FakeProcessDetector(), scratchBase: scratch,
                               passphraseProvider: { _ in "pw" })
        let out = try await exec.run(job, ownerUID: getuid(), now: Date(), control: RunControl(quietLimit: 20))
        guard case .finished(let results, _) = out, case .completed? = results.first else {
            Issue.record("expected a completed run, got \(out)"); return
        }
        let a = try #require(RestoreDiscovery.scan(dest).first)
        #expect(a.contents?.name == ContentsListing.encryptedName)
        for top in [dest, scratch] {
            let named = try ProcessCommandRunner().run("/usr/bin/find", [top.path, "-name", "*\(token)*"])
            #expect(named.stdout.isEmpty, "named in the clear under \(top.lastPathComponent): \(named.stdout)")
            let held = try ProcessCommandRunner().run("/usr/bin/grep", ["-rl", "--binary-files=text", token, top.path])
            #expect(held.stdout.isEmpty, "held in the clear under \(top.lastPathComponent): \(held.stdout)")
        }
        let hit = try #require(edgeSearch(token, a, passes: ["pw"]))
        #expect(hit.hits.count == 2, "\(hit.answer)")
    }

    // MARK: resume

    // A resume whose staged list is gone (scratch swept) names no list, and clears a
    // list an earlier attempt left in the version folder.
    @Test func aResumeWhoseStagedListIsGoneNamesNoList() throws {
        let base = edgeFolder("resume")
        defer { try? FileManager.default.removeItem(at: base) }
        let stage = base.appendingPathComponent("stage"), target = base.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let artifact = stage.appendingPathComponent("Docs.zip")
        try Data(repeating: 7, count: 3000).write(to: artifact)
        let c = ContentsListing.Collector(binding: .init(jobID: "J", libraryID: "l", version: edgeStamp))
        c.add("a.txt", size: 1, modified: nil, kind: .file)
        let staged = try #require(ContentsListing.write(c, master: nil, encrypted: false, into: stage))
        try FileManager.default.copyItem(at: staged.url, to: target.appendingPathComponent(ContentsListing.plainName))
        try FileManager.default.removeItem(at: staged.url)
        var p = PendingTransfer(jobID: "J:d:l", sourceFile: artifact.path, baseName: "Docs.zip", totalBytes: 3000,
                                chunkSize: 1000, targetDir: target.path, format: .sealedZip)
        p.contents = staged.digest
        let m = try ChunkedShipper().ship(p, persist: { _ in })
        #expect(m.contents == nil)
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent(ContentsListing.plainName).path))
    }

    // MARK: the query

    // "Copy as Pathname" in Finder, pasted: the whole path of a file that IS in the
    // version. A whole list read must not answer "Not in this version".
    // KNOWN ISSUE (2026-10-01, de2982a): a query with a "/" is matched as a substring
    // of the path from the library's top, so the whole path never matches, and the
    // file that is there is called "Not in this version". Fixed: this fails; drop
    // the withKnownIssue.
    @Test func aPastedWholePathIsntCalledNotThere() throws {
        let base = edgeFolder("paste")
        defer { try? FileManager.default.removeItem(at: base) }
        let a = try edgeVersion(base, entries: ["Taxes/2024/W-2 form.pdf"])
        let res = try #require(edgeSearch("/Users/brian/Projects/Taxes/2024/W-2 form.pdf", a))
        withKnownIssue("a pasted whole path is called not there") {
            #expect(!res.isNotInVersion, "\(res.summary)")
            #expect(ContentsSearch.summary([res], of: 1) != "Not in the one version searched.")
        }
    }
}
