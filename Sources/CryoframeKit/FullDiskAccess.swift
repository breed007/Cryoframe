//
//  FullDiskAccess.swift
//  CryoframeKit
//
//  There's no API to ask whether Cryoframe holds Full Disk Access, so it is
//  probed: macOS lets a process read certain locations only when it holds the
//  grant. 1.5 read the per-user TCC database alone, and on macOS 27 that folder
//  no longer exists, so a granted Mac read as not granted and the app stopped
//  checking its libraries. This tries several protected locations instead and
//  says "unknown" when none of them is there to ask.
//
//  A probe reads at most one byte of a file or one entry of a folder, and keeps
//  none of it.
//
//  Note: TCC evaluates a process's grant at launch, so a freshly granted Full
//  Disk Access may not take effect until Cryoframe is relaunched.
//

import Foundation

public enum FullDiskAccess {

    public enum Status: Sendable, Equatable {
        /// a protected location could be read.
        case granted
        /// a protected location exists and macOS refused to let Cryoframe read it.
        case denied
        /// none of the protected locations exists on this Mac, so there's nothing to ask.
        case unknown

        /// how Report a Problem states it. Kept here so the words are in the
        /// vocabulary the report keeps.
        public var reportText: String {
            switch self {
            case .granted: "granted"
            case .denied: "not granted"
            case .unknown: "unknown"
            }
        }
    }

    /// what trying one location found.
    public enum Probe: Sendable, Equatable {
        /// the file's first byte, or the folder's first entry, could be read.
        case readable
        /// the location exists and the read was refused (EPERM or EACCES).
        case refused
        /// the location doesn't exist (ENOENT or ENOTDIR).
        case missing
        /// some other failure, which says nothing about the grant either way.
        case inconclusive
    }

    /// the locations macOS guards with Full Disk Access, relative to the home folder
    /// unless absolute, tried in this order. Each is guarded by Full Disk Access
    /// itself rather than a per-app prompt, so probing one shouldn't ask the person
    /// anything (Containers folders, which can prompt, are left out on purpose).
    public static let locations: [String] = [
        "Library/Application Support/com.apple.TCC/TCC.db",
        "/Library/Application Support/com.apple.TCC/TCC.db",
        "Library/Safari",
        "Library/Mail",
    ]

    /// the probe paths for a home folder.
    public static func paths(home: URL) -> [String] {
        locations.map { $0.hasPrefix("/") ? $0 : home.appendingPathComponent($0).path }
    }

    /// Decide from the probes, tried in order. A readable location is proof of the
    /// grant and ends the search. A refusal is only strong evidence (an EACCES can
    /// also be ordinary file permissions), so it is remembered and the remaining
    /// locations are still tried; with no readable location it means denied. With
    /// neither, the answer is unknown.
    public static func status(paths: [String], probe: (String) -> Probe) -> Status {
        var refused = false
        for path in paths {
            switch probe(path) {
            case .readable: return .granted
            case .refused: refused = true
            case .missing, .inconclusive: continue
            }
        }
        return refused ? .denied : .unknown
    }

    /// the status for this process, probing the real locations under `home`.
    public static func status(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Status {
        status(paths: paths(home: home), probe: probe)
    }

    /// Try one location: open it, then read one byte of a file or one entry of a
    /// folder. Opening a protected folder can succeed where listing it is refused,
    /// so a folder only counts once an entry (or the end of an empty listing) is read.
    public static func probe(_ path: String) -> Probe {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return classify(errno) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { let e = errno; close(fd); return classify(e) }
        if (info.st_mode & S_IFMT) == S_IFDIR {
            guard let dir = fdopendir(fd) else { let e = errno; close(fd); return classify(e) }
            defer { closedir(dir) }   // closes fd too
            errno = 0
            if readdir(dir) != nil { return .readable }
            return errno == 0 ? .readable : classify(errno)   // an empty listing still read
        }
        defer { close(fd) }
        var byte: UInt8 = 0
        return read(fd, &byte, 1) >= 0 ? .readable : classify(errno)
    }

    static func classify(_ code: Int32) -> Probe {
        switch code {
        case EPERM, EACCES: return .refused
        case ENOENT, ENOTDIR: return .missing
        default: return .inconclusive
        }
    }
}
