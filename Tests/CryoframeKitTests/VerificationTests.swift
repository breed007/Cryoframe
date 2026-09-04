//
//  VerificationTests.swift
//  CryoframeKitTests
//
//  Checksum + manifest (cheap / periodic mode) and real mount-and-open strong
//  verification against a tiny sqlite "library" fixture (no root needed).
//

import Testing
import Foundation
@testable import CryoframeKit

private func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-vrf-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// a minimal Photos-shaped library: database/Photos.sqlite, valid or corrupt.
private func makeLibraryFixture(valid: Bool) throws -> URL {
    let lib = tempDir()
    let dbDir = lib.appendingPathComponent("database")
    try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
    let db = dbDir.appendingPathComponent("Photos.sqlite")
    if valid {
        let r = try ProcessCommandRunner().run("/usr/bin/sqlite3",
            [db.path, "CREATE TABLE asset(id INTEGER PRIMARY KEY, name TEXT); INSERT INTO asset(name) VALUES('a'),('b');"])
        #expect(r.ok)
    } else {
        try Data([UInt8](repeating: 0xFF, count: 4096)).write(to: db)   // not a database
    }
    return lib
}

private let liveDBType = ContentType(id: "test.photos", displayName: "TestPhotos", paths: [],
                                     owningProcess: nil, kind: .liveDB, integrityProbe: "database/Photos.sqlite")

// MARK: - checksum + manifest

@Test func sha256MatchesKnownVector() throws {
    let f = tempDir().appendingPathComponent("abc.txt")
    try Data("abc".utf8).write(to: f)
    #expect(try Checksum.sha256(of: f) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
}

@Test func manifestRoundTripsAndVerifies() throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    try Data("hello".utf8).write(to: dir.appendingPathComponent("a.bin"))
    try Data("world".utf8).write(to: dir.appendingPathComponent("b.bin"))
    let result = ArchiveResult(artifacts: [dir.appendingPathComponent("a.bin"),
                                           dir.appendingPathComponent("b.bin")], format: .sealedZip)

    let manifest = try ArchiveManifest.build(for: result)
    #expect(manifest.artifacts.count == 2)
    let url = try ArchiveManifest.write(manifest, toDir: dir)
    #expect(try ArchiveManifest.read(url) == manifest)
    #expect(try ChecksumVerifier().verify(manifest, in: dir).passed)
    #expect(try ChecksumVerifier().reverify(archiveDir: dir).passed)        // sidecar path
}

@Test func checksumVerifyDetectsTamperAndMissing() throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let a = dir.appendingPathComponent("a.bin")
    try Data("hello".utf8).write(to: a)
    let manifest = try ArchiveManifest.build(for: ArchiveResult(artifacts: [a], format: .sealedZip))

    try Data("HELLO world".utf8).write(to: a)                              // tamper
    #expect(!(try ChecksumVerifier().verify(manifest, in: dir).passed))

    try FileManager.default.removeItem(at: a)                              // missing
    let rep = try ChecksumVerifier().verify(manifest, in: dir)
    #expect(!rep.passed)
    #expect(rep.failures.contains { $0.contains("missing") })
}

// MARK: - mount-and-open (real)

@Test func strongVerifyDMGReopensCleanLibrary() throws {
    let lib = try makeLibraryFixture(valid: true); defer { try? FileManager.default.removeItem(at: lib) }
    let out = tempDir(); defer { try? FileManager.default.removeItem(at: out) }
    let result = try SealedArchiveEngine(.dmg).archive(ArchiveSource(name: "Lib", root: lib), to: out)

    let rep = try StrongVerifier().verify(result, type: liveDBType)
    #expect(rep.level == .mountAndOpen)
    #expect(rep.passed)
}

