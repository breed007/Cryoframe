import Foundation
import Testing
import CryoframeShared
@testable import CryoframeKit

@Suite struct HelperArgumentsTests {
    @Test func theVolumesTheAppSendsPass() throws {
        // the boot volume as JobExecutor names it, an external drive, and the empty
        // mount point the backend reads as the boot volume
        try HelperArguments.check(VolumeRef(mountPoint: "/System/Volumes/Data", bsdDevice: ""))
        try HelperArguments.check(VolumeRef(mountPoint: "/Volumes/Photos SSD", bsdDevice: ""))
        try HelperArguments.check(VolumeRef(mountPoint: "/", bsdDevice: ""))
        try HelperArguments.check(VolumeRef(mountPoint: "", bsdDevice: ""))
        try HelperArguments.check(VolumeRef(mountPoint: "/System/Volumes/Data", bsdDevice: "/dev/disk3s5"))
    }

    @Test func aMountPointAToolWouldReadAsAnOptionIsRefused() {
        for path in ["-v", "--help", "-", "Volumes/Photos", "~/Photos", " /Volumes/Photos", "/Volumes/a\nb"] {
            #expect(!HelperArguments.isMountPoint(path), "\(path)")
            #expect(throws: HelperError.self) {
                try HelperArguments.check(VolumeRef(mountPoint: path, bsdDevice: ""))
            }
        }
    }

    @Test func onlyADiskSliceIsADevice() {
        for device in ["/dev/disk3s5", "/dev/disk0s1", "/dev/disk12s10"] {
            #expect(HelperArguments.isDiskSlice(device), "\(device)")
        }
        for device in ["/dev/disk3", "/dev/rdisk3s5", "disk3s5", "/dev/disk3s5 -o union", "/dev/disk3s", "/dev/disks5",
                       "/dev/disk3s5s1", "/dev/disk3s5/..", "-s", "/dev/diskAs1", "/dev/disk\u{0663}s5"] {
            #expect(!HelperArguments.isDiskSlice(device), "\(device)")
            #expect(throws: HelperError.self) {
                try HelperArguments.check(VolumeRef(mountPoint: "/", bsdDevice: device))
            }
        }
    }
}
