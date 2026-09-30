//
//  AttributeReadBackEdgeTests.swift
//  CryoframeKitTests
//
//  The mirror's attribute read-back against attributes real files carry: what a
//  browser, Mail or AirDrop puts on a download (com.apple.quarantine), where it came
//  from, Finder tags and flags, resource forks, text encodings, access lists,
//  compressed files, and the ones macOS keeps to itself. Every run must read back
//  clean, run after run, or the mirror fails every night.
//
//  Measured on macOS 26.7: copyfile(3), which openrsync -E and the engine's own
//  attribute pass both use, re-stamps com.apple.quarantine on the copy. The flags
//  gain 0x0200, the timestamp becomes the time of the copy, and the agent name is
//  dropped ("0083;66f9a1b2;Safari;…" arrives as "0283;6abc45ca;;…"). A plain
//  setxattr keeps it byte for byte.
//

import Testing
import Foundation
@testable import CryoframeKit

private func dir(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-attredge-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

private func set(_ path: String, _ name: String, _ value: [UInt8]) -> Int32 {
    setxattr(path, name, value, value.count, 0, XATTR_NOFOLLOW)
}

/// Finder tags, the way Finder sets them (FinderInfo color and the tag list)
private func tag(_ url: URL, _ tags: [String]) throws {
    try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
}

/// mirror `src` into `out` `times` times; the error of each run, nil for a clean one
private func mirror(_ src: URL, to out: URL, base: URL, times: Int, between: (Int) -> Void = { _ in }) -> [String?] {
    (1...times).map { n in
        between(n)
        do {
            _ = try SparseBundleMirrorEngine(sizeGB: 1, mountBase: base).archive(ArchiveSource(name: "Lib", root: src), to: out)
            return nil
        } catch {
            return "\(error)"
        }
    }
}

@Suite(.serialized) struct AttributeReadBackEdgeTests {

    // A PDF downloaded in Safari, a read-only attachment saved from Mail, a folder
    // unpacked from a downloaded zip: all carry com.apple.quarantine. A library
    // holding any of them failed its read-back on every run (readBackMismatch,
    // "has a different value for extended attribute com.apple.quarantine"), so a
    // mirror of a Documents or Downloads folder never succeeds.
    @Test func downloadedFilesMirrorCleanlyRunAfterRun() throws {
        let src = dir("qsrc").appendingPathComponent("Lib")
        let out = dir("q"), base = dir("base")
        defer { _ = try? ProcessCommandRunner().run("/bin/chmod", ["-R", "u+w", src.path]); for d in [out, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        let unpacked = src.appendingPathComponent("Unpacked")
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        for (name, agent) in [("statement.pdf", "Safari"), ("invoice.pdf", "Mail"), ("Unpacked/readme.txt", "Archive Utility")] {
            let f = src.appendingPathComponent(name)
            try Data("body of \(name)".utf8).write(to: f)
            #expect(set(f.path, "com.apple.quarantine", Array("0083;66f9a1b2;\(agent);8E3C2F7A-1B2C-4D5E-9F00-112233445566".utf8)) == 0)
        }
        #expect(set(unpacked.path, "com.apple.quarantine", Array("0083;66f9a1b2;Archive Utility;".utf8)) == 0)
        #expect(chmod(src.appendingPathComponent("invoice.pdf").path, 0o444) == 0)
        let runs = mirror(src, to: out, base: base, times: 2)
        #expect(runs[0] == nil, "first run: \(runs[0] ?? "")")
        #expect(runs[1] == nil, "second run: \(runs[1] ?? "")")
    }

    // Everything else a real library's files carry, including the attributes macOS
    // keeps to itself: three runs, the second after a tag is changed and the third
    // after nothing is. Each reads back clean.
    @Test func everydayAttributesMirrorCleanlyRunAfterRun() throws {
        let src = dir("esrc").appendingPathComponent("Lib")
        let out = dir("e"), base = dir("base")
        defer { _ = try? ProcessCommandRunner().run("/bin/chmod", ["-R", "u+w", src.path]); _ = try? ProcessCommandRunner().run("/bin/chmod", ["-R", "-N", src.path])
                for d in [out, base, src.deletingLastPathComponent()] { try? FileManager.default.removeItem(at: d) } }
        let fm = FileManager.default
        try fm.createDirectory(at: src.appendingPathComponent("Tagged Folder"), withIntermediateDirectories: true)
        try fm.createDirectory(at: src.appendingPathComponent("Shared"), withIntermediateDirectories: true)
        for f in ["wherefrom.zip", "tagged.txt", "hidden.txt", "fork.txt", "encoded.txt", "lastused.txt", "macl.txt", "label.txt", "acl.txt", "locked-tagged.txt"] {
            try Data("body of \(f)".utf8).write(to: src.appendingPathComponent(f))
        }
        let p = { (n: String) in src.appendingPathComponent(n).path }
        let whereFroms = try PropertyListSerialization.data(fromPropertyList: ["https://example.com/a.zip", "https://example.com/"], format: .binary, options: 0)
        #expect(set(p("wherefrom.zip"), "com.apple.metadata:kMDItemWhereFroms", Array(whereFroms)) == 0)
        for (item, tags) in [("tagged.txt", ["Red", "Work"]), ("Tagged Folder", ["Blue"]), ("locked-tagged.txt", ["Green"])] {
            try tag(src.appendingPathComponent(item), tags)
        }
        var hidden = src.appendingPathComponent("hidden.txt"); var hv = URLResourceValues(); hv.hasHiddenExtension = true; try hidden.setResourceValues(hv)
        #expect(set(p("fork.txt"), "com.apple.ResourceFork", Array(repeating: 0xAB, count: 70_000)) == 0)
        #expect(set(p("encoded.txt"), "com.apple.TextEncoding", Array("utf-8;134217984".utf8)) == 0)
        #expect(set(p("lastused.txt"), "com.apple.lastuseddate#PS", Array(repeating: 1, count: 16)) == 0)
        #expect(set(p("macl.txt"), "com.apple.macl", [4, 0] + Array(repeating: 0x11, count: 70)) == 0)
        #expect(set(p("label.txt"), "com.apple.metadata:kMDLabel_abcdef", Array(repeating: 0x22, count: 40)) == 0)
        #expect(try ProcessCommandRunner().run("/bin/chmod", ["+a", "everyone deny delete", p("acl.txt")]).ok)
        #expect(try ProcessCommandRunner().run("/bin/chmod", ["+a", "everyone deny delete", p("Shared")]).ok)
        #expect(try ProcessCommandRunner().run("/bin/chmod", ["+a", "group:staff allow list,search,add_file", p("Shared")]).ok)
        // a file stored compressed (decmpfs), as many system-written files are
        let raw = dir("raw"); defer { try? fm.removeItem(at: raw) }
        try Data(repeating: 0x41, count: 300_000).write(to: raw.appendingPathComponent("compressed.txt"))
        #expect(try ProcessCommandRunner().run("/usr/bin/ditto", ["--hfsCompression", raw.appendingPathComponent("compressed.txt").path, p("compressed.txt")]).ok)
        #expect(chmod(p("locked-tagged.txt"), 0o444) == 0)

        let runs = mirror(src, to: out, base: base, times: 3) { n in
            if n == 2 { try? tag(src.appendingPathComponent("tagged.txt"), ["Purple"]) }
        }
        for (i, r) in runs.enumerated() { #expect(r == nil, "run \(i + 1): \(r ?? "")") }
    }
}