@Test func strongVerifyDMGDetectsCorruptLibrary() throws {
    let lib = try makeLibraryFixture(valid: false); defer { try? FileManager.default.removeItem(at: lib) }
    let out = tempDir(); defer { try? FileManager.default.removeItem(at: out) }
    let result = try SealedArchiveEngine(.dmg).archive(ArchiveSource(name: "Lib", root: lib), to: out)

    let rep = try StrongVerifier().verify(result, type: liveDBType)
    #expect(!rep.passed)
}

@Test func strongVerifyZipFindsLibraryUnderKeepParent() throws {
    let lib = try makeLibraryFixture(valid: true); defer { try? FileManager.default.removeItem(at: lib) }
    let out = tempDir(); defer { try? FileManager.default.removeItem(at: out) }
    let result = try SealedArchiveEngine(.zip).archive(ArchiveSource(name: "Lib", root: lib), to: out)

    let rep = try StrongVerifier().verify(result, type: liveDBType)   // probe is one level down in a zip
    #expect(rep.passed)
}

@Test func strongVerifyStaticRootPassesWhenNonEmpty() throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    try Data("x".utf8).write(to: dir.appendingPathComponent("file.txt"))
    let out = tempDir(); defer { try? FileManager.default.removeItem(at: out) }
    let result = try SealedArchiveEngine(.dmg).archive(ArchiveSource(name: "Docs", root: dir), to: out)

    let staticType = ContentType.genericFolder(id: "d", displayName: "Docs", path: .home("Docs"))
    let rep = try StrongVerifier().verify(result, type: staticType)
    #expect(rep.passed)
    #expect(rep.details.contains("opened"), "the drill should say it opened the files, not that it counted them")
}

// A folder library has no database to reopen, so the drill used to count entries at
// the root and stop. That passed an archive holding a file nobody can read — and the
// version then wore a "Restore-tested" badge while the actual restore failed on
// exactly that file. The drill has to fail wherever the restore would.
@Test func aDrillFailsOnAFileTheRestoreCouldNotRead() throws {
    try #require(geteuid() != 0, "mode bits do not bind root; this test proves nothing there")
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    try Data("readable".utf8).write(to: dir.appendingPathComponent("fine.txt"))
    let locked = dir.appendingPathComponent("locked.txt")
    try Data("secret".utf8).write(to: locked)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }

    let out = tempDir(); defer { try? FileManager.default.removeItem(at: out) }
    let result = try SealedArchiveEngine(.dmg).archive(ArchiveSource(name: "Docs", root: dir), to: out)
    let staticType = ContentType.genericFolder(id: "d", displayName: "Docs", path: .home("Docs"))
    let rep = try StrongVerifier().verify(result, type: staticType)

    #expect(!rep.passed, "the drill passed an archive that cannot be restored")
    #expect(rep.details.contains("locked.txt"), "it should name the file: \(rep.details)")
}

// An empty archive is not a restorable one — RestoreEngine throws libraryNotFound —
// so the drill must not call it good.
@Test func aDrillFailsOnAnEmptyLibrary() throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let out = tempDir(); defer { try? FileManager.default.removeItem(at: out) }
    let result = try SealedArchiveEngine(.dmg).archive(ArchiveSource(name: "Empty", root: dir), to: out)
    let staticType = ContentType.genericFolder(id: "e", displayName: "Empty", path: .home("Empty"))
    let rep = try StrongVerifier().verify(result, type: staticType)
    #expect(!rep.passed)
    #expect(rep.details.contains("no files"), "\(rep.details)")
}

// MARK: - transient tool-error retry
//
// hdiutil reports a saturated diskimages-helper as "Resource temporarily
// unavailable", which the retry predicate used to miss — so a verification run
// under disk contention failed outright and reported a good archive as bad.

