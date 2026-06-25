//
//  ContentTypeTests.swift
//  CryoframeKitTests
//
//  The descriptor abstraction: registry, path mapping (live ↔ frozen), locator
//  resolution, owning-process detection. All pure / fake-backed — no disk, no root.
//

import Testing
import Foundation
@testable import CryoframeKit

// MARK: - registry

@Test func builtInsCoverAppleAndOutlookLibraries() {
    let r = ContentTypeRegistry()
    #expect(r.type(id: "com.apple.photos")?.displayName == "Photos")
    #expect(r.type(id: "com.apple.music")?.displayName == "Apple Music")
    #expect(r.type(id: "com.apple.imovie")?.kind == .liveDB)
    #expect(r.type(id: "com.apple.messages")?.integrityProbe == "chat.db")
    #expect(r.type(id: "com.apple.mail")?.owningProcess?.bundleIdentifier == "com.apple.mail")
    #expect(r.type(id: "com.microsoft.outlook") != nil)
    #expect(r.type(id: "com.apple.garageband")?.kind == .staticContent)
    #expect(r.types.count == 7)
}

@Test func addReplacesByID() {
    var r = ContentTypeRegistry()
    let base = r.types.count
    let folder = ContentType.genericFolder(id: "f1", displayName: "Movies", path: .home("Movies"))
    r.add(folder)
    #expect(r.types.count == base + 1)
    r.add(ContentType.genericFolder(id: "f1", displayName: "Movies (renamed)", path: .home("Movies")))
    #expect(r.types.count == base + 1)                          // replaced, not duplicated
    #expect(r.type(id: "f1")?.displayName == "Movies (renamed)")
}

@Test func overrideRepointsBuiltInButKeepsIdentity() {
    let moved = LibraryPath.absolute("/Volumes/Big/Photos Library.photoslibrary")
    let r = ContentTypeRegistry.withOverrides(["com.apple.photos": moved])

    let photos = r.type(id: "com.apple.photos")
    #expect(photos?.paths == [moved])                                   // repointed
    #expect(photos?.owningProcess?.bundleIdentifier == "com.apple.Photos") // owner kept
    #expect(photos?.integrityProbe == "database/Photos.sqlite")          // probe kept
    #expect(r.type(id: "com.apple.music")?.paths == ContentType.appleMusic.paths) // others untouched
    #expect(r.types.count == ContentTypeRegistry.builtIns.count)
}

@Test func jobReResolvesBuiltInPathFromOverridesAtRunTime() {
    let moved = LibraryPath.absolute("/Volumes/X/Photos Library.photoslibrary")
    let registry = ContentTypeRegistry.withOverrides(["com.apple.photos": moved])
    let target = Target.localVolume(id: "t", name: "Disk", dir: URL(fileURLWithPath: "/tmp"))

    let builtInJob = BackupJob(name: "p", libraries: [.photos], target: target,
                               format: .sealedZip, frequency: .manual, createdAt: Date(timeIntervalSince1970: 0))
    #expect(builtInJob.resolvingLibraries(in: registry).libraries.first?.paths == [moved])

    let folder = ContentType.genericFolder(id: "/x", displayName: "x", path: .home("x"))
    let folderJob = BackupJob(name: "f", libraries: [folder], target: target,
                              format: .sealedZip, frequency: .manual, createdAt: Date(timeIntervalSince1970: 0))
    #expect(folderJob.resolvingLibraries(in: registry).libraries.first?.id == "/x")   // unaffected
}

@Test func templateAttachesOwnerAndPathToAPickedLibrary() {
    let ct = LibraryTemplate.finalCutPro.contentType(
        id: "/Volumes/Media/Edit.fcpbundle",
        displayName: "Edit.fcpbundle",
        path: .absolute("/Volumes/Media/Edit.fcpbundle"))
    #expect(ct.kind == .liveDB)
    #expect(ct.owningProcess?.bundleIdentifier == "com.apple.FinalCut")
    #expect(ct.paths == [.absolute("/Volumes/Media/Edit.fcpbundle")])
}

// MARK: - descriptor shape

@Test func photosIsLiveDBWithOwnerAndProbe() {
    let p = ContentType.photos
    #expect(p.kind == .liveDB)
    #expect(p.requiresSnapshot)
    #expect(p.owningProcess?.bundleIdentifier == "com.apple.Photos")
    #expect(p.integrityProbe == "database/Photos.sqlite")
}

@Test func genericFolderIsStaticWithNoOwner() {
    let f = ContentType.genericFolder(id: "x", displayName: "Docs", path: .absolute("/Users/Shared/Docs"))
    #expect(f.kind == .staticContent)
    #expect(!f.requiresSnapshot)
    #expect(f.owningProcess == nil)
    #expect(f.integrityProbe == nil)
}

@Test func contentKindRawValueIsStableForWire() {
    #expect(ContentKind.staticContent.rawValue == "static")
    #expect(ContentKind.liveDB.rawValue == "liveDB")
}

// MARK: - path mapping (the bit that makes a descriptor snapshot-aware)

@Test func homePathMapsLiveAndFrozen() {
    let path = LibraryPath.home("Pictures/Photos Library.photoslibrary")
    #expect(path.liveURL(home: "/Users/breed").path == "/Users/breed/Pictures/Photos Library.photoslibrary")
    #expect(path.frozenURL(mountPoint: "/private/var/run/app.cryoframe/mnt/1", user: "breed").path
            == "/private/var/run/app.cryoframe/mnt/1/Users/breed/Pictures/Photos Library.photoslibrary")
}

@Test func absolutePathReRootsUnderMount() {
    let path = LibraryPath.absolute("/Users/Shared/Archive")
    #expect(path.liveURL(home: "/Users/breed").path == "/Users/Shared/Archive")
    #expect(path.frozenURL(mountPoint: "/mnt", user: "breed").path == "/mnt/Users/Shared/Archive")
}

// MARK: - locator resolution (injected existence)

@Test func locatorReturnsOnlyExistingRoots() {
    let present = "/private/var/run/app.cryoframe/mnt/1/Users/breed/Pictures/Photos Library.photoslibrary"
    let locator = ContentLocator(home: "/Users/breed", user: "breed", exists: { $0 == present })

    let frozen = locator.frozenRoots(of: .photos, mountPoint: "/private/var/run/app.cryoframe/mnt/1")
    #expect(frozen.map(\.path) == [present])

    // music root not present in this fake -> filtered out
    let music = locator.frozenRoots(of: .appleMusic, mountPoint: "/private/var/run/app.cryoframe/mnt/1")
    #expect(music.isEmpty)
}

// MARK: - owning-process detection

@Test func detectsRunningOwnerByBundleID() {
    let detector = FakeProcessDetector(runningBundleIDs: ["com.apple.Photos"])
    #expect(ContentType.photos.owningProcessRunning(detector))
    #expect(!ContentType.appleMusic.owningProcessRunning(detector))
}

@Test func staticContentNeverReportsRunningOwner() {
    let detector = FakeProcessDetector(runningExecutables: ["anything"])
    let folder = ContentType.genericFolder(id: "x", displayName: "Docs", path: .home("Documents"))
    #expect(!folder.owningProcessRunning(detector))
}
