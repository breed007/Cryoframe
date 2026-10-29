//
//  DiskImageTool.swift
//  CryoframeKit
//
//  Every disk-image command Cryoframe runs is built here, and what each one prints is
//  read here. Nothing else names the disk-image tools: a test fails on any
//  "/usr/bin/hdiutil" in the sources outside this file.
//
//  macOS 27 deprecates hdiutil in favor of `diskutil image`, which doesn't cover every
//  verb Cryoframe needs: it has no band size for a sparse bundle, no -noverify, no
//  compact, no list of what is attached, and no size for an image made from a folder
//  (measured on macOS 27.0.1). Keeping every command in one place lets each verb move
//  on its own once it is measured to behave the same.
//
//  Output is read from property lists wherever the tool offers one, never from
//  columns that can shift between releases. The one exception is hdiutil's text from
//  an attach and from isencrypted, read as it always has been.
//

import Foundation

public enum DiskImageTool {
    static let hdiutil = "/usr/bin/hdiutil"
    static let diskutil = "/usr/sbin/diskutil"

    /// The tool a command runs.
    public enum Tool: Sendable, Equatable { case hdiutil, diskutil }

    /// The tool that reads an image's size limits and says whether it is encrypted:
    /// `diskutil image` where it was measured to do the same as hdiutil, otherwise
    /// hdiutil. Measured on macOS 27.0.1: the same limits within 80 sectors (hdiutil's
    /// "current" leaves out the partition map), and the same refusal of a wrong
    /// passphrase. Decided once per process. Resizing is hdiutil's everywhere (see
    /// `resize`).
    public static var sizing: Tool { diskutilImageMeasured ? .diskutil : .hdiutil }

    /// Attach and detach through `diskutil image`: off in 1.8. Its attach is served by
    /// diskimagesiod rather than diskimages-helper (measured on macOS 27.0.1), and
    /// what Cryoframe knows of an attach in progress was measured against the latter:
    /// the process an attach record follows, the tool watchdog's count of the helper's
    /// work, Pause's refusal to stop it, and the wait for a saturated disk-image system
    /// (see AttachRecords, ToolWatchdog, RunControl, DiskImageGate). Each needs
    /// measuring again before this is turned on.
    public static let attachesWithDiskutil = false

    /// the tool that attaches and detaches images (see `attachesWithDiskutil`)
    public static var attaching: Tool { attachesWithDiskutil ? .diskutil : .hdiutil }

    /// Whether this Mac's diskutil has `image resize` and `image info` with the options
    /// used here. Only macOS 27 was measured, so an older macOS keeps hdiutil even if
    /// it has them.
    static let diskutilImageMeasured: Bool = {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 else { return false }
        return offersDiskutilImage(runner: ProcessCommandRunner(quietLimit: 60))
    }()

    /// whether `runner`'s diskutil prints the help for `image resize` and `image info`
    /// with every option those commands are given here
    static func offersDiskutilImage(runner: CommandRunner) -> Bool {
        func offers(_ verb: String, _ options: [String]) -> Bool {
            guard let r = try? runner.run(diskutil, ["image", verb], stdin: nil), r.ok else { return false }
            let help = r.stdout + r.stderr
            return options.allSatisfy { help.contains($0) }
        }
        return offers("resize", ["--plist", "--size", "--stdinpassphrase"]) && offers("info", ["--plist", "--stdinpassphrase"])
    }

    // MARK: - Making images

    /// A read-only compressed image of the folder `root`. (hdiutil -segmentSize is
    /// deprecated and ignored for -srcfolder, so splitting is done afterwards with
    /// split(1): see ArchivePlan.split.) `sizeMB`, when given, sets the size of the file
    /// system the folder is copied into, instead of hdiutil's own guess (see DMGSizing).
    /// An image already at `output` is replaced (-ov).
    public static func folderImage(root: URL, output: URL, encrypted: Bool = false, sizeMB: UInt64? = nil) -> Command {
        var args = ["create", "-srcfolder", root.path, "-format", "UDZO"]
        if let sizeMB { args += ["-size", "\(sizeMB)m"] }
        if encrypted { args += ["-encryption", "AES-256", "-stdinpass"] }   // passphrase via stdin
        args += ["-ov", output.path]
        return Command(hdiutil, args)
    }

