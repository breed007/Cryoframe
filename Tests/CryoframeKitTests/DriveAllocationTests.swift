import Foundation
import Testing
@testable import CryoframeKit

@Suite struct DriveAllocationTests {
    private func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cf-alloc-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func probeMeasuresAUnitAndLeavesNothingBehind() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let found = DriveAllocation.probe(at: folder)
        #expect((found.allocationUnit ?? 0) >= 512)
        #expect(found.companion != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func probeOfAMissingFolderIsEmpty() {
        let gone = FileManager.default.temporaryDirectory.appendingPathComponent("cf-alloc-missing-" + UUID().uuidString)
        #expect(DriveAllocation.probe(at: gone) == DriveAllocation())
    }

    @Test func clusterTakesTheLargerOfWhatStatfsAndTheProbeSay() {
        let probed = DriveAllocation(allocationUnit: 131072, companion: false)
        #expect(DriveAllocation.cluster(statfsBlockSize: 4096, fsType: "exfat", probed: probed) == 131072)
        #expect(DriveAllocation.cluster(statfsBlockSize: 131072, fsType: "exfat", probed: DriveAllocation(allocationUnit: 4096)) == 131072)
    }

    @Test func clusterWithoutAMeasurementIsConservativeOnFATOnly() {
        let none = DriveAllocation()
        #expect(DriveAllocation.cluster(statfsBlockSize: 4096, fsType: "exfat", probed: none) == 131072)
        #expect(DriveAllocation.cluster(statfsBlockSize: 4096, fsType: "msdos", probed: none) == 131072)
        #expect(DriveAllocation.cluster(statfsBlockSize: 4096, fsType: "apfs", probed: none) == 4096)
        #expect(DriveAllocation.cluster(statfsBlockSize: nil, fsType: "apfs", probed: none) == 4096)
    }
}
