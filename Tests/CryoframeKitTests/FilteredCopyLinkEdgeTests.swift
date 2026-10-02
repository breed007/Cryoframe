//
//  FilteredCopyLinkEdgeTests.swift
//  CryoframeKitTests
//
//  A filtered sealed build's copy keeps hard links when the linked file is locked,
//  sits in a locked folder, or is sparse (which sends it through the copy's second
//  pass), with dates to the nanosecond. The one-walk finish of 1.7 first ran after
//  the relinking and broke every link, because rsync sets whole seconds only.
//

import Testing
import Foundation
@testable import CryoframeKit

@Suite struct FilteredCopyLinkEdgeTests {
    @Test func linksSurviveLockedFilesLockedFoldersAndSparseFiles() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("cf-fclink-\(UUID().uuidString)")
        let lib = base.appendingPathComponent("Lib")
        defer {
            _ = try? ProcessCommandRunner().run("/usr/bin/chflags", ["-R", "0", base.path], stdin: nil)
            try? fm.removeItem(at: base)
        }
        try fm.createDirectory(at: lib.appendingPathComponent("Locked"), withIntermediateDirectories: true)
        try fm.createDirectory(at: lib.appendingPathComponent("Other"), withIntermediateDirectories: true)
        try Data("locked bytes".utf8).write(to: lib.appendingPathComponent("Locked/x.bin"))
        #expect(link(lib.appendingPathComponent("Locked/x.bin").path, lib.appendingPathComponent("x-link.bin").path) == 0)
        // sparse: data at the start, a 64 MiB hole after it
        let sparse = lib.appendingPathComponent("Other/s.bin")
        try Data(repeating: 7, count: 65536).write(to: sparse)
        #expect(truncate(sparse.path, 64 << 20) == 0)
        #expect(link(sparse.path, lib.appendingPathComponent("s-link.bin").path) == 0)
        // dates to the nanosecond, as the library's are
        for rel in ["Locked/x.bin", "Other/s.bin"] {
            var times = [timespec(tv_sec: 1_700_000_000, tv_nsec: 123_456_789), timespec(tv_sec: 1_700_000_000, tv_nsec: 987_654_321)]
            #expect(utimensat(AT_FDCWD, lib.appendingPathComponent(rel).path, &times, 0) == 0)
        }
        #expect(chflags(lib.appendingPathComponent("Locked/x.bin").path, UInt32(UF_IMMUTABLE)) == 0)
        #expect(chflags(lib.appendingPathComponent("Locked").path, UInt32(UF_IMMUTABLE)) == 0)

        let made = try FilteredCopy.make(of: lib, name: "Lib", in: base.appendingPathComponent("build"),
                                         runner: ProcessCommandRunner(control: RunControl()))
        func st(_ root: URL, _ rel: String) -> stat { var s = stat(); _ = lstat(root.appendingPathComponent(rel).path, &s); return s }
        for (a, b) in [("Locked/x.bin", "x-link.bin"), ("Other/s.bin", "s-link.bin")] {
            let (x, y) = (st(made.copy, a), st(made.copy, b))
            #expect(x.st_ino == y.st_ino && x.st_nlink == 2, "\(a) and \(b) aren't one file in the copy")
            let l = st(lib, a)
            #expect(x.st_mtimespec.tv_sec == l.st_mtimespec.tv_sec && x.st_mtimespec.tv_nsec == l.st_mtimespec.tv_nsec, "\(a)'s date")
            #expect(x.st_size == l.st_size && x.st_flags & FilteredCopy.copiedFlags == l.st_flags & FilteredCopy.copiedFlags, "\(a)")
        }
        #expect(st(made.copy, "Locked").st_flags & UInt32(UF_IMMUTABLE) != 0, "the locked folder lost its lock")
        FilteredCopy.remove(in: base.appendingPathComponent("build"), runner: ProcessCommandRunner())
    }
}
