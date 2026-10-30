import Foundation
import Testing
@testable import CryoframeKit

/// The tests' own disk-image setup and cleanup: making, attaching and detaching the
/// images a test works on.
///
/// These run hdiutil from DiskImageTool and retry the way the app's own disk-image
/// commands do (CommandRunner.runRetryingBusy): while the disk-image system answers
/// "Resource temporarily unavailable" or "Resource busy", a few tries with a short
/// backoff, and never past a refusal, or an attach of an image that is already open.
/// Without it, a test failed in its own setup whenever the machine was briefly busy
/// with disk images (seen on the macOS 15 runner, on unchanged code), which said
/// nothing about the code under test.
///
/// macOS also attaches each fresh disk image by itself, to scan it: an attach with
/// "system-image: TRUE" and nothing mounted, made as the user who wrote the image.
/// Under a full suite on a CI runner that scan has held an image for over a minute.
/// While it does, an attach of the image answers "Resource temporarily unavailable",
/// the app refuses it as attached elsewhere (DiskImageInUse, attachedWithoutMount),
/// and it shows in `hdiutil info`. None of that is the code under test, so a test
/// waits for the scan of an image it made before using it (`settle`), and asks what
/// is attached with `attaches(of:)`, which leaves the scan out.
enum TestDiskImages {
    static func run(_ args: [String], stdin: Data? = nil) throws -> CommandResult {
        try ProcessCommandRunner().runRetryingBusy(DiskImageTool.hdiutil, args, stdin: stdin)
    }

    /// One attach of a disk image, as the text form of `hdiutil info` lists it. Read
    /// from the text: macOS 27's `-plist` form has no system-image key (measured).
    struct Attach: Equatable {
        /// the image's path, canonical (see TMUtilSnapshotBackend.canonicalPath)
        let path: String
        let systemImage: Bool
        let devices: [String]
        let mountPoints: [String]
        /// macOS's own look at a fresh image. Cryoframe never attaches as a system
        /// image, so an attach of its, mounted or not, is never one of these.
        var isScan: Bool { systemImage && mountPoints.isEmpty }
    }

    /// every attach on this Mac; nil when hdiutil couldn't be asked
    static func attaches() -> [Attach]? {
        guard let r = try? ProcessCommandRunner().run(DiskImageTool.hdiutil, ["info"]), r.ok else { return nil }
        return attaches(fromInfo: r.stdout)
    }

    static func attaches(fromInfo text: String) -> [Attach] {
        text.components(separatedBy: "================================================").compactMap { block in
            let lines = block.split(separator: "\n").map(String.init)
            func value(_ key: String) -> String? {
                lines.first { $0.hasPrefix(key) && $0.contains(":") }
                    .map { String($0[$0.index(after: $0.firstIndex(of: ":")!)...]).trimmingCharacters(in: .whitespaces) }
            }
            guard let path = value("image-path") else { return nil }
            var devices: [String] = [], mounts: [String] = []
            for line in lines where line.hasPrefix("/dev/") {
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                devices.append(fields[0].trimmingCharacters(in: .whitespaces))
                let mount = fields.count > 2 ? fields[2].trimmingCharacters(in: .whitespaces) : ""
                if !mount.isEmpty { mounts.append(mount) }
            }
            return Attach(path: TMUtilSnapshotBackend.canonicalPath(path), systemImage: value("system-image") == "TRUE",
                          devices: devices, mountPoints: mounts)
        }
    }

    /// The attaches of `image` other than macOS's scan of it: the code under test's,
    /// or a test's own. Empty when hdiutil couldn't be asked.
    static func attaches(of image: URL) -> [Attach] {
        let target = TMUtilSnapshotBackend.canonicalPath(image.path)
        return (attaches() ?? []).filter { $0.path == target && !$0.isScan }
    }

    /// the attaches of any image inside `folder`, other than macOS's scans
    static func attaches(inside folder: URL) -> [Attach] {
        let prefix = TMUtilSnapshotBackend.canonicalPath(folder.path) + "/"
        return (attaches() ?? []).filter { $0.path.hasPrefix(prefix) && !$0.isScan }
    }

