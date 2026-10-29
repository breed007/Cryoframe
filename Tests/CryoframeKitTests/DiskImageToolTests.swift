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
        #expect(DiskImageTool.encryptionCheck(image: image, tool: .hdiutil).args == ["isencrypted", image.path])
    }

    @Test func diskutilSizingCommands() {
        #expect(DiskImageTool.resizeLimits(image: image, tool: .diskutil).tool == "/usr/sbin/diskutil")
        #expect(DiskImageTool.resizeLimits(image: image, tool: .diskutil).args == ["image", "resize", "--plist", image.path])
        #expect(DiskImageTool.resizeLimits(image: image, encrypted: true, tool: .diskutil).args
                == ["image", "resize", "--plist", "--stdinpassphrase", image.path])
        // always with a passphrase on stdin: without one it waits for someone to type it
        #expect(DiskImageTool.encryptionCheck(image: image, tool: .diskutil).args
                == ["image", "info", "--plist", "--stdinpassphrase", image.path])
        // resizing is hdiutil's on every macOS (see anImageMadeAtAnOddSizeShrinksAndGrows)
        #expect(DiskImageTool.resize(image: image, sectors: 8).tool == "/usr/bin/hdiutil")
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
        #expect(RunControl.unsuspendable("/usr/sbin/diskutil", diskutilImage: true))
        #expect(RunControl.unsuspendable("/usr/libexec/diskimagesiod", diskutilImage: true))
        #expect(RunControl.unsuspendable("/usr/bin/hdiutil") && !RunControl.unsuspendable("/usr/bin/rsync"))
        // where hdiutil does every disk-image step, a diskutil step pauses as before 1.8
        #expect(!RunControl.unsuspendable("/usr/sbin/diskutil", diskutilImage: false))
        #expect(RunControl.unsuspendable("/usr/bin/hdiutil", diskutilImage: false))
    }

    /// Attach and eject through diskutil, behind a switch that is off in 1.8
    @Test func diskutilAttachingAndEjecting() {
        #expect(!DiskImageTool.attachesWithDiskutil)
        #expect(DiskImageTool.attach(image: image, mountpoint: mnt).tool == "/usr/bin/hdiutil")
        #expect(DiskImageTool.detach("/dev/disk9").tool == "/usr/bin/hdiutil")
        let rw = DiskImageTool.attach(image: image, mountpoint: mnt, tool: .diskutil)
        #expect(rw.tool == "/usr/sbin/diskutil")
        #expect(rw.args == ["image", "attach", "--plist", "--nobrowse", "--mountOptions", "owners", "--mountPoint", mnt.path, image.path])
        #expect(DiskImageTool.attach(image: image, mountpoint: mnt, readonly: true, encrypted: true, tool: .diskutil).args
                == ["image", "attach", "--plist", "--nobrowse", "--mountOptions", "owners", "--mountPoint", mnt.path,
                    "--readOnly", "--stdinpassphrase", image.path])
        #expect(DiskImageTool.attachWithoutMount(image: image, encrypted: true, verify: false, tool: .diskutil).args
                == ["image", "attach", "--plist", "--noMount", "--readOnly", "--stdinpassphrase", image.path])
        #expect(DiskImageTool.detach(mnt.path, tool: .diskutil).args == ["eject", mnt.path])
        #expect(DiskImageTool.detach("/dev/disk9", force: true, tool: .diskutil).args == ["eject", "force", "/dev/disk9"])
        #expect(DiskImageTool.isAttach(rw.tool, rw.args))
        #expect(ProcessCommandRunner.letsFinish(rw.tool, rw.args))
        #expect(!DiskImageTool.isAttach("/usr/sbin/diskutil", ["eject", mnt.path]))
        #expect(!DiskImageTool.isAttach("/usr/sbin/diskutil", ["image", "info", image.path]))
    }

    /// `diskutil image create` replaces what is there without a word
    @Test func noImageIsMadeOverAnything() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("cf-dit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let free = base.appendingPathComponent("new.sparsebundle")
        try DiskImageTool.refuseExisting(free)
        let file = base.appendingPathComponent("old.sparsebundle")
        try Data().write(to: file)
        #expect(throws: DiskImageExists(path: file.path)) { try DiskImageTool.refuseExisting(file) }
        let link = base.appendingPathComponent("link.sparsebundle")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: base.appendingPathComponent("gone").path)
        #expect(throws: DiskImageExists.self) { try DiskImageTool.refuseExisting(link) }
    }

    /// On a Mac where `diskutil image` is used, its attach as built here honors
    /// ownership, and its eject takes the image away.
    @Test(.enabled(if: DiskImageTool.diskutilImageMeasured)) func aDiskutilAttachHonorsOwners() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("cf-dit-\(UUID().uuidString)")
        let bundle = base.appendingPathComponent("o.sparsebundle"), at = base.appendingPathComponent("mnt")
        try FileManager.default.createDirectory(at: at, withIntermediateDirectories: true)
        defer { MountPoint.detach(at, runner: ProcessCommandRunner()); try? FileManager.default.removeItem(at: base) }
        let made = try TestDiskImages.run(DiskImageTool.sparseBundle(output: bundle, name: "DIT", sizeGB: 0, bandSectors: 16384,
                                                                     sectors: 102_400).args)
        try #require(made.ok, "\(made.stderr)")
        let attached = try DiskImageGate.serialized {
            try ProcessCommandRunner().runRetryingBusy(DiskImageTool.attach(image: bundle, mountpoint: at, readonly: true, tool: .diskutil))
        }
        try #require(attached.ok && MountPoint.isMounted(at), "\(attached.stderr)")
        let devices = DiskImageTool.devices(fromAttach: attached.stdout)
        #expect(devices.first?.node.hasPrefix("/dev/disk") == true && devices.contains { $0.content == "Apple_APFS_Volume" }, "\(devices)")
        var fs = statfs()
        try #require(statfs(at.path, &fs) == 0)
        #expect(fs.f_flags & UInt32(MNT_IGNORE_OWNERSHIP) == 0, "mounted ignoring owners")
        let ejected = try ProcessCommandRunner().runRetryingBusy(DiskImageTool.detach(at.path, tool: .diskutil))
        #expect(ejected.ok, "\(ejected.stderr)")
        #expect(!MountPoint.isMounted(at))
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

    /// On a Mac where `diskutil image` is used, the real tools: diskutil reads an image
    /// hdiutil resized at its new size, and both read an image's encryption the same way.
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
            let grown = try ProcessCommandRunner().run(DiskImageTool.resize(image: bundle, sectors: 409_600, encrypted: encrypted), stdin: stdin)
            try #require(grown.ok, "\(grown.stderr)")
            let after = try #require(DiskImageTool.limits(of: bundle, encrypted: encrypted, stdin: stdin, runner: ProcessCommandRunner(), tool: .diskutil))
            let bytes: UInt64 = 409_600 * 512
            #expect(after.current + bytes / 100 >= bytes && after.current <= bytes + bytes / 100, "\(after)")
            for tool in [DiskImageTool.Tool.hdiutil, .diskutil] {
                #expect(DiskImageTool.isEncrypted(bundle, passphrase: pass, runner: ProcessCommandRunner(), tool: tool) == encrypted, "\(tool)")
            }
        }
        // the wrong passphrase says nothing either way, and isn't taken for "not encrypted"
        #expect(DiskImageTool.isEncrypted(sealed, passphrase: "wrong", runner: ProcessCommandRunner(), tool: .diskutil) == nil)
    }

    /// On every macOS, an image made at an arbitrary sector count, as a mirror's is,
    /// shrinks and grows through the tools DiskImageTool picks. `diskutil image
    /// resize` shrank one whose count isn't a multiple of 8 (4 KB) and then failed
    /// with "Invalid argument" (measured on macOS 27.0.1: 199,963 sectors failed and
    /// 199,960 didn't), which failed the run; a stub that skipped resizing hid it.
    @Test func anImageMadeAtAnOddSizeShrinksAndGrows() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("cf-dit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let bundle = base.appendingPathComponent("odd.sparsebundle")
        let made = try TestDiskImages.run(DiskImageTool.sparseBundle(output: bundle, name: "DIT", sizeGB: 0, bandSectors: 16384,
                                                                     sectors: 199_963).args)
        try #require(made.ok, "\(made.stderr)")
        for target: UInt64 in [101_112, 150_000] {
            let resized = try DiskImageGate.serialized {
                try ProcessCommandRunner().runRetryingBusy(DiskImageTool.resize(image: bundle, sectors: target))
            }
            #expect(resized.ok, "\(target): \(resized.stderr)")
            let after = try #require(DiskImageTool.limits(of: bundle, encrypted: false, stdin: nil, runner: ProcessCommandRunner()))
            let bytes = target * 512
            #expect(after.current + bytes / 100 >= bytes && after.current <= bytes + bytes / 100, "\(target): \(after)")
        }
    }

    /// On a Mac where `diskutil image` is used: an encrypted image whose header is
    /// damaged (its first 8 bytes zeroed) reads as not encrypted through diskutil too,
    /// with the right passphrase or a wrong one, so the key check calls it damaged
    /// rather than taking it for a wrong passphrase.
    @Test(.enabled(if: DiskImageTool.diskutilImageMeasured)) func aDamagedHeaderReadsAsNotEncryptedThroughDiskutil() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("cf-dit-\(UUID().uuidString)")
        let root = base.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("notes".utf8).write(to: root.appendingPathComponent("a.txt"))
        let image = base.appendingPathComponent("e.dmg")
        let made = try TestDiskImages.run(DiskImageTool.folderImage(root: root, output: image, encrypted: true).args,
                                          stdin: Data("right".utf8))
        try #require(made.ok, "\(made.stderr)")
        #expect(DiskImageTool.isEncrypted(image, passphrase: "right", runner: ProcessCommandRunner(), tool: .diskutil) == true)
        let fh = try FileHandle(forWritingTo: image)
        try fh.write(contentsOf: Data(count: 8))
        try fh.close()
        for pass in ["right", "wrong"] {
            #expect(DiskImageTool.isEncrypted(image, passphrase: pass, runner: ProcessCommandRunner(), tool: .diskutil) == false, "\(pass)")
        }
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

    @Test func aDiskutilAttachsDevicesAreRead() {
        let devices = DiskImageTool.devices(fromAttach: Self.diskutilAttach)
        #expect(devices.map(\.node) == ["/dev/disk25", "/dev/disk25s1", "/dev/disk26", "/dev/disk26s1"])
        #expect(devices.first { $0.content.contains("Apple_APFS") }?.node == "/dev/disk25s1")
        #expect(DiskImageTool.devices(fromAttach: "Error: Incorrect passphrase").isEmpty)
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

    /// `diskutil image attach --plist --noMount` (trimmed: sizes and names left out)
    static let diskutilAttach = plist("""
        <dict>
            <key>system-entities</key>
            <array>
                <dict><key>content-hint</key><string>GUID_partition_scheme</string><key>dev-entry</key><string>disk25</string></dict>
                <dict><key>content-hint</key><string>Apple_APFS</string><key>dev-entry</key><string>disk25s1</string></dict>
                <dict><key>content-hint</key><string>Apple_APFS_Container</string><key>dev-entry</key><string>disk26</string></dict>
                <dict><key>content-hint</key><string>Apple_APFS_Volume</string><key>dev-entry</key><string>disk26s1</string>
                      <key>filesystem-type</key><string>apfs</string></dict>
            </array>
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
