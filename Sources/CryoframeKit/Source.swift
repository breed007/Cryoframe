//
//  Source.swift
//  CryoframeKit
//
//  What gets backed up, as something a person recognizes and the app can find
//  again: the rules a folder has to pass to be backed up, its friendly name, and
//  its volume, so a folder on an external drive is still found after the drive is
//  renamed or mounts somewhere else.
//
//  A library's id is its identity (the job's archive folders are named by it, see
//  LibraryFolder); a custom folder's id is fixed when it is added, whatever its
//  name or place becomes.
//

import Foundation

public enum SourceRules {
    /// Check `folder` as a folder to back up, to `destinations` (the job's). Refused:
    /// missing; a file (a package, like a library, is fine); unreadable; inside a
    /// destination, or holding one; a Cryoframe backup, or inside one; a system
    /// location. Warned: on a drive that can't be frozen, so it is read as it is.
    public static func check(_ folder: URL, destinations: [URL], home: String = NSHomeDirectory(),
                             systemRoots: [String] = ["/System", "/usr", "/bin", "/sbin", "/private", "/var", "/tmp", "/etc", "/dev", "/cores"]) -> [PlaceIssue] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDir) else {
            return [PlaceIssue(.refusal, "\(folder.lastPathComponent) doesn't exist, or its drive isn't connected")]
        }
        guard isDir.boolValue else {
            return [PlaceIssue(.refusal, "\(folder.lastPathComponent) is a file. Choose the folder it's in, or a library.")]
        }
        var out: [PlaceIssue] = []
        if access(folder.path, R_OK | X_OK) != 0 || (try? fm.contentsOfDirectory(atPath: folder.path)) == nil {
            out.append(PlaceIssue(.refusal, "Cryoframe can't read \(folder.lastPathComponent). Check that Cryoframe has Full Disk Access, and the folder's permissions in Finder's Get Info."))
        }
        for d in destinations {
            if DestinationRules.contains(d, folder) {
                out.append(PlaceIssue(.refusal, DestinationRules.samePath(d, folder)
                    ? "\(folder.lastPathComponent) is where this job's backups go. Choose the folder you want backed up."
                    : "\(folder.lastPathComponent) is inside \(d.lastPathComponent), where this job's backups go: it would back up its own backups."))
            } else if DestinationRules.contains(folder, d) {
                out.append(PlaceIssue(.refusal, "\(d.lastPathComponent), where this job's backups go, is inside \(folder.lastPathComponent): each backup would copy the ones before it. Choose a destination outside it."))
            }
        }
        if let inside = DestinationRules.insideBackup(folder) {
            out.append(PlaceIssue(.refusal, "\(folder.lastPathComponent) is \(DestinationRules.samePath(inside, folder) ? "" : "inside ")a Cryoframe backup. Back up the folder the backup was made from instead; to get files back from it, use Restore."))
        }
        let p = DestinationRules.canonical(folder)
        if p == "/" || systemRoots.contains(where: { p == $0 || p.hasPrefix($0 + "/") }) {
            out.append(PlaceIssue(.refusal, "\(folder.lastPathComponent) is part of macOS itself, which a reinstall puts back. Choose your own folders."))
        }
        if out.isEmpty, let v = VolumeInspector.volume(for: folder), !v.canSnapshot {
            out.append(PlaceIssue(.warning, "\(folder.lastPathComponent) is on \(v.name), a \(v.fsType.uppercased()) drive, which can't be frozen for a backup: it is copied as it is, so quit apps that change it while a backup runs."))
        }
        return out
    }

    /// "Projects in your home folder", "Projects on Work SSD", "Projects on this Mac"
    public static func friendlyName(for folder: URL, volumes: VolumeTable = SystemVolumeTable(),
                                    home: String = NSHomeDirectory()) -> String {
        let name = folder.lastPathComponent
        if DestinationRules.contains(URL(fileURLWithPath: home), folder) {
            return DestinationRules.samePath(URL(fileURLWithPath: home), folder) ? "your home folder" : "\(name) in your home folder"
        }
        guard let v = volumes.volume(containing: folder) else { return name }
        switch v.kind {
        case .internalDisk, .cloud: return "\(name) on this Mac"
        case .externalDrive: return DestinationRules.samePath(folder, v.mountPoint) ? v.name : "\(name) on \(v.name)"
        case .network: return "\(name) on \(v.name)"
        }
    }
}

extension ContentType {
    /// where this library is now: its recorded folder if it's there, else the same
    /// place on its drive wherever that drive is mounted now (a renamed drive mounts
    /// under its new name). Only a folder whose volume is recorded can be found again.
    public func located(volumes: VolumeTable, home: String) -> ContentType {
        guard let id = volume, paths.count == 1 else { return self }
        let live = paths[0].liveURL(home: home)
        if FileManager.default.fileExists(atPath: live.path) { return self }
        guard let v = volumes.mounted().first(where: { $0.uuid == id.uuid }) else { return self }
        let now = id.relativePath.isEmpty ? v.mountPoint : v.mountPoint.appendingPathComponent(id.relativePath)
        var copy = self
        copy.paths = [.absolute(now.path)]
        return copy
    }
}

extension ContentType {
    /// A folder chosen to be backed up, named after itself. On a drive other than the
    /// startup disk its volume is recorded too, so it's found after the drive is
    /// renamed (see `located`).
    public static func customFolder(_ url: URL, path: LibraryPath, volumes: VolumeTable = SystemVolumeTable()) -> ContentType {
        var ct = genericFolder(id: url.path, displayName: url.lastPathComponent, path: path)
        if let v = volumes.volume(containing: url), v.kind == .externalDrive, let uuid = v.uuid {
            ct.volume = VolumeIdentity(uuid: uuid, name: v.name, relativePath: DestinationRules.relative(url, to: v.mountPoint))
        }
        return ct
    }
}
