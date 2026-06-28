//
//  CloudProvider.swift
//  CryoframeKit
//
//  Which cloud-sync service a destination folder belongs to. macOS 12+ puts the
//  third-party providers under ~/Library/CloudStorage; iCloud lives in Mobile
//  Documents. Knowing the provider lets us split sealed archives under the RIGHT
//  single-file ceiling (they differ a lot — iCloud caps at 50 GB, Box at 5 GB on
//  lower tiers) and warn about the provider's on-demand/eviction behavior.
//

import Foundation

/// a provider plan and the single-file ceiling it allows.
public struct CloudPlan: Sendable, Hashable {
    public let name: String
    public let bytes: UInt64
    public init(_ name: String, _ bytes: UInt64) { self.name = name; self.bytes = bytes }
}

public enum CloudProvider: String, Codable, Sendable, CaseIterable {
    case oneDrive, dropbox, googleDrive, box, iCloud, generic

    public var displayName: String {
        switch self {
        case .oneDrive:    return "OneDrive"
        case .dropbox:     return "Dropbox"
        case .googleDrive: return "Google Drive"
        case .box:         return "Box"
        case .iCloud:      return "iCloud Drive"
        case .generic:     return "Cloud folder"
        }
    }

    /// the plans (and their single-file ceilings) a provider offers, so the user can pick
    /// the one matching their account. Plans differ a lot — Box especially — and a sealed
    /// archive splits under the chosen ceiling so the provider accepts it. The first plan
    /// is the safe default.
    public var plans: [CloudPlan] {
        let gb: UInt64 = 1_000_000_000
        switch self {
        case .box:         return [CloudPlan("Free / Starter", 5 * gb),
                                   CloudPlan("Business", 50 * gb),
                                   CloudPlan("Enterprise", 150 * gb)]
        case .iCloud:      return [CloudPlan("iCloud Drive", 50 * gb)]        // hard 50 GB single-file limit
        case .oneDrive:    return [CloudPlan("Personal / Business", 240 * gb)]
        case .dropbox:     return [CloudPlan("Standard", 240 * gb), CloudPlan("Large files", 2_000 * gb)]
        case .googleDrive: return [CloudPlan("Standard", 240 * gb), CloudPlan("Large files", 2_000 * gb)]
        case .generic:     return [CloudPlan("Standard", 240 * gb)]
        }
    }

    /// the default single-file ceiling (the first plan).
    public var maxSingleFileBytes: UInt64 { plans.first?.bytes ?? 240_000_000_000 }

    /// match a folder to a provider by its path. The CloudStorage folders are named
    /// like "OneDrive-Personal", "OneDrive - Contoso", "GoogleDrive-me@x.com", "Box-Box",
    /// "Dropbox". Matching is tight (exact name or "<Provider>-"/"<Provider> -" prefix) so
    /// an unrelated folder like "OneDriveBackups" isn't misread as a provider folder.
    public static func identify(_ dir: URL) -> CloudProvider {
        let parts = dir.pathComponents
        func any(_ pred: (String) -> Bool) -> Bool { parts.contains(where: pred) }
        func provider(_ name: String, _ c: String) -> Bool { c == name || c.hasPrefix("\(name)-") || c.hasPrefix("\(name) -") }
        if any({ provider("OneDrive", $0) }) { return .oneDrive }
        if any({ $0 == "Dropbox" }) { return .dropbox }
        if any({ provider("GoogleDrive", $0) || $0 == "Google Drive" }) { return .googleDrive }
        if any({ provider("Box", $0) || $0 == "Box Sync" }) { return .box }
        if any({ $0 == "com~apple~CloudDocs" }) { return .iCloud }
        return .generic
    }

    /// the cloud-sync folders present on this machine, for offering as quick-picks.
    public static func detectFolders(home: String) -> [(url: URL, provider: CloudProvider)] {
        let fm = FileManager.default
        var out: [(URL, CloudProvider)] = []
        func add(_ url: URL, _ provider: CloudProvider) {
            guard fm.fileExists(atPath: url.path), !out.contains(where: { $0.0.path == url.path }) else { return }
            out.append((url, provider))
        }
        let homeURL = URL(fileURLWithPath: home)

        // modern: ~/Library/CloudStorage/<Provider>-<account>
        let cloudStorage = homeURL.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        if let entries = try? fm.contentsOfDirectory(at: cloudStorage, includingPropertiesForKeys: [.isDirectoryKey]) {
            for e in entries where (try? e.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let p = identify(e)
                if p != .generic { add(e, p) }
            }
        }
        // iCloud Drive
        add(homeURL.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true), .iCloud)
        // legacy top-level folders (older clients)
        add(homeURL.appendingPathComponent("Dropbox", isDirectory: true), .dropbox)
        add(homeURL.appendingPathComponent("Google Drive", isDirectory: true), .googleDrive)
        add(homeURL.appendingPathComponent("Box", isDirectory: true), .box)
        return out
    }
}
