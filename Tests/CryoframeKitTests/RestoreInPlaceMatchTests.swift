//
//  RestoreInPlaceMatchTests.swift
//  CryoframeKitTests
//
//  Which live library a restore in place replaces. It is told by the identity of the
//  folder the version was found in, never by the library's name: a folder chosen to
//  be backed up may be called "Photos" or "Mail", and restored in place by its name
//  it sent the Photos library, or ~/Library/Mail, to the Trash.
//

import Testing
import Foundation
@testable import CryoframeKit

@Suite struct RestoreInPlaceMatchTests {
    private let registry = ContentTypeRegistry.withOverrides([:])

    private func archive(_ name: String, key: String?) -> RestorableArchive {
        RestorableArchive(dir: URL(fileURLWithPath: "/Volumes/Backup/\(name)/2026-10-29_10-00-00"), libraryName: name,
                          format: .sealedZip, bytes: 1, artifactNames: ["\(name).zip"], libraryKey: key)
    }

    @Test(arguments: ["Photos", "Mail", "Messages", "iMovie", "GarageBand"])
    func aCustomFolderNamedLikeABuiltInLibraryIsNeverRestoredOverIt(_ name: String) {
        #expect(registry.types.contains { $0.displayName == name }, "\(name) is a built-in's name")
        let folder = archive(name, key: LibraryIdentity.key(jobID: "J1", libraryID: "/Users/me/Dropbox/\(name)"))
        #expect(RestoreInPlace.liveLibrary(for: folder, in: registry) == nil)
    }

    @Test func aBuiltInLibraryIsFoundByItsIdentityWhateverItsName() {
        let photos = archive("Photos", key: LibraryIdentity.key(jobID: "J1", libraryID: ContentType.photos.id))
        #expect(RestoreInPlace.liveLibrary(for: photos, in: registry)?.id == ContentType.photos.id)
        let renamed = archive("Family pictures", key: LibraryIdentity.key(jobID: "J1", libraryID: ContentType.photos.id))
        #expect(RestoreInPlace.liveLibrary(for: renamed, in: registry)?.id == ContentType.photos.id)
        let mail = archive("Photos", key: LibraryIdentity.key(jobID: "J1", libraryID: ContentType.mail.id))
        #expect(RestoreInPlace.liveLibrary(for: mail, in: registry)?.id == ContentType.mail.id)
    }

    // A folder written before 1.6 has no identity, only its name, which proves nothing;
    // Removed items are not a version of the library at all. Both are restored beside.
    @Test func noIdentityOrRemovedItemsIsNeverRestoredInPlace() {
        #expect(RestoreInPlace.liveLibrary(for: archive("Photos", key: nil), in: registry) == nil)
        var removed = archive("Photos", key: LibraryIdentity.key(jobID: "J1", libraryID: ContentType.photos.id))
        removed.removedItems = true
        #expect(RestoreInPlace.liveLibrary(for: removed, in: registry) == nil)
    }

    // An id that only ends like a built-in's isn't it.
    @Test func aLibraryIDIsMatchedWhole() {
        let a = archive("Photos", key: LibraryIdentity.key(jobID: "J1", libraryID: "/Volumes/X/" + ContentType.photos.id))
        #expect(RestoreInPlace.liveLibrary(for: a, in: registry) == nil)
    }
}
