//
//  LibraryNames.swift
//  CryoframeKit
//
//  Through 1.5 a library's archives lived in `<destination>/<library display name>/`,
//  and a folder library's display name is just its folder's name. So `Work/Projects`
//  and `Personal/Projects` in one job wrote into the same folder, each run
//  overwriting the other; 1.5.6 refused such a job. Since 1.6 each library's folder
//  is found by its identity (see LibraryFolder), so two libraries of one name get
//  two folders, and the job is allowed. What's left is telling them apart: the
//  editor says so, and suggests a rename.
//
//  "The same name" is how the destination's file system compares folder names, and
//  is also how a folder 1.5 wrote is matched to its library.
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

    /// one sentence per shared name, for the job editor (a note, not a refusal)
    public static func clashMessages(_ libraries: [ContentType]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for lib in clashing(libraries) where seen.insert(key(lib.displayName)).inserted {
            out.append(clashMessage(lib.displayName))
        }
        return out
    }

    public static func clashMessage(_ name: String) -> String {
        "More than one library in this job is named “\(name)”. Their backups are kept in separate folders, but they look alike in Restore and in the history; rename one to tell them apart."
    }

    private static func key(_ s: String) -> String { s.precomposedStringWithCanonicalMapping.lowercased() }
}
