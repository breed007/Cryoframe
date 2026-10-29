//
//  UnreadableSourceTests.swift
//  CryoframeKitTests
//
//  What a run does with what it can't read. A folder the app may not read (Full Disk
//  Access lost, a mode changed by mistake, a failing drive) is not an empty folder:
//  the run fails and says so, and nothing in the copy is moved to Removed items.
//

import Testing
import Foundation
@testable import CryoframeKit

private func tempDir(_ tag: String) -> URL {
    let d = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        .appendingPathComponent("cf-unreadable-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

private func put(_ root: URL, _ rel: String, _ text: String) throws {
    let url = root.appendingPathComponent(rel)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

private func files(under root: URL) -> [String] {
    var out: [String] = []
    let e = FileManager.default.enumerator(atPath: root.path)
    while let p = e?.nextObject() as? String {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(p).path, isDirectory: &isDir), !isDir.boolValue {
            out.append(p)
        }
    }
    return out.sorted()
}

@Suite(.serialized) struct UnreadableSourceTests {

    // On a drive that isn't a Mac's the copy is compared item by item. A library folder
    // that couldn't be listed read as empty, so everything the copy held of it went to
    // Removed items and the run reported success; the library's own top folder emptied
    // the whole copy the same way.
    @Test(arguments: ["exfat", "msdos"]) func anUnreadableLibraryFolderFailsTheRunAndLeavesTheCopy(_ fsType: String) throws {
        let base = tempDir("plain-\(fsType)")
        defer {
            _ = try? ProcessCommandRunner().run("/bin/chmod", ["-R", "u+rwX", base.path], stdin: nil)
            try? FileManager.default.removeItem(at: base)
        }
        let lib = base.appendingPathComponent("Lib", isDirectory: true)
        let dest = base.appendingPathComponent("dest", isDirectory: true)
        try put(lib, "top.txt", "top")
        try put(lib, "sub/a.txt", "aaaa")
        try put(lib, "sub/b.txt", "bbbbbb")
        let copier = PlainCopy(profile: FileSystemProfile.make(fsType: fsType), runner: ProcessCommandRunner(),
                               companions: false, accepts: { _ in true },
                               probe: { _ in DriveAllocation(allocationUnit: 4096, companion: false) })
        _ = try copier.run(lib, in: dest)
        let full = files(under: dest)
        #expect(full == ["Lib/sub/a.txt", "Lib/sub/b.txt", "Lib/top.txt"])

        for (unreadable, shown) in [("sub", "sub"), ("", "Lib")] {
            let path = unreadable.isEmpty ? lib.path : lib.appendingPathComponent(unreadable).path
            #expect(chmod(path, 0o000) == 0)
            let error = #expect(throws: (any Error).self) { _ = try copier.run(lib, in: dest) }
            #expect(error?.localizedDescription.contains("couldn't read “\(shown)”") == true, "\(String(describing: error))")
            #expect(chmod(path, 0o755) == 0)
            #expect(files(under: dest) == full, "unreadable \(shown)")
        }
        // readable again: nothing to write, nothing removed
        let after = try copier.run(lib, in: dest)
        #expect(after.removed == 0)
        #expect(files(under: dest) == full)
    }
}
