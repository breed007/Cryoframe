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
        #expect(DiskImageTool.resizeLimits(image: image, tool: .hdiutil).args == ["resize", "-limits", image.path])
        #expect(DiskImageTool.resizeLimits(image: image, encrypted: true, tool: .hdiutil).args == ["resize", "-limits", "-stdinpass", image.path])
        #expect(DiskImageTool.resize(image: image, sectors: 409_600, tool: .hdiutil).args == ["resize", "-sectors", "409600", image.path])
        #expect(DiskImageTool.resize(image: image, sectors: 8, encrypted: true, tool: .hdiutil).args == ["resize", "-sectors", "8", "-stdinpass", image.path])
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
        #expect(DiskImageTool.encryptionCheck(image: image, tool: .hdiutil).args == ["isencrypted", image.path])
    }

    @Test func diskutilSizingCommands() {
        #expect(DiskImageTool.resizeLimits(image: image, tool: .diskutil).tool == "/usr/sbin/diskutil")
        #expect(DiskImageTool.resizeLimits(image: image, tool: .diskutil).args == ["image", "resize", "--plist", image.path])
        #expect(DiskImageTool.resizeLimits(image: image, encrypted: true, tool: .diskutil).args
                == ["image", "resize", "--plist", "--stdinpassphrase", image.path])
        // bytes, not sectors: diskutil's default unit
        #expect(DiskImageTool.resize(image: image, sectors: 409_600, tool: .diskutil).args
                == ["image", "resize", "--size", "209715200", image.path])
        #expect(DiskImageTool.resize(image: image, sectors: 8, encrypted: true, tool: .diskutil).args
                == ["image", "resize", "--size", "4096", "--stdinpassphrase", image.path])
        // always with a passphrase on stdin: without one it waits for someone to type it
        #expect(DiskImageTool.encryptionCheck(image: image, tool: .diskutil).args
                == ["image", "info", "--plist", "--stdinpassphrase", image.path])
        #expect(DiskImageTool.resize(image: image, sectors: 8, tool: .hdiutil).tool == "/usr/bin/hdiutil")
    }

    /// `diskutil image` is used only where it has what is asked of it
    @Test func theDiskutilProbe() {
        let full = ScriptedCommandRunner { _, args in
            CommandResult(status: 0, stdout: args.last == "resize" ? Self.resizeHelp : Self.infoHelp, stderr: "")
        }
        #expect(DiskImageTool.offersDiskutilImage(runner: full))
        // a diskutil without `image` (it lists its verbs and fails)
        let none = ScriptedCommandRunner { _, _ in
            CommandResult(status: 1, stdout: "", stderr: "Usage:  diskutil [quiet] <verb> <options>")
        }
        #expect(!DiskImageTool.offersDiskutilImage(runner: none))
        // one without an option used here
        let short = ScriptedCommandRunner { _, args in
            CommandResult(status: 0, stdout: args.last == "resize" ? "USAGE: diskutil image resize [--size <size>] <image-url>" : Self.infoHelp, stderr: "")
        }
        #expect(!DiskImageTool.offersDiskutilImage(runner: short))
        // never a disk-image step paused part way, whichever tool runs it
        #expect(RunControl.unsuspendable("/usr/sbin/diskutil") && RunControl.unsuspendable("/usr/libexec/diskimagesiod"))
        #expect(RunControl.unsuspendable("/usr/bin/hdiutil") && !RunControl.unsuspendable("/usr/bin/rsync"))
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

    @Test func diskutilLimitsAreReadInBytes() throws {
        let limits = try #require(DiskImageTool.limits(from: Self.diskutilLimits, tool: .diskutil))
        #expect(limits == DiskImageTool.Limits(minimum: 6_332_416, current: 104_857_600, maximum: 144_115_188_075_855_872))
        #expect(DiskImageTool.limits(from: "Error: Incorrect passphrase", tool: .diskutil) == nil)
        #expect(DiskImageTool.limits(from: Self.diskutilLimits, tool: .hdiutil) == nil)
    }

    @Test func diskutilEncryptionIsRead() {
        #expect(DiskImageTool.isEncrypted(from: Self.diskutilInfo(encrypted: 1), tool: .diskutil) == true)
        #expect(DiskImageTool.isEncrypted(from: Self.diskutilInfo(encrypted: 0), tool: .diskutil) == false)
        #expect(DiskImageTool.isEncrypted(from: "Error: Incorrect passphrase", tool: .diskutil) == nil)
        #expect(DiskImageTool.isEncrypted(from: Self.plist("<dict><key>Image Format</key><string>UDSB</string></dict>"),
                                          tool: .diskutil) == nil)
    }

    /// On a Mac where `diskutil image` is used, the real tools: what one resizes, the
    /// other reads at the new size, and both read an image's encryption the same way.
    @Test(.enabled(if: DiskImageTool.diskutilImageMeasured)) func diskutilAndHdiutilAgree() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("cf-dit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let pass = "pw-dit", key = Data("pw-dit".utf8)
        let plain = base.appendingPathComponent("p.sparsebundle"), sealed = base.appendingPathComponent("e.sparsebundle")
        for (bundle, encrypted) in [(plain, false), (sealed, true)] {
            let made = try TestDiskImages.run(DiskImageTool.sparseBundle(output: bundle, name: "DIT", sizeGB: 0, bandSectors: 16384,
                                                                         encrypted: encrypted, sectors: 204_800).args,
                                              stdin: encrypted ? key : nil)
            try #require(made.ok, "\(made.stderr)")
            let stdin = encrypted ? key : nil
            let before = try #require(DiskImageTool.limits(of: bundle, encrypted: encrypted, stdin: stdin, runner: ProcessCommandRunner(), tool: .diskutil))
            let old = try #require(DiskImageTool.limits(of: bundle, encrypted: encrypted, stdin: stdin, runner: ProcessCommandRunner(), tool: .hdiutil))
            #expect(before.current >= old.current && before.current - old.current <= 1 << 20, "\(before) \(old)")
            let grown = try ProcessCommandRunner().run(DiskImageTool.resize(image: bundle, sectors: 409_600, encrypted: encrypted, tool: .diskutil), stdin: stdin)
            try #require(grown.ok, "\(grown.stderr)")
            let after = try #require(DiskImageTool.limits(of: bundle, encrypted: encrypted, stdin: stdin, runner: ProcessCommandRunner(), tool: .hdiutil))
            #expect(after.current >= 409_600 * 512 * 99 / 100 && after.current <= 409_600 * 512, "\(after)")
            for tool in [DiskImageTool.Tool.hdiutil, .diskutil] {
                #expect(DiskImageTool.isEncrypted(bundle, passphrase: pass, runner: ProcessCommandRunner(), tool: tool) == encrypted, "\(tool)")
            }
        }
        // the wrong passphrase says nothing either way, and isn't taken for "not encrypted"
        #expect(DiskImageTool.isEncrypted(sealed, passphrase: "wrong", runner: ProcessCommandRunner(), tool: .diskutil) == nil)
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

    /// `diskutil image resize --plist` with no size, of a 100 MB sparse bundle
    static let diskutilLimits = plist("""
        <dict>
            <key>current</key><integer>104857600</integer>
            <key>max</key><integer>144115188075855872</integer>
            <key>min</key><integer>6332416</integer>
        </dict>
        """)

    /// `diskutil image info --plist` (trimmed: the partitions are left out)
    static func diskutilInfo(encrypted: Int) -> String {
        plist("""
            <dict>
                <key>Encryption Info</key>
                <dict><key>Is Encrypted</key><integer>\(encrypted)</integer></dict>
                <key>Format Description</key><string>Sparse bundle image</string>
                <key>Image Format</key><string>UDSB</string>
                <key>Size Info</key>
                <dict><key>Sector Count</key><integer>204800</integer><key>Total Bytes</key><integer>104857600</integer></dict>
            </dict>
            """)
    }

    /// the parts of `diskutil image resize` and `diskutil image info` help the probe reads
    static let resizeHelp = """
        USAGE: diskutil image resize [--verbose] [--stdinpassphrase] [--plist] [--size <size>] [--image-only] <image-url>
          --stdinpassphrase, --stdinpass
          --plist                 Produce output in a plist format
          -s, --size <size>       New size of the disk image or 'min' to resize to
        """
    static let infoHelp = """
        USAGE: diskutil image info [--verbose] [--stdinpassphrase] [--plist] [--extra] <image-url>
        """

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