    /// `attaches(of:)`, waited on for up to `seconds` to be empty: a detach the code
    /// under test asked for can take a moment to show
    static func leftovers(of image: URL, within seconds: TimeInterval = 10) -> [Attach] {
        let until = ProcessInfo.processInfo.systemUptime + seconds
        while true {
            let left = attaches(of: image)
            if left.isEmpty || ProcessInfo.processInfo.systemUptime >= until { return left }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    /// Wait, up to `seconds`, for macOS to finish scanning the images a test just made
    /// (each image, or every image inside each folder given), so the code under test
    /// gets them as a user's Mac has them by the time a check or a restore opens them.
    /// The scan starts a moment after the image is written, so a short `grace` is
    /// given for it to show before the image is taken as unscanned.
    static func settle(_ images: URL..., grace: TimeInterval = 1, within seconds: TimeInterval = 180) {
        let targets = images.map { TMUtilSnapshotBackend.canonicalPath($0.path) }
        func scanned(_ a: Attach) -> Bool {
            a.isScan && targets.contains { a.path == $0 || a.path.hasPrefix($0 + "/") }
        }
        let start = ProcessInfo.processInfo.systemUptime
        var seen = false
        while ProcessInfo.processInfo.systemUptime - start < seconds {
            let scanning = (attaches() ?? []).contains(where: scanned)
            seen = seen || scanning
            if !scanning, seen || ProcessInfo.processInfo.systemUptime - start >= grace { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    /// An archive a test just built, opened once macOS has scanned it. A scan that
    /// starts only after `settle` gave up waiting for one is waited out too: the reader
    /// refuses an image held that way (an encrypted one always), as it should.
    static func open(_ result: ArchiveResult, passphrase: String? = nil) throws -> OpenedArchive {
        for image in result.artifacts { settle(image) }
        let until = Date().addingTimeInterval(60)
        while true {
            do { return try ArchiveReader(runner: ProcessCommandRunner()).open(result, passphrase: passphrase) }
            catch let e as DiskImageInUse where e.attachedWithoutMount && Date() < until { Thread.sleep(forTimeInterval: 1) }
        }
    }

    /// A restore of an archive a test just built, once macOS has scanned it, waiting
    /// out a disk-image system kept busy (EAGAIN) by other tests attaching at the same
    /// time: the restore's own one retry wasn't always enough under a full suite.
    static func restore(_ archive: RestorableArchive, to dir: URL, passphrase: String? = nil) throws -> URL {
        settle(archive.dir)
        let until = Date().addingTimeInterval(60)
        while true {
            do { return try RestoreEngine().restore(archive, to: dir, passphrase: passphrase) }
            catch let ArchiveError.toolFailed(_, _, stderr) where ProcessCommandRunner.isTransient(stderr) && Date() < until {
                Thread.sleep(forTimeInterval: 2)
            } catch let e as DiskImageInUse where e.attachedWithoutMount && Date() < until {
                Thread.sleep(forTimeInterval: 2)        // an encrypted image the scan holds is refused
            }
        }
    }
}

// MARK: - reading hdiutil info

// Trimmed from the macOS 15 runner's `hdiutil info` (CI, 2026-10-30): a test's image
// mounted, the same image under macOS's scan, and another held with -nomount.
@Test func theScanIsToldApartFromEveryOtherAttach() {
    let info = """
        framework       : 671.140.2.700.3
        driver          : 671.140.2.700.3
        images          : 3
        ================================================
        image-path      : /private/var/folders/nj/T/cf-x/dest/Alpha/Alpha.dmg
        system-image    : false
        mounting user   : runner
        /dev/disk51\tGUID_partition_scheme\t
        /dev/disk51s1\t7C3457EF-0000-11AA-AA11-00306543ECAC\t
        /dev/disk52\tEF57347C-0000-11AA-AA11-00306543ECAC\t
        /dev/disk52s1\t41504653-0000-11AA-AA11-00306543ECAC\t/private/var/folders/nj/T/cf-open-1/mnt
        ================================================
        image-path      : /private/var/folders/nj/T/cf-x/dest/Alpha/Alpha.dmg
        system-image    : TRUE
        mounting user   : runner
        /dev/disk55\tGUID_partition_scheme\t
        /dev/disk56s1\t41504653-0000-11AA-AA11-00306543ECAC\t
        ================================================
        image-path      : /private/var/folders/nj/T/cf-x/dest/Bravo/Bravo.dmg
        system-image    : false
        /dev/disk60\tGUID_partition_scheme\t
        """
    let all = TestDiskImages.attaches(fromInfo: info)
    #expect(all.map(\.isScan) == [false, true, false])
    #expect(all[0].path == "/var/folders/nj/T/cf-x/dest/Alpha/Alpha.dmg")
    #expect(all[0].devices.count == 4 && all[0].mountPoints == ["/private/var/folders/nj/T/cf-open-1/mnt"])
    #expect(all[2].devices == ["/dev/disk60"] && all[2].mountPoints.isEmpty)
    #expect(TestDiskImages.attaches(fromInfo: "hdiutil: info failed").isEmpty)
}