    /// An empty APFS sparse bundle with bands of `bandSectors` 512-byte sectors.
    /// `sectors`, when given, sets the size in sectors instead of `sizeGB`.
    public static func sparseBundle(output: URL, name: String, sizeGB: Int, bandSectors: Int,
                                    encrypted: Bool = false, sectors: UInt64? = nil) -> Command {
        let size = sectors.map { ["-sectors", "\($0)"] } ?? ["-size", "\(sizeGB)g"]
        var args = ["create", "-type", "SPARSEBUNDLE", "-fs", "APFS"] + size + ["-volname", name,
                    "-imagekey", "sparse-band-size=\(bandSectors)"]
        if encrypted { args += ["-encryption", "AES-256", "-stdinpass"] }
        args += [output.path]
        return Command(hdiutil, args)
    }

    /// Refuse to make an image where something already is. `diskutil image create`
    /// replaces an existing image without a word (measured: a new image, exit 0), and
    /// hdiutil does with -ov, so every image made that must not replace one is checked
    /// here first, whichever tool makes it. A link counts, even one to nothing.
    public static func refuseExisting(_ output: URL) throws {
        var st = stat()
        if lstat(output.path, &st) == 0 { throw DiskImageExists(path: output.path) }
    }

    // MARK: - Size

    /// The smallest, current and largest size an image can have, in bytes.
    public struct Limits: Sendable, Equatable {
        public let minimum: UInt64
        public let current: UInt64
        public let maximum: UInt64
    }

    /// the command that prints the image's size limits (see `limits(from:tool:)`).
    /// diskutil prints them with no size given.
    public static func resizeLimits(image: URL, encrypted: Bool = false, tool: Tool = sizing) -> Command {
        switch tool {
        case .hdiutil:  return Command(hdiutil, ["resize", "-limits"] + (encrypted ? ["-stdinpass"] : []) + [image.path])
        case .diskutil: return Command(diskutil, ["image", "resize", "--plist"] + (encrypted ? ["--stdinpassphrase"] : []) + [image.path])
        }
    }

    /// The limits `resizeLimits` printed; nil when the output isn't them. hdiutil
    /// prints "min<TAB>current<TAB>max" in 512-byte sectors, diskutil a property list
    /// of the three in bytes.
    public static func limits(from stdout: String, tool: Tool = .hdiutil) -> Limits? {
        switch tool {
        case .hdiutil:
            let f = stdout.split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" })
            guard f.count >= 3, let min = UInt64(f[0]), let current = UInt64(f[1]), let max = UInt64(f[2]) else { return nil }
            return Limits(minimum: min * 512, current: current * 512, maximum: max > UInt64.max / 512 ? .max : max * 512)
        case .diskutil:
            guard let d = dictionary(stdout), let min = (d["min"] as? NSNumber)?.uint64Value,
                  let current = (d["current"] as? NSNumber)?.uint64Value,
                  let max = (d["max"] as? NSNumber)?.uint64Value else { return nil }
            return Limits(minimum: min, current: current, maximum: max)
        }
    }

    /// `image`'s limits, asked of `runner` with `stdin` (the passphrase, when it is
    /// encrypted); nil when they couldn't be told
    static func limits(of image: URL, encrypted: Bool, stdin: Data?, runner: CommandRunner, tool: Tool = sizing) -> Limits? {
        guard let r = try? runner.run(resizeLimits(image: image, encrypted: encrypted, tool: tool), stdin: stdin), r.ok else { return nil }
        return limits(from: r.stdout, tool: tool)
    }

    /// Grow or shrink an image, and the APFS volume inside it, to `sectors` 512-byte
    /// sectors, with hdiutil on every macOS. Measured on APFS sparse bundles, plain and
    /// encrypted: the mounted volume reports the new size. `diskutil image resize`
    /// isn't used: on macOS 27.0.1 it shrinks an image whose sector count isn't a
    /// multiple of 8, as a mirror's made at whatever size its drive allows can be, and
    /// then exits 1 with "Invalid argument". hdiutil exits 0 on the same image.
    public static func resize(image: URL, sectors: UInt64, encrypted: Bool = false) -> Command {
        Command(hdiutil, ["resize", "-sectors", "\(sectors)"] + (encrypted ? ["-stdinpass"] : []) + [image.path])
    }

    // MARK: - Encryption

