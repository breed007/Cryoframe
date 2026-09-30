//
//  JobEdit.swift
//  CryoframeKit
//
//  Saving an edited job over the one on disk.
//
//  The editor holds a copy of the job from the moment it opened. A run can record
//  things about the job's drives in the meantime: the drive a destination set up
//  before 1.6 is on, another drive it takes turns on, the drive a folder is on.
//  Saving the editor's copy whole wrote those back to what they were when it opened,
//  so the next run met its own drive as "a different drive" and refused it. What the
//  editor shows and changes is its to decide; what a run found out is the run's,
//  unless the editor changed that very thing.
//

import Foundation

public enum JobEdit {
    /// The job to save, given `draft` (the editor's job), `base` (the job when the
    /// editor opened; nil for a new job) and `stored` (the job on disk now; nil when
    /// it isn't there). nil: nothing to save, because the job was deleted while it was
    /// being edited, and saving must not bring it back.
    ///
    /// The draft decides names, folders, which destination is the main one, their
    /// order, rotations, format, schedule and what to keep. From `stored` come the
    /// drives a run recorded (a destination's and a folder's volume, and the other
    /// drives a destination takes turns on) unless the draft changed that field from
    /// `base`; whether the job is paused; when it was made; whether it is encrypted.
    /// The drives a destination takes turns on are the stored ones, plus those the
    /// draft added, less those it took away. What the draft removed stays removed.
    public static func merge(draft: BackupJob, base: BackupJob?, stored: BackupJob?) -> BackupJob? {
        guard let base else { return draft }              // a new job is all the editor's
        guard let stored else { return nil }
        var out = draft
        out.enabled = stored.enabled
        out.createdAt = stored.createdAt
        out.encrypted = stored.encrypted
        out.targets = draft.targets.map { t in
            guard let s = stored.targets.first(where: { $0.id == t.id }),
                  let b = base.targets.first(where: { $0.id == t.id }) else { return t }
            var m = t
            if t.volume == b.volume { m.volume = s.volume }
            m.otherVolumes = otherVolumes(draft: t, base: b, stored: s)
            return m
        }
        out.libraries = draft.libraries.map { lib in
            guard let s = stored.libraries.first(where: { $0.id == lib.id }),
                  let b = base.libraries.first(where: { $0.id == lib.id }) else { return lib }
            var m = lib
            if lib.volume == b.volume { m.volume = s.volume }
            return m
        }
        return out
    }

    /// the stored drives, plus the ones the draft added, less the ones it took away
    /// (by UUID), never the destination's own drive
    static func otherVolumes(draft: Target, base: Target, stored: Target) -> [VolumeIdentity]? {
        let d = draft.otherVolumes ?? [], b = base.otherVolumes ?? [], s = stored.otherVolumes ?? []
        let removed = Set(b.map(\.uuid)).subtracting(d.map(\.uuid))
        var out: [VolumeIdentity] = []
        for v in s + d.filter({ x in !b.contains { $0.uuid == x.uuid } })
            where !removed.contains(v.uuid) && !out.contains(where: { $0.uuid == v.uuid }) {
            out.append(v)
        }
        let own = draft.volume == base.volume ? stored.volume : draft.volume
        out.removeAll { $0.uuid == own?.uuid }
        return out.isEmpty ? nil : out
    }
}
