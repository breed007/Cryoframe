//
//  UnlistableFolderRemovalTests.swift
//  CryoframeKitTests
//
//  What Cryoframe removes of its own (a copy's staging, a filtered copy in scratch, a
//  restore's staging, a day of Removed items) may hold a folder its owner can't list:
//  rsync keeps a library folder's mode, 000 included. Made writable but still not
//  listable, it couldn't be removed, and every later run stopped on it.
//

import Testing
import Foundation
@testable import CryoframeKit

private func tempDir(_ tag: String) -> URL {
    let d = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        .appendingPathComponent("cf-unlistable-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// a tree holding a folder of mode 000 (one inside another, too) and a read-only one
private func closedTree(at root: URL) throws {
    let fm = FileManager.default
    for dir in ["closed", "nested/inner", "ro"] {
        try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
    }
    for file in ["top.txt", "closed/a.txt", "nested/inner/b.txt", "ro/c.txt"] {
        try Data(file.utf8).write(to: root.appendingPathComponent(file))
    }
    for (dir, mode) in [("closed", 0o000), ("nested/inner", 0o000), ("nested", 0o000), ("ro", 0o500)] as [(String, mode_t)] {
        #expect(chmod(root.appendingPathComponent(dir).path, mode) == 0)
    }
}

private func unlock(_ base: URL) {
    _ = try? ProcessCommandRunner().run("/bin/chmod", ["-R", "u+rwX", base.path], stdin: nil)
}

@Suite(.serialized) struct UnlistableFolderRemovalTests {

    @Test func aCopysStagingWithAnUnlistableFolderIsRemoved() throws {
        let base = tempDir("staging")
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        let staging = base.appendingPathComponent(".cryoframe-staging")
        try closedTree(at: staging.appendingPathComponent("Lib"))
        MirrorCopy.removeStaging(staging, runner: ProcessCommandRunner())
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    @Test func aFilteredCopyWithAnUnlistableFolderIsRemoved() throws {
        let base = tempDir("filtered")
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent(FilteredCopy.folderName)
        try closedTree(at: folder.appendingPathComponent("Lib"))
        FilteredCopy.remove(in: base, runner: ProcessCommandRunner())
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func aRestoresStagingWithAnUnlistableFolderIsRemoved() throws {
        let base = tempDir("restore")
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        let dir = base.appendingPathComponent("staged")
        try closedTree(at: dir.appendingPathComponent("Lib"))
        RestoreStaging.remove(dir)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func aDayOfRemovedItemsWithAnUnlistableFolderIsDeleted() throws {
        let base = tempDir("removed")
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        let removed = base.appendingPathComponent(PlainCopyLayout.removedFolder)
        let day = removed.appendingPathComponent("2026-10-01")
        try closedTree(at: day.appendingPathComponent("Lib"))
        let out = RemovedItems.delete(in: removed, before: nil)
        #expect(out.deleted == 1 && out.failed.isEmpty, "\(out)")
        #expect(!FileManager.default.fileExists(atPath: day.path))
    }

    // Wes's case on a Mac drive: a run that met a library folder of mode 000 fails, and
    // once the folder is put right, the next run goes through instead of stopping on
    // what the first left beside the copy.
    @Test func aPlainCopyRunsAgainOnceAnUnreadableFolderIsPutRight() throws {
        let base = tempDir("apfs")
        defer { unlock(base); try? FileManager.default.removeItem(at: base) }
        let lib = base.appendingPathComponent("Lib"), dest = base.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: lib.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("top".utf8).write(to: lib.appendingPathComponent("top.txt"))
        try Data("a".utf8).write(to: lib.appendingPathComponent("sub/a.txt"))
        let copier = PlainCopy(profile: FileSystemProfile.make(fsType: "apfs"), runner: ProcessCommandRunner(),
                               companions: false, accepts: { _ in true },
                               probe: { _ in DriveAllocation(allocationUnit: 4096, companion: false) })
        _ = try copier.run(lib, in: dest)
        #expect(chmod(lib.appendingPathComponent("sub").path, 0o000) == 0)
        #expect(throws: (any Error).self) { _ = try copier.run(lib, in: dest) }
        #expect(chmod(lib.appendingPathComponent("sub").path, 0o755) == 0)
        try Data("b".utf8).write(to: lib.appendingPathComponent("sub/b.txt"))
        _ = try copier.run(lib, in: dest)
        #expect((try? String(contentsOf: dest.appendingPathComponent("Lib/sub/b.txt"), encoding: .utf8)) == "b")
    }
}
