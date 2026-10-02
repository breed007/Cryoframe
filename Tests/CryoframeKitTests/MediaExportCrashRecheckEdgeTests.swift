//
//  MediaExportCrashRecheckEdgeTests.swift
//  CryoframeKitTests
//
//  An export killed in the middle of a file (simulated: the export's list on disk and
//  the file left as the kill left it) is finished by the next export: the file is
//  written again whole under its own name, never counted as already exported, and no
//  "(2)" copy appears.
//

import Testing
import Foundation
@testable import CryoframeKit

private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

@Suite(.serialized) struct MediaExportCrashRecheckEdgeTests {
    private enum Kill: CaseIterable {
        case halfWritten          // killed while writing: a prefix, no date
        case fullSizeNoDate       // killed after the last byte, before the date was set
        case emptyJustCreated     // killed right after the file was created
        case zeroFilledFullSize   // power cut: size reached the drive, the data didn't
    }

    @Test(arguments: Kill.allCases)
    private func theNextExportRewritesAFileTheKillLeftAndNeverCountsItAsDone(_ kill: Kill) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("cf-crash-\(UUID().uuidString)")
        let source = base.appendingPathComponent("Library"), dest = base.appendingPathComponent("Out")
        let fm = FileManager.default
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let date = utc.date(from: DateComponents(year: 2023, month: 3, day: 9, hour: 12))!
        var bytes: [String: Data] = [:]
        for i in 0..<3 {
            let d = Data((0..<(9 * 1024 * 1024 + i)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ i) })   // 3 chunks and a bit
            bytes["f\(i).heic"] = d
            let u = source.appendingPathComponent("f\(i).heic")
            try d.write(to: u)
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: u.path)
        }
        let drive = MediaExportDrive(name: "Out", free: 1 << 40)
        let export = MediaExport(calendar: utc, interval: 0)

        let files = try MediaExport.look(in: source, control: RunControl()) { _ in }
        let plan = try MediaExportPlanner.plan(MediaCatalog.entries(files), drive: drive,
                                               probe: MediaExport.probe(source: source, destination: dest, control: RunControl()), calendar: utc)
        try MediaExport.writeList(plan, in: dest)
        let month = dest.appendingPathComponent("2023-03")
        try fm.createDirectory(at: month, withIntermediateDirectories: true)
        var partLeft = false
        try MediaExport.copyFile(source.appendingPathComponent("f0.heic"), into: month, as: "f0.heic", modified: date,
                                 control: RunControl(), partLeft: &partLeft) { _ in }
        let full = bytes["f1.heic"]!
        let torn: Data
        switch kill {
        case .halfWritten: torn = full.prefix(4 * 1024 * 1024)
        case .fullSizeNoDate: torn = full
        case .emptyJustCreated: torn = Data()
        case .zeroFilledFullSize: torn = Data(count: full.count)
        }
        try torn.write(to: month.appendingPathComponent("f1.heic"))   // dated now, as a kill leaves it

        let after = try export.run(from: source, to: dest, filter: MediaExportFilter(), drive: drive, control: RunControl()) { _ in }
        #expect(after.copied == 2 && after.alreadyThere == 1 && after.unreadable.isEmpty && !after.stopped, "\(kill): \(after)")
        let left = (fm.enumerator(atPath: dest.path)?.allObjects as? [String] ?? []).filter { !$0.hasSuffix("2023-03") }.sorted()
        #expect(left == ["2023-03/f0.heic", "2023-03/f1.heic", "2023-03/f2.heic"], "\(kill): \(left)")
        for i in 0..<3 {
            #expect(fm.contentsEqual(atPath: month.appendingPathComponent("f\(i).heic").path, andPath: source.appendingPathComponent("f\(i).heic").path), "\(kill) f\(i)")
        }
        // and a third export has nothing to do
        let third = try export.run(from: source, to: dest, filter: MediaExportFilter(), drive: drive, control: RunControl()) { _ in }
        #expect(third.copied == 0 && third.alreadyThere == 3, "\(kill): \(third)")
    }
}
