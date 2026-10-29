//
//  PlainFilesDrillTests.swift
//  CryoframeKitTests
//
//  A restore drill of a plain-files copy. The copy has no checksum manifest (it was
//  read back against the library when it was written), and the drill looked for one:
//  every drill of every plain-files job failed, and with checks set to drills each
//  scheduled round raised a false alert. It opens every file of the copy instead.
//

import Testing
import Foundation
@testable import CryoframeKit

private func tempDir(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-plaindrill-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func put(_ root: URL, _ rel: String, _ text: String) throws {
    let url = root.appendingPathComponent(rel)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

private let exfatLike = FileSystemProfile(kind: .exfat, fsType: "exfat", foldsCase: true, cluster: 4096, companions: false)

@Suite(.serialized) struct PlainFilesDrillTests {

    @Test func aDrillOpensAPlainCopyAndFailsOnlyWhatARestoreWould() throws {
        let base = tempDir("drill")
        defer {
            _ = try? ProcessCommandRunner().run("/bin/chmod", ["-R", "u+rwX", base.path], stdin: nil)
            try? FileManager.default.removeItem(at: base)
        }
        let src = base.appendingPathComponent("src/Papers")
        try put(src, "a.txt", "a")
        try put(src, "sub/b.txt", "b")
        let dest = base.appendingPathComponent("dest")
        let lib = ContentType.genericFolder(id: "papers", displayName: "Papers", path: .absolute(src.path))
        let job = BackupJob(name: "P", libraries: [lib], target: .localVolume(id: "d", name: "Disk", dir: dest),
                            format: .plainFiles, frequency: .manual, createdAt: Date())
        let prepared = try LibraryFolders.prepare(job: job, library: lib, in: dest, jobs: [job])
        let (result, _) = try JobExecutor.plainFiles(job: job, library: lib, source: ArchiveSource(name: "Papers", root: src),
                                                     folder: prepared.folder, target: job.target, profile: exfatLike, bytes: 10,
                                                     partial: false, now: Date(), runner: ProcessCommandRunner())
        guard case .completed = result else { Issue.record("not completed: \(result)"); return }
        let copy = prepared.folder.appendingPathComponent("Papers")

        var report = RestoreDriller().drill(job: job)
        #expect(report.checks.count == 1)
        #expect(report.checks.first?.passed == true && report.checks.first?.skipped == false, "\(report.checks)")

        // a file the restore couldn't read fails it
        #expect(chmod(copy.appendingPathComponent("sub/b.txt").path, 0o000) == 0)
        report = RestoreDriller().drill(job: job)
        #expect(report.checks.first?.passed == false, "\(report.checks)")
        #expect(chmod(copy.appendingPathComponent("sub/b.txt").path, 0o644) == 0)

        // an update stopped part way isn't counted either way
        try PlainCopy.mark(prepared.folder)
        report = RestoreDriller().drill(job: job)
        #expect(report.checks.first?.skipped == true, "\(report.checks)")
        PlainCopy.unmark(prepared.folder)

        // an empty copy is no backup
        for name in try FileManager.default.contentsOfDirectory(atPath: copy.path) {
            try FileManager.default.removeItem(at: copy.appendingPathComponent(name))
        }
        report = RestoreDriller().drill(job: job)
        #expect(report.checks.first?.passed == false, "\(report.checks)")
    }
}
