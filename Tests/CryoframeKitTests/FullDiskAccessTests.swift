//
//  FullDiskAccessTests.swift
//  CryoframeKitTests
//
//  Full Disk Access is decided from probes of protected locations. The decision is
//  tested with fake probes only; the real probe is tried on files these tests make
//  in a temporary folder, never on a protected location of this Mac.
//

import Testing
import Foundation
@testable import CryoframeKit

@Suite struct FullDiskAccessTests {

    /// a fake probe answering from a table, recording the order it was asked in.
    final class FakeProbe {
        var answers: [String: FullDiskAccess.Probe]
        var asked: [String] = []
        init(_ answers: [String: FullDiskAccess.Probe]) { self.answers = answers }
        func callAsFunction(_ path: String) -> FullDiskAccess.Probe {
            asked.append(path)
            return answers[path] ?? .missing
        }
    }

    let paths = ["/a", "/b", "/c", "/d"]

    @Test func aReadableLocationMeansGrantedAndEndsTheSearch() {
        let fake = FakeProbe(["/a": .readable, "/b": .refused])
        #expect(FullDiskAccess.status(paths: paths, probe: fake.callAsFunction) == .granted)
        #expect(fake.asked == ["/a"])
    }

    @Test func refusalsEverywhereMeanDenied() {
        let fake = FakeProbe(Dictionary(uniqueKeysWithValues: paths.map { ($0, .refused) }))
        #expect(FullDiskAccess.status(paths: paths, probe: fake.callAsFunction) == .denied)
        #expect(fake.asked == paths)
    }

    // macOS 27 has no per-user TCC folder: nothing there to ask is not a refusal
    @Test func noLocationThereMeansUnknown() {
        let fake = FakeProbe([:])
        #expect(FullDiskAccess.status(paths: paths, probe: fake.callAsFunction) == .unknown)
        #expect(fake.asked == paths)
        #expect(FullDiskAccess.status(paths: [], probe: fake.callAsFunction) == .unknown)
    }

    @Test func inconclusiveFailuresAloneMeanUnknown() {
        let fake = FakeProbe(["/a": .inconclusive, "/c": .inconclusive])
        #expect(FullDiskAccess.status(paths: paths, probe: fake.callAsFunction) == .unknown)
    }

    // a refusal can be ordinary file permissions; a later read still proves the grant
    @Test func aReadAfterARefusalMeansGranted() {
        let fake = FakeProbe(["/a": .missing, "/b": .refused, "/c": .inconclusive, "/d": .readable])
        #expect(FullDiskAccess.status(paths: paths, probe: fake.callAsFunction) == .granted)
        #expect(fake.asked == paths)
    }

    @Test func aMissingLocationThenARefusalMeansDenied() {
        let fake = FakeProbe(["/a": .missing, "/b": .refused])
        #expect(FullDiskAccess.status(paths: paths, probe: fake.callAsFunction) == .denied)
        #expect(fake.asked == paths)   // in order, and the rest still tried for a read
    }

    @Test func errorsAreClassified() {
        #expect(FullDiskAccess.classify(EPERM) == .refused)
        #expect(FullDiskAccess.classify(EACCES) == .refused)
        #expect(FullDiskAccess.classify(ENOENT) == .missing)
        #expect(FullDiskAccess.classify(ENOTDIR) == .missing)
        #expect(FullDiskAccess.classify(EIO) == .inconclusive)
    }

    @Test func pathsAreUnderTheHomeFolderUnlessAbsolute() {
        let p = FullDiskAccess.paths(home: URL(fileURLWithPath: "/Users/jdoe"))
        #expect(p == ["/Users/jdoe/Library/Application Support/com.apple.TCC/TCC.db",
                      "/Library/Application Support/com.apple.TCC/TCC.db",
                      "/Users/jdoe/Library/Safari",
                      "/Users/jdoe/Library/Mail"])
    }

    // the real probe, on stand-ins made here (never a protected location)
    @Test func theRealProbeReadsFilesAndFolders() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fda-probe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            for p in ["locked", "shut"] { chmod(dir.appendingPathComponent(p).path, 0o700) }
            try? FileManager.default.removeItem(at: dir)
        }
        let file = dir.appendingPathComponent("file"); try Data("x".utf8).write(to: file)
        let empty = dir.appendingPathComponent("empty"); try Data().write(to: empty)
        let folder = dir.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let locked = dir.appendingPathComponent("locked"); try Data("x".utf8).write(to: locked)
        chmod(locked.path, 0)
        let shut = dir.appendingPathComponent("shut")
        try FileManager.default.createDirectory(at: shut, withIntermediateDirectories: false)
        chmod(shut.path, 0o300)   // can enter, can't list

        #expect(FullDiskAccess.probe(file.path) == .readable)
        #expect(FullDiskAccess.probe(empty.path) == .readable)
        #expect(FullDiskAccess.probe(folder.path) == .readable)   // empty listing still read
        #expect(FullDiskAccess.probe(locked.path) == .refused)
        #expect(FullDiskAccess.probe(shut.path) == .refused)
        #expect(FullDiskAccess.probe(dir.appendingPathComponent("absent").path) == .missing)
        #expect(FullDiskAccess.probe(file.appendingPathComponent("under-a-file").path) == .missing)
    }

    // Report a Problem keeps the status words rather than redacting them
    @Test func theReportKeepsTheStatusWords() {
        let r = Redactor(names: [], userWords: [])
        for status in [FullDiskAccess.Status.granted, .denied, .unknown] {
            #expect(r.redact(status.reportText) == status.reportText)
        }
    }
}