@Test func retriesTransientResourceUnavailable() throws {
    let attempts = Counter()
    let runner = ScriptedCommandRunner { _, _ in
        let n = attempts.bump()
        return n < 3
            ? CommandResult(status: 1, stdout: "", stderr: "hdiutil: attach failed - Resource temporarily unavailable")
            : CommandResult(status: 0, stdout: "ok", stderr: "")
    }
    let r = try runner.runRetryingBusy("/usr/bin/hdiutil", ["attach"])
    #expect(r.ok)
    #expect(attempts.value == 3)          // failed twice, succeeded on the third
}

@Test func doesNotRetryRealFailures() throws {
    let attempts = Counter()
    let runner = ScriptedCommandRunner { _, _ in
        _ = attempts.bump()
        return CommandResult(status: 1, stdout: "", stderr: "hdiutil: attach failed - no such file or directory")
    }
    let r = try runner.runRetryingBusy("/usr/bin/hdiutil", ["attach"])
    #expect(!r.ok)
    #expect(attempts.value == 1)          // a genuine error fails fast, no backoff
}

@Test func transientPredicateIsCaseInsensitive() {
    #expect(ScriptedCommandRunner.isTransient("Resource Temporarily Unavailable"))
    #expect(ScriptedCommandRunner.isTransient("hdiutil: attach failed - resource busy"))
    #expect(!ScriptedCommandRunner.isTransient("image not recognized"))
}

/// tiny thread-safe counter — the runner closure is @Sendable.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

// MARK: - cleaning up after a failed attach

/// records every command, and fails detaches the way a saturated disk-image
/// subsystem does: EAGAIN, until it has been asked enough times.
private final class BusyDetachRunner: CommandRunner, @unchecked Sendable {
    let lock = NSLock()
    var commands: [[String]] = []
    var detachAttempts = 0
    let succeedOnAttempt: Int
    let infoPlist: String
    init(succeedOnAttempt: Int, infoPlist: String) {
        self.succeedOnAttempt = succeedOnAttempt; self.infoPlist = infoPlist
    }
    func run(_ launchPath: String, _ args: [String], stdin: Data?) throws -> CommandResult {
        lock.lock(); defer { lock.unlock() }
        commands.append(args)
        if args.first == "info" { return CommandResult(status: 0, stdout: infoPlist, stderr: "") }
        if args.first == "detach" {
            detachAttempts += 1
            if detachAttempts < succeedOnAttempt {
                return CommandResult(status: 1, stdout: "",
                                     stderr: "hdiutil: detach failed - Resource temporarily unavailable")
            }
            return CommandResult(status: 0, stdout: "", stderr: "")
        }
        return CommandResult(status: 0, stdout: "", stderr: "")
    }
}

private func infoPlist(imagePath: String, devices: [String]) -> String {
    let entities = devices.map { "<dict><key>dev-entry</key><string>\($0)</string></dict>" }.joined()
    return """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict><key>images</key><array><dict>
    <key>image-path</key><string>\(imagePath)</string>
    <key>system-entities</key><array>\(entities)</array>
    </dict></array></dict></plist>
    """
}

// The orphan cleanup runs at the worst possible moment: right after an attach failed
// because the disk-image subsystem was saturated. A detach fired once into that same
// contention comes back EAGAIN too, and giving up there leaves the device behind —
// which is precisely what makes the next attach fail. The spiral is the cleanup's own
// fault, so the cleanup has to be as patient as the attach was.
@Test func aDetachThatComesBackBusyIsRetriedRatherThanAbandoned() {
    let image = URL(fileURLWithPath: "/tmp/orphan-test/Photos.dmg")
    let runner = BusyDetachRunner(succeedOnAttempt: 4,
                                  infoPlist: infoPlist(imagePath: image.path, devices: ["/dev/disk9"]))
    ArchiveReader.detachDevices(forImage: image, runner: runner)
    #expect(runner.detachAttempts >= 4, "gave up after \(runner.detachAttempts) attempt(s)")
}

