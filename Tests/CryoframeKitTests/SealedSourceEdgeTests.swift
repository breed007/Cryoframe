//
//  SealedSourceEdgeTests.swift
//  CryoframeKitTests
//
//  The walk before a sealed build, at its edges: what it must not flag in an
//  ordinary folder (links to places you can't read, a deny-delete list like the one
//  on ~/Documents, read-only git objects, private files of your own), what it must
//  flag even though the mode bits look fine (an access list that denies reading),
//  and a named pipe in the library, which neither hdiutil nor ditto can archive:
//  both open it, wait for a writer that never comes, and hang.
//
//  NEVER let a folder with an unreadable or foreign item reach a real hdiutil
//  create here: it puts a password dialog on the screen (see DMGSourceCheckTests).
//

import Testing
import Foundation
@testable import CryoframeKit

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-srcedge-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

private func unlock(_ dir: URL) {
    _ = try? ProcessCommandRunner().run("/bin/chmod", ["-R", "-N", dir.path])
    _ = try? ProcessCommandRunner().run("/bin/chmod", ["-R", "u+rwx", dir.path])
}

private func sh(_ cmd: String, in dir: URL) throws {
    let r = try ProcessCommandRunner().run("/bin/sh", ["-c", "cd '\(dir.path)' && \(cmd)"])
    try #require(r.ok, "\(cmd): \(r.stderr)")
}

@Suite(.serialized) struct SealedSourceEdgeTests {

    // What an ordinary folder of one's own holds: nothing here would stop hdiutil,
    // and the check must say nothing, or every sealed-DMG run of it fails for no reason.
    @Test func anOrdinaryFolderIsNotFlagged() throws {
        let lib = folder("ordinary")
        let elsewhere = folder("elsewhere")
        defer { unlock(lib); unlock(elsewhere); for d in [lib, elsewhere] { try? FileManager.default.removeItem(at: d) } }
        try sh("""
            mkdir -p Project/.git/objects/ab Private 'Name with spaces' && \
            echo x > Project/.git/objects/ab/cdef && chmod 444 Project/.git/objects/ab/cdef && \
            echo s > Private/secret.txt && chmod 600 Private/secret.txt && chmod 700 Private && \
            echo t > .DS_Store && echo q > downloaded.pdf && xattr -w com.apple.quarantine '0083;66f9a1b2;Safari;' downloaded.pdf && \
            echo n > 'Name with spaces/café résumé.txt' && ln 'Name with spaces/café résumé.txt' hardlink.txt && \
            chmod +a 'everyone deny delete' . && mkdir Empty && ln -s /nonexistent/place dangling && \
            ln -s Project/.git link-to-folder
            """, in: lib)
        // links to things this user can't read: the link is copied, not what it points at
        try sh("echo z > locked.txt && chmod 000 locked.txt && mkdir closed && chmod 000 closed", in: elsewhere)
        try sh("ln -s '\(elsewhere.path)/locked.txt' link-to-unreadable && ln -s '\(elsewhere.path)/closed' link-to-closed && ln -s /private/var/root link-to-root", in: lib)
        let found = JobExecutor.directoryStats(lib, forDMG: true).dmgBlockers
        #expect(found.isEmpty, "\(found.explanation(library: "Ordinary"))")
    }

    // Mode bits say readable; an access list says no. hdiutil is refused all the same.
    @Test func anAccessListThatDeniesReadingIsFlagged() throws {
        let lib = folder("acl")
        defer { unlock(lib); try? FileManager.default.removeItem(at: lib) }
        let me = NSUserName()
        try sh("echo x > denied.txt && chmod 644 denied.txt && chmod +a 'user:\(me) deny read' denied.txt", in: lib)
        try sh("mkdir Unlistable && echo y > Unlistable/in.txt && chmod +a 'user:\(me) deny list' Unlistable", in: lib)
        let found = JobExecutor.directoryStats(lib, forDMG: true).dmgBlockers
        #expect(found.counts[.unreadable] == 2, "\(found.counts) \(found.examples)")
        #expect(Set(found.examples[.unreadable] ?? []) == ["denied.txt", "Unlistable"])
    }

    // A named pipe in a sealed-DMG library: hdiutil create -srcfolder opens it and
    // waits for a writer forever (measured: 40 s, 0.02 s of CPU, until killed). The
    // watchdog now stops it after 15 minutes and blames a drive or share that stopped
    // responding, and every run of the job does the same. The pipe is in the library,
    // and the run should say so up front, as it does for the other things that stop
    // hdiutil.
    @Test func aNamedPipeInASealedDMGLibraryIsNamedUpFront() async throws {
        try await sealedRunNamesThePipe(.sealedDMG)
    }

    // The same for the sealed zip format: ditto -c -k hangs on the pipe the same way.
    @Test func aNamedPipeInASealedZipLibraryIsNamedUpFront() async throws {
        try await sealedRunNamesThePipe(.sealedZip)
    }

    private func sealedRunNamesThePipe(_ format: FormatChoice) async throws {
        let base = folder("pipe")
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        // the library on a non-APFS volume, so the run reads it where it is (the fake
        // helper can't snapshot); as in DMGSourceCheckTests
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
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: lib.appendingPathComponent("notes.txt"))
        try #require(mkfifo(lib.appendingPathComponent("build.pipe").path, 0o644) == 0)
        let dest = base.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let projects = ContentType.genericFolder(id: "projects", displayName: "Projects", path: .absolute(lib.path))
        let job = BackupJob(name: "Projects", libraries: [projects], target: .localVolume(id: "d", name: "Dest", dir: dest),
                            format: format, frequency: .manual, createdAt: Date(timeIntervalSince1970: 0))
        let exec = JobExecutor(helper: FakePrivilegedHelper(), detector: FakeProcessDetector(),
                               scratchBase: base.appendingPathComponent("scratch"))
        // a short quiet limit, so a hung tool is stopped in seconds rather than 15 minutes
        let control = RunControl(quietLimit: 3)
        let start = ProcessInfo.processInfo.systemUptime
        let outcome = try await exec.run(job, ownerUID: getuid(), now: Date(), control: control)
        #expect(ProcessInfo.processInfo.systemUptime - start < 60)
        guard case .finished(let results, _) = outcome, case .failed(_, _, let why)? = results.first else {
            Issue.record("expected a failed library, got \(outcome)"); return
        }
        #expect(why.contains("build.pipe"), "the run didn't name the pipe: \(why)")
        #expect(!why.contains("made no progress"), "the run blamed a stalled tool, not the pipe: \(why)")
    }
}
