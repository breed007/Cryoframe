//
//  LibraryLocationsView.swift
//  Cryoframe (app)
//
//  Edit where Cryoframe looks for each built-in library. Used both in Settings ▸
//  Libraries and as a sheet from the New Job sheet's "Edit locations…" button, so a
//  detected path can be repointed (e.g. a Photos library that lives on an external
//  drive) without leaving the job you're setting up.
//

import SwiftUI
import AppKit
import CryoframeKit

/// the editable rows, with no chrome — embed in a Form (Settings) or in the sheet below.
struct LibraryLocationsList: View {
    /// called after any change so the caller can refresh its own library list / validity.
    var onChange: () -> Void = {}

    @State private var overrides = LibraryOverrides.loadRaw()

    var body: some View {
        Section {
            ForEach(ContentTypeRegistry.builtIns) { type in row(type) }
        } header: {
            Text("Built-in library locations")
        } footer: {
            Text("Repoint a built-in library if it lives somewhere other than its default location, such as an external drive. The owning app and integrity check stay attached. Click a path to reveal it in Finder.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            Button("Restore all defaults") { LibraryOverrides.resetAll(); overrides = [:]; onChange() }
                .disabled(overrides.isEmpty)
        }
    }

    @ViewBuilder private func row(_ type: ContentType) -> some View {
        let defaultPath = type.paths.first?.liveURL(home: NSHomeDirectory()).path ?? ""
        let current = overrides[type.id] ?? defaultPath
        let isCustom = overrides[type.id] != nil
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(type.displayName)
                    if isCustom {
                        Text("custom").font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                FinderPathLink(path: current, font: .caption)
            }
            Spacer()
            Button("Change…") { change(type) }
            if isCustom {
                Button("Reset") { LibraryOverrides.reset(id: type.id); overrides = LibraryOverrides.loadRaw(); onChange() }
            }
        }
        .padding(.vertical, 2)
    }

    private func change(_ type: ContentType) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true            // a .photoslibrary is a package (a file to the panel)
        panel.allowsMultipleSelection = false
        panel.message = "Choose the \(type.displayName) library"
        if panel.runModal() == .OK, let url = panel.url {
            LibraryOverrides.set(id: type.id, path: url.path)
            overrides = LibraryOverrides.loadRaw()
            onChange()
        }
    }
}

/// sheet wrapper for presenting the editor over another sheet (the New Job sheet).
struct LibraryLocationsSheet: View {
    @Binding var isPresented: Bool
    var onChange: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Library locations").font(.title2.bold())
                Spacer()
                Button("Done") { isPresented = false }.keyboardShortcut(.defaultAction)
            }
            .padding(20)
            Divider()
            Form { LibraryLocationsList(onChange: onChange) }
                .formStyle(.grouped)
        }
        .frame(width: 520, height: 460)
    }
}
