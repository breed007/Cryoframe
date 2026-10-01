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
    // waits for a writer forever (measured: 40 s, 0.02 s of CPU, until killed), and
    // refuses a socket. The run builds from a copy without them (see FilteredCopy),
    // says what it left out, and the version restores without them: plain, encrypted,
    // and as a zip (ditto -c -k hangs on the pipe the same way).
    @Test(arguments: [(FormatChoice.sealedDMG, false), (.sealedDMG, true), (.sealedZip, false)])
    func aSealedRunLeavesPipesAndSocketsOut(_ format: FormatChoice, _ encrypted: Bool) async throws {
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
        try sh("mkdir tools && ln notes.txt tools/notes-link.txt", in: lib)
        try #require(mkfifo(lib.appendingPathComponent("build.pipe").path, 0o644) == 0)
        let bound = try ProcessCommandRunner().run("/bin/sh", ["-c", "cd '\(lib.path)/tools' && /usr/bin/python3 -c \"import socket; socket.socket(socket.AF_UNIX).bind('agent.sock')\""])
        try #require(bound.ok, "couldn't make a socket: \(bound.stderr)")
        let dest = base.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let projects = ContentType.genericFolder(id: "projects", displayName: "Projects", path: .absolute(lib.path))
        let job = BackupJob(name: "Projects", libraries: [projects], target: .localVolume(id: "d", name: "Dest", dir: dest),
                            format: format, frequency: .manual, encrypted: encrypted, createdAt: Date(timeIntervalSince1970: 0))
        let scratch = base.appendingPathComponent("scratch")
        let exec = JobExecutor(helper: FakePrivilegedHelper(), detector: FakeProcessDetector(), scratchBase: scratch,
                               passphraseProvider: { _ in encrypted ? "pw" : nil })
        // a short quiet limit, so a hung tool is stopped in seconds rather than 15 minutes
        let control = RunControl(quietLimit: 3)
        let start = ProcessInfo.processInfo.systemUptime
        let outcome = try await exec.run(job, ownerUID: getuid(), now: Date(), control: control)
        #expect(ProcessInfo.processInfo.systemUptime - start < 60)
        guard case .finished(let results, let warning) = outcome, case .completed? = results.first else {
            Issue.record("expected a completed library, got \(outcome)"); return
        }
        let what = format == .sealedZip ? "the zip" : "the disk image"
        #expect(warning?.contains("Projects: left 2 named pipes, sockets or devices out of \(what) (") == true, "\(warning ?? "no warning")")
        #expect(warning?.contains("build.pipe") == true && warning?.contains("tools/agent.sock") == true, "\(warning ?? "no warning")")
        // the copy is gone from scratch once the archive is built
        let leftovers = (FileManager.default.enumerator(atPath: scratch.path)?.allObjects as? [String] ?? []).filter { $0.contains("filtered") }
        #expect(leftovers.isEmpty, "\(leftovers)")

        let archive = try #require(RestoreDiscovery.scan(dest, maxDepth: 4).first)
        let restored = try RestoreEngine().restore(archive, to: base.appendingPathComponent("restored"), passphrase: encrypted ? "pw" : nil)
        #expect(restored.lastPathComponent == "Projects")
        #expect(try String(contentsOf: restored.appendingPathComponent("notes.txt"), encoding: .utf8) == "notes")
        #expect(try String(contentsOf: restored.appendingPathComponent("tools/notes-link.txt"), encoding: .utf8) == "notes")
        #expect(!FileManager.default.fileExists(atPath: restored.appendingPathComponent("build.pipe").path))
        #expect(!FileManager.default.fileExists(atPath: restored.appendingPathComponent("tools/agent.sock").path))
    }

    // Stop while the copy is being made: the run is canceled, and the copy, which
    // holds a whole copy of the library, isn't left in scratch.
    @Test func stopWhileTheCopyIsMadeLeavesNoCopy() async throws {
        let base = folder("stop")
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        let mnt = base.appendingPathComponent("vol")
        try FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)
        let made = try ProcessCommandRunner().run("/usr/bin/hdiutil", ["create", "-size", "200m", "-fs", "HFS+", "-volname", "Src",
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
        // enough files that the copy takes a while
        try sh("for d in 1 2 3 4 5 6 7 8; do mkdir d$d; for f in $(seq 1 400); do echo $d$f > d$d/f$f; done; done", in: lib)
        try #require(mkfifo(lib.appendingPathComponent("build.pipe").path, 0o644) == 0)
        let dest = base.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let projects = ContentType.genericFolder(id: "projects", displayName: "Projects", path: .absolute(lib.path))
        let job = BackupJob(name: "Projects", libraries: [projects], target: .localVolume(id: "d", name: "Dest", dir: dest),
                            format: .sealedDMG, frequency: .manual, createdAt: Date(timeIntervalSince1970: 0))
        let scratch = base.appendingPathComponent("scratch")
        let exec = JobExecutor(helper: FakePrivilegedHelper(), detector: FakeProcessDetector(), scratchBase: scratch)
        let control = RunControl()
        let filtered = scratch.appendingPathComponent("\(job.id)/build/projects/filtered")
        let watcher = Task.detached {
            while !Task.isCancelled {
                if FileManager.default.fileExists(atPath: filtered.path) { control.cancel(); return true }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            return false
        }
        let outcome = try await exec.run(job, ownerUID: getuid(), now: Date(), control: control)
        watcher.cancel()
        try #require(await watcher.value, "the copy was never started")
        guard case .cancelled = outcome else { Issue.record("expected a canceled run, got \(outcome)"); return }
        #expect(!FileManager.default.fileExists(atPath: filtered.path), "the copy was left in scratch")
    }
}
