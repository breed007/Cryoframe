//
//  MessagesAttachments.swift
//  CryoframeKit
//
//  "Messages attachments": the photos, videos and files people send in Messages,
//  as a library of its own, without the rest of Messages (its database is never
//  read). It is the folder ~/Library/Messages/Attachments, read from the moment
//  the backup freezes, like every library on the startup disk. Messages may stay
//  open: it only adds files there, and the run reads a frozen copy.
//
//  What it needs that no other library does comes from its id, not from anything
//  stored with a job, so 1.6.0 reads its jobs unchanged:
//    - What it leaves out (`leavesOut`): the link previews Messages keeps beside
//      attachments (".pluginPayloadAttachment"; measured on one Mac: 2,690 of 8,191
//      files, 465 MB), property lists (112 there) and Finder's ".DS_Store". None is a
//      photo, video or file someone sent. Stickers aren't in this folder at all.
//      Only the up-to-date disk image and plain files leave them out; a sealed
//      version holds them (see JobExecutor.leavesOut).
//    - What was deleted in Messages stays in the backup (`keepsRemoved`): plain files
//      and the up-to-date disk image keep it in Removed items (see RemovedItems),
//      and dated versions in a removed-items archive (see RemovedArchive).
//    - It is part of Messages (`partOf`): a job backing up Messages covers it.
//
//  Full Disk Access guards it, as it does all of Messages; the run reports a refused
//  read the way it does for any library (see FullDiskAccess).
//

import Foundation

public extension ContentType {
    static let messagesAttachmentsID = "com.apple.messages.attachments"

    static let messagesAttachments = ContentType(
        id: messagesAttachmentsID,
        displayName: "Messages attachments",
        paths: [.home("Library/Messages/Attachments")],
        owningProcess: nil,               // read frozen; Messages may stay open
        kind: .staticContent,             // a folder of files, kept on any drive
        integrityProbe: nil)

    /// whether what is deleted from this library is kept in its backups (see the top)
    var keepsRemoved: Bool { id == Self.messagesAttachmentsID }

    /// the library this one is part of, whose backup covers it (see CoverageAdvisor)
    var partOf: String? { id == Self.messagesAttachmentsID ? ContentType.messages.id : nil }

    /// Whether an item named `name` in this library is left out of its backups, and
    /// what is in it. nil: nothing is. A name holding a backslash is never left out:
    /// rsync's filters can't match one (see MirrorCopy.update), so it is copied.
    var leavesOut: (@Sendable (String) -> Bool)? {
        id == Self.messagesAttachmentsID ? MessagesAttachments.isLeftOut : nil
    }
}

public enum MessagesAttachments {
    /// the extensions of what isn't backed up (see the top), lowercased
    static let leftOutExtensions: Set<String> = ["pluginpayloadattachment", "plist"]

    @Sendable public static func isLeftOut(_ name: String) -> Bool {
        guard !name.contains("\\") else { return false }
        return name == ".DS_Store" || leftOutExtensions.contains((name as NSString).pathExtension.lowercased())
    }
}
