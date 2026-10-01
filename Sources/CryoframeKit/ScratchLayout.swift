//
//  ScratchLayout.swift
//  CryoframeKit
//
//  Where a sealed build is made, and how Cryoframe tells its own folders in scratch
//  from anyone else's.
//
//  A sealed archive is built in scratch before it is copied to its destinations:
//
//    <root>/<job ID>/.cryoframe-scratch    the mark: this folder is that job's
//    <root>/<job ID>/build/<library>/      the archive, and any copy it is built from
//
//  The root is `app.cryoframe/scratch` in the system cache by default. A scratch
//  location chosen in Settings is the user's own folder and may hold anything, so
//  Cryoframe works in a folder of its own inside it, `Cryoframe Scratch`. Up to 1.5
//  it worked in the chosen folder itself, and the sweep at launch took every
//  `<chosen>/*/build/*` no pending transfer named as its own: choose ~/Developer, and
//  a project's MyApp/build/Release was gone at the next launch.
//
//  So nothing in scratch is removed unless it is provably Cryoframe's: a folder
//  named for a job (a UUID, as every job's ID is, or a job Cryoframe knows), that is
//  a real folder and not a link, holding the mark naming that job, written before
//  anything else goes in. Anything else, a 1.5 build left in a chosen folder among
//  them, is left alone.
//

import Foundation

public enum ScratchLayout {
    /// Cryoframe's own folder inside a scratch location chosen in Settings
    public static let folderName = "Cryoframe Scratch"
    static let markName = ".cryoframe-scratch"

    /// where Cryoframe builds in a scratch location chosen in Settings
    public static func root(inChosen chosen: URL) -> URL {
        chosen.appendingPathComponent(folderName, isDirectory: true)
    }

    static func markText(_ jobID: String) -> String { "Cryoframe builds job \(jobID) here.\n" }

    /// Whether a folder named `name` can be a job's: one path component, and a UUID
    /// (every job's ID) or one of `known`.
    static func isJobID(_ name: String, known: Set<String> = []) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/") else { return false }
        return UUID(uuidString: name) != nil || known.contains(name)
    }

    /// whether `url` is a folder, and not a link to one
    static func isRealFolder(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
    }

    /// Whether `dir` is `jobID`'s folder in scratch, made by Cryoframe: a real folder
    /// holding the mark that names the job.
    public static func isOurs(_ dir: URL, jobID: String) -> Bool {
        guard dir.lastPathComponent == jobID, isRealFolder(dir) else { return false }
        let mark = dir.appendingPathComponent(markName).path
        var st = stat()
        guard lstat(mark, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size < 1024,
              let data = FileManager.default.contents(atPath: mark) else { return false }
        return String(decoding: data, as: UTF8.self) == markText(jobID)
    }

    /// Make the job folder holding `libraryDir` (`<root>/<job>/build/<library>`) and
    /// mark it as the job's, before anything is built in it. Nothing for a folder
    /// laid out any other way.
    static func claim(libraryDir: URL) throws {
        guard libraryDir.deletingLastPathComponent().lastPathComponent == "build" else { return }
        let jobDir = libraryDir.deletingLastPathComponent().deletingLastPathComponent()
        let jobID = jobDir.lastPathComponent
        let fm = FileManager.default
        try fm.createDirectory(at: jobDir, withIntermediateDirectories: true)
        guard isRealFolder(jobDir) else { throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: jobDir.path]) }
        if isOurs(jobDir, jobID: jobID) { return }
        try Data(markText(jobID).utf8).write(to: jobDir.appendingPathComponent(markName), options: .atomic)
    }

    /// The job folder's `build`, if empty, then the folder itself if it holds nothing
    /// but its mark. Only for a folder of Cryoframe's (see `isOurs`).
    static func tidy(jobDir: URL) {
        _ = rmdir(jobDir.appendingPathComponent("build").path)
        guard isOurs(jobDir, jobID: jobDir.lastPathComponent),
              (try? FileManager.default.contentsOfDirectory(atPath: jobDir.path)) == [markName] else { return }
        _ = unlink(jobDir.appendingPathComponent(markName).path)
        _ = rmdir(jobDir.path)
    }
}
