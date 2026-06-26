//
//  FinderPathLink.swift
//  Cryoframe (app)
//
//  A file path rendered as a link: click it to reveal the item in Finder. Used for
//  library locations and destinations, so a path you can see is a path you can open.
//

import SwiftUI
import AppKit

struct FinderPathLink: View {
    let path: String
    var font: Font = .caption2
    @State private var hovering = false

    var body: some View {
        Button { Self.reveal(path) } label: {
            Text(path)
                .font(font)
                .foregroundStyle(hovering ? Color.accentColor : Color.secondary)
                .underline(hovering)
                .lineLimit(1).truncationMode(.middle)
        }
        .buttonStyle(.plain)
        .help("Reveal in Finder")
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    /// reveal the path in Finder, selecting it in its parent. If it doesn't exist
    /// (a missing or moved library), open the nearest folder that does.
    static func reveal(_ path: String) {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            return
        }
        var dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        while !fm.fileExists(atPath: dir.path), dir.path != "/" { dir = dir.deletingLastPathComponent() }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }
}
