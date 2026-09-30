//
//  JobPreset.swift
//  CryoframeKit
//
//  Quick-start choices for a new job: one click sets what to back up, how each
//  backup is kept, the check, what to keep and when, and every choice stays
//  editable after. They were the new-job wizard's cards through 1.5.
//
//  And the room note the editor shows for a new job: about how much there is to
//  back up against the free space on the main destination. It's information only:
//  a job that may not fit can still be made (a dated version compresses, and the
//  room can be made before the first backup).
//

import Foundation

public struct JobPreset: Sendable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var systemImage: String
    /// the built-in libraries it backs up; none: choose them yourself
    public var libraryIDs: [String]
    /// "mirror" (one up-to-date copy), "dmg" or "zip" (dated versions)
    public var formatKind: String
    public var verification: VerificationPolicy
    public var retention: RetentionPolicy

    public static let all: [JobPreset] = [
        JobPreset(id: "photos-nightly", title: "Photos, nightly", subtitle: "Dated versions, fully checked · keeps the last 14",
                  systemImage: "photo.on.rectangle.angled", libraryIDs: [ContentType.photos.id],
                  formatKind: "dmg", verification: .mountAndOpen, retention: .keepLast(14)),
        JobPreset(id: "music-copy", title: "Music, kept up to date", subtitle: "One up-to-date copy · updated in place, fast",
                  systemImage: "music.note.list", libraryIDs: [ContentType.appleMusic.id],
                  formatKind: "mirror", verification: .checksumOnly, retention: .keepAll),
        JobPreset(id: "photos-music", title: "Photos and Music", subtitle: "Both, dated versions, nightly · keeps the last 7",
                  systemImage: "square.stack.3d.up", libraryIDs: [ContentType.photos.id, ContentType.appleMusic.id],
                  formatKind: "dmg", verification: .checksumOnly, retention: .keepLast(7)),
        JobPreset(id: "scratch", title: "Start from scratch", subtitle: "Choose everything yourself",
                  systemImage: "plus", libraryIDs: [], formatKind: "mirror", verification: .checksumOnly, retention: .keepLast(7)),
    ]
}

public extension JobDraftState {
    /// Start from `preset`: its libraries (those on offer), how each backup is kept,
    /// the check, what to keep, and every night at 2:00. Destinations, the name and
    /// encryption stay as they are. Starting from scratch clears what's chosen.
    mutating func apply(_ preset: JobPreset, now: Date = Date(), calendar: Calendar = .current) {
        selectedLibraryIDs = Set(libraries.filter { preset.libraryIDs.contains($0.id) }.map(\.id))
        // an encrypted job keeps its backups in disk images: a zip can't be encrypted
        formatKind = encrypt && preset.formatKind == "zip" ? "dmg" : preset.formatKind
        verification = preset.verification
        switch preset.retention {
        case .keepAll: retentionKind = "all"
        case .keepLast(let n): retentionKind = "lastN"; keepN = n
        case .gfs(let d, let w, let m): retentionKind = "gfs"; gfsDaily = d; gfsWeekly = w; gfsMonthly = m
        }
        freqKind = .daily
        dailyTime = calendar.date(bySettingHour: 2, minute: 0, second: 0, of: now) ?? now
    }

    /// whether the draft is what `preset` set up (starting from scratch: nothing chosen)
    func matches(_ preset: JobPreset) -> Bool {
        guard !preset.libraryIDs.isEmpty else { return selectedLibraryIDs.isEmpty }
        return selectedLibraryIDs == Set(preset.libraryIDs) && formatKind == preset.formatKind
    }

    /// About how much there is to back up against the room on the main destination.
    /// `sizes`: each library's size, by id, where it's known. `free`: the room on the
    /// main destination, where it's known. nil when there's nothing to say.
    func roomNote(sizes: [String: UInt64], free: UInt64?) -> RoomNote? {
        let chosen = selectedLibraries
        let known = chosen.compactMap { sizes[$0.id] }
        let total = known.reduce(UInt64(0), +)
        guard total > 0, let free, let main = primaryTarget else { return nil }
        let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: total), countStyle: .file)
        let room = ByteCountFormatter.string(fromByteCount: Int64(clamping: free), countStyle: .file)
        let tight = total > free
        let line = "About \(size)\(known.count == chosen.count ? "" : "+") to back up · \(room) free on \(main.displayName)"
        let advice = tight ? "This may not fit on the main destination."
            : isSealed ? "Dated versions are compressed, so each usually takes less room than this." : nil
        return RoomNote(line: line, advice: advice, mayNotFit: tight)
    }
}

/// What the editor says about room for a new job (see JobDraftState.roomNote).
public struct RoomNote: Sendable, Equatable {
    public var line: String
    public var advice: String?
    /// more to back up than there is room: said, never refused
    public var mayNotFit: Bool
}