@Test func everyDeviceOfAnOrphanedImageIsDetached() {
    // a failed attach leaves the whole-disk node AND its partitions; missing any of
    // them leaves the image attached, so the orphan survives the cleanup.
    let image = URL(fileURLWithPath: "/tmp/orphan-test/Lib.dmg")
    let runner = BusyDetachRunner(succeedOnAttempt: 1,
                                  infoPlist: infoPlist(imagePath: image.path,
                                                       devices: ["/dev/disk9s1", "/dev/disk9"]))
    ArchiveReader.detachDevices(forImage: image, runner: runner)
    let detached = runner.commands.filter { $0.first == "detach" }.compactMap { $0.dropFirst().first }
    #expect(Set(detached) == ["/dev/disk9", "/dev/disk9s1"])
    // whole-disk first: detaching it takes the partitions with it
    #expect(detached.first == "/dev/disk9")
}

// MARK: - 1.5.4: the folder-library drill, probed directly (no image needed)

private func staticFixture() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cf-static-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// A directory the walk cannot enter fails a restore exactly the way a file it
// cannot open does — the copy trips on it the same way. An enumerator skips such
// directories silently by default, which is the one class of false pass the
// 1.5.3 rewrite left open.
@Test func aDrillFailsOnAFolderItCannotEnter() throws {
    try #require(geteuid() != 0, "mode bits do not bind root; this test proves nothing there")
    let dir = try staticFixture(); defer { try? FileManager.default.removeItem(at: dir) }
    try Data("ok".utf8).write(to: dir.appendingPathComponent("fine.txt"))
    let sealed = dir.appendingPathComponent("sealed", isDirectory: true)
    try FileManager.default.createDirectory(at: sealed, withIntermediateDirectories: true)
    try Data("hidden".utf8).write(to: sealed.appendingPathComponent("inside.txt"))
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: sealed.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sealed.path) }

    let rep = StrongVerifier().staticReport(dir, fm: .default)
    #expect(!rep.passed, "passed a tree with a folder the restore cannot enter")
    #expect(rep.details.contains("sealed/"), "should name the folder: \(rep.details)")
}

// exactly `namedUnreadableLimit` failures used to say "and others" about none
@Test func theUnreadableListIsHonestAboutHowManyMoreThereAre() throws {
    try #require(geteuid() != 0)
    let dir = try staticFixture(); defer { try? FileManager.default.removeItem(at: dir) }
    let n = StrongVerifier.namedUnreadableLimit
    var locked: [URL] = []
    for i in 0..<n {
        let f = dir.appendingPathComponent("locked\(i).txt")
        try Data("x".utf8).write(to: f)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: f.path)
        locked.append(f)
    }
    defer { for f in locked { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.path) } }

    let rep = StrongVerifier().staticReport(dir, fm: .default)
    #expect(!rep.passed)
    #expect(!rep.details.contains("more"), "claimed more failures than there were: \(rep.details)")
}

// the executor and the drill must agree on what "empty" means: no files. Folders on
// their own are not a backup, and the drill must not bless an archive of them.
@Test func aFolderOnlyArchiveIsEmptyToTheDrillToo() throws {
    let dir = try staticFixture(); defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("a/b/c"), withIntermediateDirectories: true)
    let rep = StrongVerifier().staticReport(dir, fm: .default)
    #expect(!rep.passed)
    #expect(rep.details.contains("no files"), "\(rep.details)")
    #expect(JobExecutor.isEmptyTree(dir), "the executor disagrees with the drill about this tree")
}

// a sealed zip was fully extracted by ditto to get here; the probe is for mounts
@Test func aSealedZipDrillCountsWithoutProbing() throws {
    let dir = try staticFixture(); defer { try? FileManager.default.removeItem(at: dir) }
    try Data("x".utf8).write(to: dir.appendingPathComponent("f.txt"))
    let rep = StrongVerifier().staticReport(dir, fm: .default, probeReadability: false)
    #expect(rep.passed)
    #expect(rep.details.hasPrefix("found"), "\(rep.details)")
}
