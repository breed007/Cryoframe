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

    // MARK: - Size

    /// The smallest, current and largest size an image can have, in bytes.
    public struct Limits: Sendable, Equatable {
        public let minimum: UInt64
        public let current: UInt64
        public let maximum: UInt64
    }

    /// the command that prints the image's size limits (see `limits(from:)`)
    public static func resizeLimits(image: URL, encrypted: Bool = false) -> Command {
        Command(hdiutil, ["resize", "-limits"] + (encrypted ? ["-stdinpass"] : []) + [image.path])
    }

    /// The limits `resizeLimits` printed: "min<TAB>current<TAB>max", in 512-byte
    /// sectors. nil when the output isn't that.
    public static func limits(from stdout: String) -> Limits? {
        let f = stdout.split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" })
        guard f.count >= 3, let min = UInt64(f[0]), let current = UInt64(f[1]), let max = UInt64(f[2]) else { return nil }
        return Limits(minimum: min * 512, current: current * 512, maximum: max > UInt64.max / 512 ? .max : max * 512)
    }

    /// Grow or shrink an image, and the APFS volume inside it, to `sectors` 512-byte
    /// sectors. Measured on APFS sparse bundles, plain and encrypted: the mounted
    /// volume reports the new size.
    public static func resize(image: URL, sectors: UInt64, encrypted: Bool = false) -> Command {
        Command(hdiutil, ["resize", "-sectors", "\(sectors)"] + (encrypted ? ["-stdinpass"] : []) + [image.path])
    }

    // MARK: - Encryption

    /// The command that says whether `image` is encrypted. It reads the image's
    /// header and needs no passphrase.
    public static func encryptionCheck(image: URL) -> Command {
        Command(hdiutil, ["isencrypted", image.path])
    }

    /// whether `encryptionCheck` found the image encrypted; nil when its output says neither
    public static func isEncrypted(from stdout: String) -> Bool? {
        if stdout.contains("encrypted: NO") { return false }
        if stdout.contains("encrypted: YES") { return true }
        return nil
    }

    // MARK: - Attaching

    /// Attach an image at a known mount point, without showing it in the Finder, with
    /// ownership honored. `readonly` for reading and checking; read-write for the
    /// mirror's rsync. `encrypted` reads the passphrase from stdin.
    public static func attach(image: URL, mountpoint: URL, readonly: Bool = false, encrypted: Bool = false) -> Command {
        var args = ["attach", image.path, "-mountpoint", mountpoint.path, "-nobrowse", "-owners", "on"]
        if readonly { args.append("-readonly") }
        if encrypted { args.append("-stdinpass") }
        return Command(hdiutil, args)
    }

    /// Attach an image read-only as devices, with nothing mounted. `verify` false skips
    /// the checksum and the file-system check, for an attach that only proves the key.
    public static func attachWithoutMount(image: URL, encrypted: Bool, verify: Bool = true) -> Command {
        var args = ["attach", "-nomount", "-readonly", "-nobrowse"]
        if !verify { args += ["-noverify", "-noautofsck"] }
        if encrypted { args.append("-stdinpass") }
        return Command(hdiutil, args + [image.path])
    }

    /// One device an attach handed back, and what it holds ("GUID_partition_scheme",
    /// "Apple_APFS", a partition type).
    public struct Device: Sendable, Equatable {
        public let node: String         // "/dev/disk7s1"
        public let content: String
    }

    /// The devices an attach printed, the image's own disk first. hdiutil prints one
    /// line a device: its node, then what it holds.
    public static func devices(fromAttach stdout: String) -> [Device] {
        stdout.split(separator: "\n").compactMap { line in
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let node = f.first, node.hasPrefix("/dev/") else { return nil }
            return Device(node: String(node), content: f.count > 1 ? String(f[1]) : "")
        }
    }

    // MARK: - Detaching

    /// Detach the image attached as `target` (a mount point or a device), taking every
    /// device of it away. `force` detaches it even while files on it are open.
    public static func detach(_ target: String, force: Bool = false) -> Command {
        Command(hdiutil, ["detach", target] + (force ? ["-force"] : []))
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
        guard let data = stdout.data(using: .utf8),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
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

    // MARK: - What a command is

    /// whether `launchPath` and `args` attach an image
    static func isAttach(_ launchPath: String, _ args: [String]) -> Bool {
        (launchPath as NSString).lastPathComponent == "hdiutil" && args.first == "attach"
    }

    /// Whether `launchPath` and `args` make an empty image: a sparse bundle, not one
    /// made from a folder.
    static func isBlankCreate(_ launchPath: String, _ args: [String]) -> Bool {
        (launchPath as NSString).lastPathComponent == "hdiutil" && args.first == "create" && !args.contains("-srcfolder")
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
