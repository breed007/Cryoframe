//
//  CloudProviderTests.swift
//  CryoframeKitTests
//

import Testing
import Foundation
@testable import CryoframeKit

@Test func identifyMatchesProviderByPath() {
    func id(_ p: String) -> CloudProvider { CloudProvider.identify(URL(fileURLWithPath: p)) }
    #expect(id("/Users/x/Library/CloudStorage/OneDrive-Personal/Backups") == .oneDrive)
    #expect(id("/Users/x/Library/CloudStorage/OneDrive-Contoso") == .oneDrive)
    #expect(id("/Users/x/Library/CloudStorage/Dropbox/Backups") == .dropbox)
    #expect(id("/Users/x/Library/CloudStorage/GoogleDrive-me@x.com/My Drive") == .googleDrive)
    #expect(id("/Users/x/Library/CloudStorage/Box-Box") == .box)
    #expect(id("/Users/x/Library/Mobile Documents/com~apple~CloudDocs/Backups") == .iCloud)
    #expect(id("/Users/x/Dropbox") == .dropbox)
    #expect(id("/Users/x/Documents/SomeFolder") == .generic)
    // tightened matching: an unrelated folder isn't misread as a provider folder
    #expect(id("/Users/x/OneDriveBackups") == .generic)
    #expect(id("/Users/x/Boxes/stuff") == .generic)
    #expect(id("/Users/x/Library/CloudStorage/OneDrive - Contoso/B") == .oneDrive)
}

@Test func providerPlansOfferTheRightTiers() {
    #expect(CloudProvider.box.plans.map(\.name) == ["Free / Starter", "Business", "Enterprise"])
    #expect(CloudProvider.box.plans.map(\.bytes) == [5_000_000_000, 50_000_000_000, 150_000_000_000])
    #expect(CloudProvider.iCloud.plans.count == 1)
    #expect(CloudProvider.box.maxSingleFileBytes == CloudProvider.box.plans.first?.bytes)   // default = first plan
}

@Test func perProviderSingleFileCapsDiffer() {
    let g: UInt64 = 1_000_000_000
    #expect(CloudProvider.iCloud.maxSingleFileBytes == 50 * g)    // hard 50 GB limit
    #expect(CloudProvider.box.maxSingleFileBytes == 5 * g)        // free/Starter floor
    #expect(CloudProvider.oneDrive.maxSingleFileBytes == 240 * g)
    #expect(CloudProvider.generic.maxSingleFileBytes == 240 * g)
}

@Test func cloudTargetCarriesProviderAndDerivesCap() {
    let t = Target.cloudSyncFolder(id: "i", name: "iCloud", dir: URL(fileURLWithPath: "/x"), provider: .iCloud)
    #expect(t.cloudProvider == .iCloud)
    #expect(t.constraints.maxSingleFileBytes == 50_000_000_000)
    // a paid-plan override still works
    let box = Target.cloudSyncFolder(id: "b", name: "Box", dir: URL(fileURLWithPath: "/y"),
                                     provider: .box, maxFileBytes: 150_000_000_000)
    #expect(box.constraints.maxSingleFileBytes == 150_000_000_000)
}

@Test func detectFindsProviderFoldersUnderAFakeHome() throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent("cf-cloud-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: home) }
    let cs = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
    for sub in ["OneDrive-Personal", "Dropbox", "Box-Box", "NotACloud"] {
        try fm.createDirectory(at: cs.appendingPathComponent(sub), withIntermediateDirectories: true)
    }
    try fm.createDirectory(at: home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs"),
                           withIntermediateDirectories: true)

    let found = CloudProvider.detectFolders(home: home.path)
    let providers = Set(found.map(\.provider))
    #expect(providers == [.oneDrive, .dropbox, .box, .iCloud])   // NotACloud is .generic → skipped
}

@Test func isDatalessDistinguishesHollowFromMaterialized() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("cf-dl-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    // a real 2 MB file (materialized)
    let normal = dir.appendingPathComponent("normal.bin")
    try Data(repeating: 7, count: 2_000_000).write(to: normal)

    // a hollow file: 2 MB logical, ~0 blocks (the structural signature of a cloud placeholder)
    let hollow = dir.appendingPathComponent("hollow.bin")
    fm.createFile(atPath: hollow.path, contents: nil)
    let fh = try FileHandle(forWritingTo: hollow)
    try fh.truncate(atOffset: 2_000_000)
    try fh.close()

    #expect(!CloudFile.isDataless(normal))
    #expect(CloudFile.isDataless(hollow))
    #expect(CloudFile.anyDataless(in: dir))        // the dir contains a placeholder
}

@Test func backupJobWithoutProviderStillDecodes() throws {
    // a pre-1.2 target JSON has no cloudProvider key → optional decodes to nil.
    var obj = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(
        Target.localVolume(id: "t", name: "Disk", dir: URL(fileURLWithPath: "/x")))) as! [String: Any]
    obj.removeValue(forKey: "cloudProvider")
    let data = try JSONSerialization.data(withJSONObject: obj)
    let decoded = try JSONDecoder().decode(Target.self, from: data)
    #expect(decoded.cloudProvider == nil)
}
