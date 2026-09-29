//
//  DMGSourceCheckTests.swift
//  CryoframeKitTests
//
//  hdiutil create -srcfolder stops to ask for an administrator's password when the
//  folder holds an unreadable file, a file owned by another user, or a set-group-ID
//  file in a group the user isn't in. A sealed-DMG run finds those first and fails
//  naming them, instead of waiting on a prompt nobody will answer.
//
//  NEVER let one of these folders reach a real `hdiutil create`: it puts a password
//  dialog on the screen of whoever runs the tests, and the test waits on it.
//

import Testing
import Foundation
@testable import CryoframeKit

private let hdiutil = "/usr/bin/hdiutil"

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-dmgck-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// put permissions back so the folder can be removed
private func unlock(_ dir: URL) {
    _ = try? ProcessCommandRunner().run("/bin/chmod", ["-R", "u+rwx", dir.path])
}

@Suite(.serialized) struct DMGSourceCheckTests {

    @Test func unreadableFilesAndFoldersAreFound() throws {
        let lib = folder("unreadable")
        defer { unlock(lib); try? FileManager.default.removeItem(at: lib) }
        for i in 0..<8 { try Data("x".utf8).write(to: lib.appendingPathComponent("locked \(i).txt")) }
        try Data("fine".utf8).write(to: lib.appendingPathComponent("fine.txt"))
        let closed = lib.appendingPathComponent("Closed")
        try FileManager.default.createDirectory(at: closed, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: closed.appendingPathComponent("inside.txt"))
        for i in 0..<8 { chmod(lib.appendingPathComponent("locked \(i).txt").path, 0o200) }
        chmod(closed.path, 0o300)          // can enter, can't list

        let found = JobExecutor.directoryStats(lib, forDMG: true).dmgBlockers
        #expect(found.counts[.unreadable] == 9)
        #expect(found.examples[.unreadable]?.count == DMGBlockers.examplesKept)
        #expect(found.counts[.foreign] == nil && found.counts[.setgid] == nil)
        let text = found.explanation(library: "Notes")
        #expect(text.hasPrefix("Notes can't be sealed into a disk image unattended: the disk image tool would stop and wait for an administrator's password because of 9 items you can't read ("), "\(text)")
        #expect(text.contains(", …)"), "more than it names, and says so")
        #expect(text.hasSuffix("or move them out of the folder."), "zip can't read them either: \(text)")
        // a folder that isn't a sealed DMG's source isn't looked at
        #expect(JobExecutor.directoryStats(lib).dmgBlockers.isEmpty)
    }

    // A set-group-ID file whose group the user isn't in. The user can only set the bit
    // in a group of their own, so the membership answer is stood in for.
    @Test func aSetGroupIDFileInAGroupTheUserIsNotInIsFound() throws {
        let lib = folder("sgid")
        defer { try? FileManager.default.removeItem(at: lib) }
        let file = lib.appendingPathComponent("tool")
        try Data("#!/bin/sh\n".utf8).write(to: file)
        #expect(chmod(file.path, 0o2755) == 0)
        var st = stat(); lstat(file.path, &st)
        try #require(st.st_mode & S_ISGID != 0, "couldn't set the bit, so this proves nothing")
        var notIn = DMGBlockers.Membership(known: [st.st_gid: false])
        var found = DMGBlockers()
        found.inspect(file.path, relative: "tool", groups: &notIn)
        #expect(found.counts[.setgid] == 1 && found.examples[.setgid] == ["tool"])
        #expect(found.explanation(library: "Tools").contains("or switch this job to the sealed zip format"))
        // in the group: nothing to ask about
        var member = DMGBlockers.Membership()
        var none = DMGBlockers()
        none.inspect(file.path, relative: "tool", groups: &member)
        #expect(none.isEmpty, "the user is in their own group")
        var groups = DMGBlockers.Membership()
        let inOwn = groups.contains(getegid())
        #expect(inOwn)
    }

    // Files owned by another user. Making one takes root, so this looks at a folder
    // of the system's own (read only, owned by root).
    @Test func filesOwnedByAnotherUserAreFound() throws {
        let system = URL(fileURLWithPath: "/usr/share/misc")
        var st = stat()
        try #require(lstat(system.path, &st) == 0 && st.st_uid == 0 && geteuid() != 0, "no root-owned folder to look at")
        let found = JobExecutor.directoryStats(system, forDMG: true).dmgBlockers
        #expect((found.counts[.foreign] ?? 0) > DMGBlockers.examplesKept)
        #expect(found.examples[.foreign]?.first == "misc", "the folder itself is copied too")
        let text = found.explanation(library: "Misc")
        #expect(text.contains("items owned by another user (misc, "), "\(text)")
        #expect(text.hasSuffix("or switch this job to the sealed zip format, which archives them without asking."), "\(text)")
    }

    // Through a whole sealed-DMG run: the library fails before hdiutil is started,
    // with the list, and the run moves on. (Never run without the check: see the top.)
    @Test func aSealedDMGRunFailsUpFrontNamingThem() async throws {
        let base = folder("run")
        // the library on a volume that isn't APFS, so the run reads it where it is
        // (no snapshot), as the fake helper can't make one
        let mnt = base.appendingPathComponent("vol")
        try FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)
        let made = try ProcessCommandRunner().run(hdiutil, ["create", "-size", "20m", "-fs", "HFS+", "-volname", "Src",
                                                            base.appendingPathComponent("src.dmg").path])
        try #require(made.ok, "\(made.stderr)")
        let attached = try DiskImageGate.serialized {
            try ProcessCommandRunner().runRetryingBusy(hdiutil, ["attach", base.appendingPathComponent("src.dmg").path,
                                                                 "-mountpoint", mnt.path, "-nobrowse", "-owners", "on"])
        }
        try #require(attached.ok && MountPoint.isMounted(mnt), "\(attached.stderr)")
        defer {
            unlock(mnt)
            MountPoint.detach(mnt, runner: ProcessCommandRunner())
            try? FileManager.default.removeItem(at: base)
        }
        let lib = mnt.appendingPathComponent("Papers")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: lib.appendingPathComponent("secret.txt"))
        chmod(lib.appendingPathComponent("secret.txt").path, 0o200)
        let dest = base.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let papers = ContentType.genericFolder(id: "papers", displayName: "Papers", path: .absolute(lib.path))
        let job = BackupJob(name: "Papers", libraries: [papers], target: .localVolume(id: "d", name: "Dest", dir: dest),
                            format: .sealedDMG, frequency: .manual, createdAt: Date(timeIntervalSince1970: 0))
        let exec = JobExecutor(helper: FakePrivilegedHelper(), detector: FakeProcessDetector(),
                               scratchBase: base.appendingPathComponent("scratch"))
        let start = ProcessInfo.processInfo.systemUptime
        let outcome = try await exec.run(job, ownerUID: getuid(), now: Date())
        #expect(ProcessInfo.processInfo.systemUptime - start < 60)
        guard case .finished(let results, _) = outcome, case .failed(_, _, let why)? = results.first else {
            Issue.record("expected a failed library, got \(outcome)"); return
        }
        #expect(why.contains("secret.txt") && why.contains("administrator's password"), "\(why)")
    }
}
