//
//  LibraryNames.swift
//  CryoframeKit
//
//  A library's archives live in `<destination>/<library display name>/`, and a
//  folder library's display name is just its folder's name. So `Work/Projects` and
//  `Personal/Projects` in one job wrote into the same folder, each run overwriting
//  the other, and the run reported "1 library archived". A custom folder named
//  "Photos" did the same to the built-in Photos library.
//
//  The wizard refuses the combination and the executor refuses to run it, both from
//  this one definition of "the same name". Naming archive folders by library ID
//  instead is the real fix, and needs a migration of existing archives (1.6).
//

import Foundation

public enum LibraryNames {
    /// how the destination's file system compares the two folder names: APFS and
    /// HFS+ ignore case, and APFS ignores Unicode normalization too.
    public static func same(_ a: String, _ b: String) -> Bool { key(a) == key(b) }

    /// the libraries that share an archive folder with another library in the list.
    public static func clashing(_ libraries: [ContentType]) -> [ContentType] {
        let counts = Dictionary(grouping: libraries, by: { key($0.displayName) })
        return libraries.filter { (counts[key($0.displayName)]?.count ?? 0) > 1 }
    }

    /// one sentence per clashing name, for the job editor.
    public static func clashMessages(_ libraries: [ContentType]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for lib in clashing(libraries) where seen.insert(key(lib.displayName)).inserted {
            out.append(clashMessage(lib.displayName))
        }
        return out
    }

    public static func clashMessage(_ name: String) -> String {
        "More than one library in this job is named “\(name)”. Their backups would share one folder and overwrite each other — keep one here and back up the other in a separate job with a different destination."
    }

    private static func key(_ s: String) -> String { s.precomposedStringWithCanonicalMapping.lowercased() }
}
