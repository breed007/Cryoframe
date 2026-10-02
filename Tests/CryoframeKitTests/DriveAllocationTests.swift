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

    // statfs can't be trusted on exFAT and FAT (512 on macOS 15 for a 128 KiB-cluster
    // drive): what the probe measured is the cluster there, even a real 512 on a small
    // FAT32 drive. Elsewhere it is the larger of the two.
    @Test func clusterIsWhatTheProbeMeasuredOnFATAndTheLargerElsewhere() {
        let probed = DriveAllocation(allocationUnit: 131072, companion: false)
        #expect(DriveAllocation.cluster(statfsBlockSize: 512, fsType: "exfat", probed: probed) == 131072)
        #expect(DriveAllocation.cluster(statfsBlockSize: 32768, fsType: "msdos", probed: DriveAllocation(allocationUnit: 512)) == 512)
        #expect(DriveAllocation.cluster(statfsBlockSize: 4096, fsType: "smbfs", probed: probed) == 131072)
        #expect(DriveAllocation.cluster(statfsBlockSize: 131072, fsType: "smbfs", probed: DriveAllocation(allocationUnit: 4096)) == 131072)
    }

    // never the 512 macOS 15 reports: exFAT's largest common cluster, or FAT32's
    @Test func clusterWithoutAMeasurementIsConservativeOnFATOnly() {
        let none = DriveAllocation()
        #expect(DriveAllocation.cluster(statfsBlockSize: 512, fsType: "exfat", probed: none) == 131072)
        #expect(DriveAllocation.cluster(statfsBlockSize: 512, fsType: "msdos", probed: none) == 32768)
        #expect(DriveAllocation.cluster(statfsBlockSize: 65536, fsType: "msdos", probed: none) == 65536)
        #expect(DriveAllocation.cluster(statfsBlockSize: 4096, fsType: "apfs", probed: none) == 4096)
        #expect(DriveAllocation.cluster(statfsBlockSize: nil, fsType: "apfs", probed: none) == 4096)
    }
}
