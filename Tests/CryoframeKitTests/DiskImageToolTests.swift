import Testing
import Foundation
@testable import CryoframeKit

/// DiskImageTool's commands and its reading of what the tools print. The fixtures are
/// output captured on macOS 27.0.1 from 100 MB sparse bundles, plain and encrypted.
@Suite struct DiskImageToolTests {
    let image = URL(fileURLWithPath: "/d/Lib.sparsebundle")
    let mnt = URL(fileURLWithPath: "/tmp/cf-mirror-1/mnt")

    // MARK: - commands

    @Test func makingImages() {
        let folder = DiskImageTool.folderImage(root: URL(fileURLWithPath: "/m/lib"), output: URL(fileURLWithPath: "/o/L.dmg"),
                                               encrypted: true, sizeMB: 120)
        #expect(folder.tool == "/usr/bin/hdiutil")
        #expect(folder.args == ["create", "-srcfolder", "/m/lib", "-format", "UDZO", "-size", "120m",
                                "-encryption", "AES-256", "-stdinpass", "-ov", "/o/L.dmg"])
        let sparse = DiskImageTool.sparseBundle(output: image, name: "Lib", sizeGB: 0, bandSectors: 16384,
                                                encrypted: true, sectors: 4096)
        #expect(sparse.tool == "/usr/bin/hdiutil")
        #expect(sparse.args == ["create", "-type", "SPARSEBUNDLE", "-fs", "APFS", "-sectors", "4096", "-volname", "Lib",
                                "-imagekey", "sparse-band-size=16384", "-encryption", "AES-256", "-stdinpass", image.path])
    }

    @Test func sizingCommands() {
        #expect(DiskImageTool.resizeLimits(image: image).args == ["resize", "-limits", image.path])
        #expect(DiskImageTool.resizeLimits(image: image, encrypted: true).args == ["resize", "-limits", "-stdinpass", image.path])
        #expect(DiskImageTool.resize(image: image, sectors: 409_600).args == ["resize", "-sectors", "409600", image.path])
        #expect(DiskImageTool.resize(image: image, sectors: 8, encrypted: true).args == ["resize", "-sectors", "8", "-stdinpass", image.path])
    }

    @Test func attachingAndDetaching() {
        #expect(DiskImageTool.attach(image: image, mountpoint: mnt).args
                == ["attach", image.path, "-mountpoint", mnt.path, "-nobrowse", "-owners", "on"])
        #expect(DiskImageTool.attach(image: image, mountpoint: mnt, readonly: true, encrypted: true).args
                == ["attach", image.path, "-mountpoint", mnt.path, "-nobrowse", "-owners", "on", "-readonly", "-stdinpass"])
        #expect(DiskImageTool.attachWithoutMount(image: image, encrypted: false).args
                == ["attach", "-nomount", "-readonly", "-nobrowse", image.path])
        #expect(DiskImageTool.attachWithoutMount(image: image, encrypted: true, verify: false).args
                == ["attach", "-nomount", "-readonly", "-nobrowse", "-noverify", "-noautofsck", "-stdinpass", image.path])
        #expect(DiskImageTool.detach("/dev/disk9").args == ["detach", "/dev/disk9"])
        #expect(DiskImageTool.detach(mnt.path, force: true).args == ["detach", mnt.path, "-force"])
        #expect(DiskImageTool.unmount(mnt.path, force: true).args == ["unmount", mnt.path, "-force"])
        #expect(DiskImageTool.compact(image: image, encrypted: true).args == ["compact", "-puppetstrings", image.path, "-stdinpass"])
        #expect(DiskImageTool.info().args == ["info", "-plist"])
        #expect(DiskImageTool.encryptionCheck(image: image).args == ["isencrypted", image.path])
    }

    /// Stop lets an attach and the making of an empty image finish (see letsFinish)
    @Test func whatACommandIs() {
        let attach = DiskImageTool.attach(image: image, mountpoint: mnt)
        #expect(DiskImageTool.isAttach(attach.tool, attach.args))
        let sparse = DiskImageTool.sparseBundle(output: image, name: "L", sizeGB: 1, bandSectors: 16384)
        #expect(DiskImageTool.isBlankCreate(sparse.tool, sparse.args))
        let folder = DiskImageTool.folderImage(root: mnt, output: image)
        #expect(!DiskImageTool.isBlankCreate(folder.tool, folder.args))
        #expect(!DiskImageTool.isAttach("/usr/bin/rsync", ["attach"]))
    }

    // MARK: - reading output

    @Test func limitsAreReadInBytes() throws {
        let plain = try #require(DiskImageTool.limits(from: "12288\t204720\t18014398509481903\n"))
        #expect(plain.minimum == 12288 * 512)
        #expect(plain.current == 204_720 * 512)
        #expect(plain.maximum == 18_014_398_509_481_903 * 512)
        #expect(DiskImageTool.limits(from: "hdiutil: resize failed - Authentication error") == nil)
        #expect(DiskImageTool.limits(from: "") == nil)
    }

    @Test func encryptionIsRead() {
        #expect(DiskImageTool.isEncrypted(from: "encrypted: YES\n") == true)
        #expect(DiskImageTool.isEncrypted(from: "encrypted: NO\n") == false)
        #expect(DiskImageTool.isEncrypted(from: "hdiutil: isencrypted failed - image not recognized") == nil)
    }

    @Test func anAttachsDevicesAreReadInOrder() {
        let printed = "/dev/disk27         \tGUID_partition_scheme          \t\n"
            + "/dev/disk27s1       \tApple_APFS                     \t\n"
            + "/dev/disk28         \tEF57347C-0000-11AA-AA11-0030654\t\n"
            + "/dev/disk28s1       \t41504653-0000-11AA-AA11-0030654\t\n"
        let devices = DiskImageTool.devices(fromAttach: printed)
        #expect(devices.map(\.node) == ["/dev/disk27", "/dev/disk27s1", "/dev/disk28", "/dev/disk28s1"])
        #expect(devices.first { $0.content.contains("Apple_APFS") }?.node == "/dev/disk27s1")
        #expect(DiskImageTool.devices(fromAttach: "hdiutil: attach failed - Authentication error").isEmpty)
    }

    @Test func theAttachedListIsRead() throws {
        let attaches = try #require(DiskImageTool.attaches(from: Self.info))
        #expect(attaches.count == 2)
        let mounted = attaches[0]
        #expect(mounted.path == "/var/folders/T/cf18fx/p.sparsebundle")
        #expect(mounted.devices == ["/dev/disk25", "/dev/disk25s1", "/dev/disk26", "/dev/disk26s1"])
        #expect(mounted.mountPoints == ["/private/var/folders/T/cf18fx/m"])
        #expect(mounted.mounted && mounted.helper == 22109)
        #expect(!attaches[1].mounted && attaches[1].helper == nil)
        // nothing attached: no list at all, which is not "can't tell"
        #expect(DiskImageTool.attaches(from: Self.plist("<dict><key>framework</key><string>1</string></dict>"))?.isEmpty == true)
        #expect(DiskImageTool.attaches(from: "hdiutil: info failed") == nil)
    }

    // MARK: - one place

    /// Every disk-image command is DiskImageTool's, so that each verb can move to
    /// `diskutil image` in one place. RecoveryNote's Terminal instructions name hdiutil
    /// on purpose, without a path: it works on every macOS version.
    @Test func noOtherSourceRunsHdiutil() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let walk = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        var seen = 0
        for case let file as URL in walk where file.pathExtension == "swift" {
            seen += 1
            guard file.lastPathComponent != "DiskImageTool.swift" else { continue }
            if try String(contentsOf: file, encoding: .utf8).contains("\"/usr/bin/hdiutil\"") { offenders.append(file.lastPathComponent) }
        }
        #expect(seen > 50, "found \(seen) source files")
        #expect(offenders.isEmpty, "run disk-image commands through DiskImageTool: \(offenders)")
    }

    // MARK: - fixtures

    static func plist(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        \(body)
        </plist>
        """
    }

    /// `hdiutil info -plist` with one image mounted and one attached with -nomount
    /// (trimmed to the keys read; paths shortened)
    static let info = plist("""
        <dict>
            <key>framework</key><string>1069.0.0</string>
            <key>images</key>
            <array>
                <dict>
                    <key>diskimages2</key><true/>
                    <key>hdid-pid</key><integer>22109</integer>
                    <key>image-path</key><string>/var/folders/T/cf18fx/p.sparsebundle</string>
                    <key>system-entities</key>
                    <array>
                        <dict><key>content-hint</key><string>GUID_partition_scheme</string><key>dev-entry</key><string>/dev/disk25</string></dict>
                        <dict><key>content-hint</key><string>7C3457EF-0000-11AA-AA11-00306543ECAC</string><key>dev-entry</key><string>/dev/disk25s1</string></dict>
                        <dict><key>content-hint</key><string>EF57347C-0000-11AA-AA11-00306543ECAC</string><key>dev-entry</key><string>/dev/disk26</string></dict>
                        <dict><key>content-hint</key><string>41504653-0000-11AA-AA11-00306543ECAC</string><key>dev-entry</key><string>/dev/disk26s1</string>
                              <key>mount-point</key><string>/private/var/folders/T/cf18fx/m</string></dict>
                    </array>
                </dict>
                <dict>
                    <key>image-path</key><string>/var/folders/T/cf18fx/e.sparsebundle</string>
                    <key>system-entities</key>
                    <array>
                        <dict><key>content-hint</key><string>GUID_partition_scheme</string><key>dev-entry</key><string>/dev/disk27</string></dict>
                    </array>
                </dict>
            </array>
        </dict>
        """)
}