    /// The command that says whether `image` is encrypted. hdiutil reads the image's
    /// header and needs no passphrase. diskutil is always given one on stdin: asked
    /// of an encrypted image without it, it waited for one with nobody to type it
    /// (measured: still waiting after five minutes). Given one, a plain image reads as
    /// not encrypted, and an encrypted image with the wrong one fails, which says
    /// nothing either way (measured).
    public static func encryptionCheck(image: URL, tool: Tool = sizing) -> Command {
        switch tool {
        case .hdiutil:  return Command(hdiutil, ["isencrypted", image.path])
        case .diskutil: return Command(diskutil, ["image", "info", "--plist", "--stdinpassphrase", image.path])
        }
    }

    /// whether `encryptionCheck` found the image encrypted; nil when its output says neither
    public static func isEncrypted(from stdout: String, tool: Tool = .hdiutil) -> Bool? {
        switch tool {
        case .hdiutil:
            if stdout.contains("encrypted: NO") { return false }
            if stdout.contains("encrypted: YES") { return true }
            return nil
        case .diskutil:
            guard let info = dictionary(stdout)?["Encryption Info"] as? [String: Any],
                  let encrypted = info["Is Encrypted"] as? NSNumber else { return nil }
            return encrypted.boolValue
        }
    }

    /// whether `image` reads as encrypted, asked of `runner` (diskutil with
    /// `passphrase` on stdin); nil when that couldn't be told
    static func isEncrypted(_ image: URL, passphrase: String, runner: CommandRunner, tool: Tool = sizing) -> Bool? {
        let stdin = tool == .diskutil ? Data(passphrase.utf8) : nil
        guard let r = try? runner.run(encryptionCheck(image: image, tool: tool), stdin: stdin), r.ok else { return nil }
        return isEncrypted(from: r.stdout, tool: tool)
    }

    // MARK: - Attaching

    /// Attach an image at a known mount point, without showing it in the Finder, with
    /// ownership honored. `readonly` for reading and checking; read-write for the
    /// mirror's rsync. `encrypted` reads the passphrase from stdin.
    /// diskutil mounts without ownership unless told (measured, read-only and
    /// read-write), and the read-back's comparison of owners then fails on every file,
    /// so it is always given `--mountOptions owners`.
    public static func attach(image: URL, mountpoint: URL, readonly: Bool = false, encrypted: Bool = false,
                              tool: Tool = attaching) -> Command {
        switch tool {
        case .hdiutil:
            var args = ["attach", image.path, "-mountpoint", mountpoint.path, "-nobrowse", "-owners", "on"]
            if readonly { args.append("-readonly") }
            if encrypted { args.append("-stdinpass") }
            return Command(hdiutil, args)
        case .diskutil:
            var args = ["image", "attach", "--plist", "--nobrowse", "--mountOptions", "owners", "--mountPoint", mountpoint.path]
            if readonly { args.append("--readOnly") }
            if encrypted { args.append("--stdinpassphrase") }
            return Command(diskutil, args + [image.path])
        }
    }

    /// Attach an image read-only as devices, with nothing mounted. `verify` false skips
    /// the checksum and the file-system check, for an attach that only proves the key;
    /// diskutil has no way to skip them.
    public static func attachWithoutMount(image: URL, encrypted: Bool, verify: Bool = true, tool: Tool = attaching) -> Command {
        switch tool {
        case .hdiutil:
            var args = ["attach", "-nomount", "-readonly", "-nobrowse"]
            if !verify { args += ["-noverify", "-noautofsck"] }
            if encrypted { args.append("-stdinpass") }
            return Command(hdiutil, args + [image.path])
        case .diskutil:
            return Command(diskutil, ["image", "attach", "--plist", "--noMount", "--readOnly"]
                           + (encrypted ? ["--stdinpassphrase"] : []) + [image.path])
        }
    }

    /// One device an attach handed back, and what it holds ("GUID_partition_scheme",
    /// "Apple_APFS", a partition type).
    public struct Device: Sendable, Equatable {
        public let node: String         // "/dev/disk7s1"
        public let content: String
    }

    /// The devices an attach printed, the image's own disk first. hdiutil prints one
    /// line a device: its node, then what it holds. diskutil prints a property list
    /// whose nodes have no "/dev/" (measured: "disk25s1").
    public static func devices(fromAttach stdout: String) -> [Device] {
        if let entities = dictionary(stdout)?["system-entities"] as? [[String: Any]] {
            return entities.compactMap { e in
                guard let node = e["dev-entry"] as? String, !node.isEmpty else { return nil }
                return Device(node: node.hasPrefix("/dev/") ? node : "/dev/" + node, content: e["content-hint"] as? String ?? "")
            }
        }
        return stdout.split(separator: "\n").compactMap { line in
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let node = f.first, node.hasPrefix("/dev/") else { return nil }
            return Device(node: String(node), content: f.count > 1 ? String(f[1]) : "")
        }
    }

