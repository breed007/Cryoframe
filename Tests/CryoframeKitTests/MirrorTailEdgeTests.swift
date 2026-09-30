//
//  MirrorTailEdgeTests.swift
//  CryoframeKitTests
//
//  After the rsync passes, a file of the copy shorter than the library's is
//  extended (its tail a hole) and given the library's date, for macOS 15's
//  openrsync, which leaves a file ending in zeros short. Extended and dated, a file
//  that lost DATA at its end (a drive filling up under the image, where rsync
//  said all was well) looks right by size and date. It must still fail the
//  read-back: a file whose library size or date differs from the previous copy's
//  is compared byte for byte.
//

import Testing
import Foundation
@testable import CryoframeKit

private func folder(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-tail-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    guard let real = realpath(d.path, nil) else { return d }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

private func random(_ n: Int) -> Data { var d = Data(count: n); d.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, n) }; return d }

private func setDate(_ url: URL, _ date: Date) throws {
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
}

@Suite(.serialized) struct MirrorTailEdgeTests {

    // A changed file, and a new one, each cut short with data lost from their ends
    // by the copier. Both come out of the sync at the library's size and date.
    @Test(arguments: ["changed", "new"])
    func aFileThatLostDataAtItsEndFailsTheReadBackOnceExtended(_ variant: String) throws {
        let base = folder(variant); defer { try? FileManager.default.removeItem(at: base) }
        let lib = base.appendingPathComponent("Lib")
        let vol = base.appendingPathComponent("vol")
        let current = vol.appendingPathComponent("Lib"), staging = vol.appendingPathComponent(".cryoframe-staging")
        let next = staging.appendingPathComponent("Lib")
        for d in [lib, current] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try random(4096).write(to: lib.appendingPathComponent("same.bin"))
        try setDate(lib.appendingPathComponent("same.bin"), Date(timeIntervalSince1970: 1_700_000_000))
        try FileManager.default.copyItem(at: lib.appendingPathComponent("same.bin"), to: current.appendingPathComponent("same.bin"))
        try setDate(current.appendingPathComponent("same.bin"), Date(timeIntervalSince1970: 1_700_000_000))
        let name = "report.bin"
        try random(1 << 20).write(to: lib.appendingPathComponent(name))           // this run's version: data to its end
        if variant == "changed" {
            try random(1 << 20).write(to: current.appendingPathComponent(name))   // the previous copy's, older
            try setDate(current.appendingPathComponent(name), Date(timeIntervalSince1970: 1_700_000_000))
        }
        // the new copy starts as the previous one
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let cloned = try ProcessCommandRunner().run("/bin/cp", ["-c", "-Rp", current.path, next.path], stdin: nil)
        try #require(cloned.ok, "\(cloned.stderr)")

        let runner = ProcessCommandRunner()
        var cut = false
        _ = try MirrorCopy.sync(lib, into: next, runner: runner) { cmd in
            let r = try runner.run(cmd.tool, cmd.args, stdin: nil)
            guard r.ok else { throw ArchiveError.toolFailed(tool: cmd.tool, status: r.status, stderr: r.stderr) }
            // a copier that loses the last half of what it wrote, and says nothing
            let p = next.appendingPathComponent(name).path
            var st = stat()
            if !cut, lstat(p, &st) == 0, st.st_size == 1 << 20 { cut = truncate(p, 1 << 19) == 0 }
        }
        try #require(cut, "the stand-in copier didn't cut the file")
        var st = stat()
        #expect(lstat(next.appendingPathComponent(name).path, &st) == 0 && st.st_size == 1 << 20, "extended to the library's size")
        #expect(throws: MirrorCopyError.self, "a file missing half its data passed the read-back") {
            try MirrorCopy.verify(MirrorCopy.Staged(volume: vol, current: current, staging: staging, next: next), against: lib, control: nil)
        }
    }
}
