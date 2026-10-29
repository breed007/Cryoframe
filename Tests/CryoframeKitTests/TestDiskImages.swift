import Foundation
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
enum TestDiskImages {
    static func run(_ args: [String], stdin: Data? = nil) throws -> CommandResult {
        try ProcessCommandRunner().runRetryingBusy(DiskImageTool.hdiutil, args, stdin: stdin)
    }
}