    // MARK: - Detaching

    /// Detach the image attached as `target` (a mount point or a device), taking every
    /// device of it away. `force` detaches it even while files on it are open (not
    /// measured with diskutil's eject).
    public static func detach(_ target: String, force: Bool = false, tool: Tool = attaching) -> Command {
        switch tool {
        case .hdiutil:  return Command(hdiutil, ["detach", target] + (force ? ["-force"] : []))
        case .diskutil: return Command(diskutil, ["eject"] + (force ? ["force"] : []) + [target])
        }
    }

    /// Unmount the volume at `mountpoint` and leave its device attached.
    public static func unmount(_ mountpoint: String, force: Bool = false) -> Command {
        Command(hdiutil, ["unmount", mountpoint] + (force ? ["-force"] : []))
    }

    // MARK: - Upkeep

    /// Give the drive back the bands a sparse image no longer uses. -puppetstrings
    /// prints progress as it goes, which the tool watchdog counts (the disk-image
    /// daemon does the work, and hdiutil itself can sit idle).
    public static func compact(image: URL, encrypted: Bool = false) -> Command {
        Command(hdiutil, ["compact", "-puppetstrings", image.path] + (encrypted ? ["-stdinpass"] : []))
    }

    // MARK: - What is attached

    /// the command that lists every disk image attached on this Mac (see `attaches(from:)`)
    public static func info() -> Command { Command(hdiutil, ["info", "-plist"]) }

    /// Every attach `info` listed; nil when its output can't be read, which isn't the
    /// same as nothing attached. The list is absent from it when nothing is.
    static func attaches(from stdout: String) -> [MirrorMounts.Attach]? {
        guard let root = dictionary(stdout) else { return nil }
        let images = root["images"] as? [[String: Any]] ?? []
        return images.compactMap { img in
            guard let path = img["image-path"] as? String else { return nil }
            let entities = img["system-entities"] as? [[String: Any]] ?? []
            return MirrorMounts.Attach(path: path, devices: entities.compactMap { $0["dev-entry"] as? String },
                                       mountPoints: entities.compactMap { $0["mount-point"] as? String },
                                       helper: (img["hdid-pid"] as? NSNumber)?.int32Value)
        }
    }

    /// every attach on this Mac, asked of `runner`; nil when that couldn't be told
    static func attaches(runner: CommandRunner) -> [MirrorMounts.Attach]? {
        guard let r = try? runner.run(info()), r.ok else { return nil }
        return attaches(from: r.stdout)
    }

    /// the top-level dictionary of a property list a tool printed
    static func dictionary(_ stdout: String) -> [String: Any]? {
        guard let data = stdout.data(using: .utf8) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    // MARK: - What a command is

    /// whether `launchPath` and `args` attach an image
    static func isAttach(_ launchPath: String, _ args: [String]) -> Bool {
        switch (launchPath as NSString).lastPathComponent {
        case "hdiutil":  return args.first == "attach"
        case "diskutil": return args.starts(with: ["image", "attach"])
        default:         return false
        }
    }

    /// Whether `launchPath` and `args` make an empty image: a sparse bundle, not one
    /// made from a folder.
    static func isBlankCreate(_ launchPath: String, _ args: [String]) -> Bool {
        (launchPath as NSString).lastPathComponent == "hdiutil" && args.first == "create" && !args.contains("-srcfolder")
    }
}

/// An image wasn't made because something is already at its path (see
/// DiskImageTool.refuseExisting).
public struct DiskImageExists: Error, Equatable, LocalizedError {
    public let path: String
    public var errorDescription: String? {
        "Something is already at \(path), so a new disk image wasn't made over it."
    }
}

public extension CommandRunner {
    func run(_ command: Command, stdin: Data? = nil) throws -> CommandResult {
        try run(command.tool, command.args, stdin: stdin)
    }

    func runRetryingBusy(_ command: Command, stdin: Data? = nil) throws -> CommandResult {
        try runRetryingBusy(command.tool, command.args, stdin: stdin)
    }
}
