//
//  RestoreView.swift
//  Cryoframe (app)
//
//  The other half of the loop: pick a folder of archives, choose what to restore,
//  and copy the libraries back out to a destination folder. Restores beside the
//  live library (never over it); the user moves it into place or opens it.
//

import SwiftUI
import AppKit
import CryoframeKit

@MainActor
final class RestoreModel: ObservableObject {
    @Published var sourceFolder: URL?
    @Published var archives: [RestorableArchive] = []
    @Published var selected: Set<String> = []
    @Published var destFolder: URL? = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
    @Published var verify = true
    @Published var passphrase = ""
    @Published var running = false
    @Published var stage = ""
    @Published var results: [Outcome] = []
    @Published var pendingInPlace: RestorableArchive?    // awaiting the replace-in-place confirmation
    @Published var pendingDelete: RestorableArchive?     // awaiting the delete-version confirmation
    @Published var errorMessage: String?
    @Published var browsingName: String?                 // an archive is mounted for in-app browsing
    @Published var browseRoot: URL?                       // the opened tree to browse, drives the sheet
    private var opened: OpenedArchive?

    struct Outcome: Identifiable { let id = UUID(); let name: String; let ok: Bool; let detail: String; let url: URL? }

    /// a passphrase is needed if any archive in the list is encrypted (covers
    /// restore, restore-in-place, and browse).
    var needsPassphrase: Bool { archives.contains { $0.encrypted } }

    /// the live location of a library by display name, if Cryoframe knows it — gates
    /// the restore-in-place option.
    func liveLocation(forLibraryNamed name: String) -> (type: ContentType, url: URL)? {
        let reg = ContentTypeRegistry.withOverrides(LibraryOverrides.load())
        guard let type = reg.types.first(where: { $0.displayName == name }),
              let url = ContentLocator().liveRoots(of: type).first else { return nil }
        return (type, url)
    }

    func canRestoreInPlace(_ a: RestorableArchive) -> Bool { liveLocation(forLibraryNamed: a.libraryName) != nil }

    /// validate, then ask for confirmation (the actual replace runs in confirmInPlace).
    func requestInPlace(_ a: RestorableArchive) {
        guard let (type, _) = liveLocation(forLibraryNamed: a.libraryName) else { return }
        if a.encrypted, passphrase.isEmpty { errorMessage = "Enter the archive's passphrase first."; return }
        if let proc = type.owningProcess, WorkspaceProcessDetector().isRunning(proc) {
            errorMessage = "Quit \(proc.displayName) before replacing its library in place."; return
        }
        pendingInPlace = a
    }

    func confirmInPlace() {
        guard let a = pendingInPlace, let (_, liveURL) = liveLocation(forLibraryNamed: a.libraryName) else { pendingInPlace = nil; return }
        pendingInPlace = nil
        let pass = a.encrypted ? passphrase : nil
        running = true; stage = "\(a.bundleName): replacing in place…"; results = []
        Task {
            results = [await Self.inPlace(a, liveURL: liveURL, passphrase: pass)]
            running = false; stage = ""
        }
    }

    private nonisolated static func inPlace(_ a: RestorableArchive, liveURL: URL, passphrase: String?) async -> Outcome {
        await Task.detached {
            let fm = FileManager.default
            let parent = liveURL.deletingLastPathComponent()
            let staging = parent.appendingPathComponent(".cryoframe-restore-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: staging) }
            do {
                // 1. restore + verify into a staging copy FIRST — the live library is
                //    never touched until we have a good copy in hand.
                let restored = try RestoreEngine().restore(a, to: staging, verify: true, passphrase: passphrase)
                // 2. move the current library to the Trash (reversible).
                if fm.fileExists(atPath: liveURL.path) { try fm.trashItem(at: liveURL, resultingItemURL: nil) }
                // 3. swap the verified copy into the exact original location (also
                //    fixes any archived-vs-live name mismatch).
                do {
                    try fm.moveItem(at: restored, to: liveURL)
                } catch {
                    // move failed — rescue the verified copy OUT of staging first, or
                    // the defer below deletes the very file this message points at.
                    var rescued = parent.appendingPathComponent("\(liveURL.lastPathComponent) (recovered)")
                    if fm.fileExists(atPath: rescued.path) {
                        rescued = parent.appendingPathComponent("\(liveURL.lastPathComponent) (recovered \(UUID().uuidString.prefix(8)))")
                    }
                    let finalURL = (try? fm.moveItem(at: restored, to: rescued)) != nil ? rescued : restored
                    return Outcome(name: a.bundleName, ok: false,
                                   detail: "restored and verified, but couldn't move it into place — the good copy is at \(finalURL.path)",
                                   url: finalURL)
                }
                return Outcome(name: a.bundleName, ok: true,
                               detail: "restored in place — the previous version is in the Trash", url: liveURL)
            } catch {
                return Outcome(name: a.bundleName, ok: false,
                               detail: "in-place restore failed — \(Self.message(error, encrypted: a.encrypted)). Your live library was left untouched.",
                               url: nil)
            }
        }.value
    }

    /// mount/extract an archive read-only and open the in-app file browser so the
    /// user can pull individual files out. Stays open until endBrowse().
    func browse(_ a: RestorableArchive) {
        if a.encrypted, passphrase.isEmpty { errorMessage = "Enter the archive's passphrase first."; return }
        let pass = a.encrypted ? passphrase : nil
        let result = a.archiveResult()
        stage = "\(a.bundleName): opening…"
        Task {
            do {
                let o = try await Task.detached { try ArchiveReader().open(result, passphrase: pass) }.value
                opened?.close()
                opened = o
                browsingName = a.bundleName
                browseRoot = o.root
                stage = ""
            } catch {
                stage = ""
                errorMessage = "Couldn't open \(a.bundleName)" + (a.encrypted ? " — check the passphrase." : ".")
            }
        }
    }

    func endBrowse() {
        opened?.close()
        opened = nil
        browsingName = nil
        browseRoot = nil
    }

    func confirmDelete() {
        guard let a = pendingDelete else { return }
        pendingDelete = nil
        do {
            try FileManager.default.removeItem(at: a.dir)
            if let folder = sourceFolder { scan(folder) }
        } catch {
            errorMessage = "Couldn't delete: \((error as NSError).localizedDescription)"
        }
    }

    func scan(_ folder: URL) {
        sourceFolder = folder
        archives = RestoreDiscovery.scan(folder)
        selected = Set(archives.map(\.id))
        results = []
    }

    func run() {
        guard let dest = destFolder, !running else { return }
        let items = archives.filter { selected.contains($0.id) }
        guard !items.isEmpty else { return }
        let doVerify = verify
        let pass = passphrase
        running = true; results = []
        Task {
            var outcomes: [Outcome] = []
            for a in items {
                stage = "\(a.bundleName): starting"
                outcomes.append(await Self.restoreOne(a, to: dest, verify: doVerify,
                                                      passphrase: a.encrypted ? pass : nil) { s in
                    Task { @MainActor in self.stage = "\(a.bundleName): \(s.rawValue)" }
                })
            }
            results = outcomes; running = false; stage = ""
        }
    }

    private nonisolated static func restoreOne(_ a: RestorableArchive, to dest: URL, verify: Bool, passphrase: String?,
                                               onStage: @escaping @Sendable (RestoreStage) -> Void) async -> Outcome {
        await Task.detached {
            do {
                let url = try RestoreEngine().restore(a, to: dest, verify: verify, passphrase: passphrase, onStage: onStage)
                return Outcome(name: a.bundleName, ok: true, detail: "restored", url: url)
            } catch {
                return Outcome(name: a.bundleName, ok: false, detail: Self.message(error, encrypted: a.encrypted), url: nil)
            }
        }.value
    }

    private nonisolated static func message(_ e: Error, encrypted: Bool) -> String {
        switch e as? RestoreError {
        case .verificationFailed(let d): return "verification failed — \(d)"
        case .destinationExists:         return "already exists in the destination"
        case .libraryNotFound:           return "library not found inside the archive"
        case .noManifest:                return "no checksum manifest"
        case .none:                      return encrypted ? "couldn't open — check the passphrase" : (e as NSError).localizedDescription
        }
    }
}

struct RestoreView: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    @StateObject private var r = RestoreModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Restore").font(.title2.bold())
                Spacer()
                Button("Done") { isPresented = false }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            ScrollView { content.padding() }
        }
        .frame(width: 580, height: 580)
        .onDisappear { r.endBrowse() }
        .sheet(isPresented: Binding(get: { r.browseRoot != nil }, set: { if !$0 { r.endBrowse() } })) {
            if let root = r.browseRoot {
                FileBrowserView(archiveName: r.browsingName ?? "archive", root: root) { r.endBrowse() }
            }
        }
        .alert("Replace your live library?",
               isPresented: Binding(get: { r.pendingInPlace != nil }, set: { if !$0 { r.pendingInPlace = nil } })) {
            Button("Cancel", role: .cancel) { r.pendingInPlace = nil }
            Button("Replace", role: .destructive) { r.confirmInPlace() }
        } message: {
            Text("Your current “\(r.pendingInPlace?.bundleName ?? "library")” will be moved to the Trash and replaced with this archive. You can recover it from the Trash if needed.")
        }
        .alert("Restore", isPresented: Binding(get: { r.errorMessage != nil }, set: { if !$0 { r.errorMessage = nil } })) {
            Button("OK") { r.errorMessage = nil }
        } message: { Text(r.errorMessage ?? "") }
        .alert("Delete this archive version?",
               isPresented: Binding(get: { r.pendingDelete != nil }, set: { if !$0 { r.pendingDelete = nil } })) {
            Button("Cancel", role: .cancel) { r.pendingDelete = nil }
            Button("Delete", role: .destructive) { r.confirmDelete() }
        } message: {
            Text("Permanently delete this version of “\(r.pendingDelete?.bundleName ?? "")”\(r.pendingDelete?.version.map { " from " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "")? This can't be undone.")
        }
    }

    @ViewBuilder private var content: some View {
        source
        if r.sourceFolder != nil { archivesSection }
        destination
        if !r.results.isEmpty { resultsSection }
        actionRow
    }

    private var source: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("1 · Where the archives are").font(.headline)
            HStack {
                Button("Choose folder…") { chooseFolder { r.scan($0) } }
                if let s = r.sourceFolder {
                    Text(s.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            let sources = model.restoreSources
            if !sources.isEmpty {
                HStack(spacing: 6) {
                    Text("Quick pick:").font(.caption).foregroundStyle(.tertiary)
                    ForEach(sources) { t in
                        Button(t.displayName) { r.scan(t.destinationDir) }.buttonStyle(.link).font(.caption)
                    }
                }
            }
        }
    }

    private var archivesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("2 · What to restore").font(.headline)
            if r.archives.isEmpty {
                Text("No Cryoframe archives found in that folder.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(r.archives) { a in
                    HStack(spacing: 4) {
                        Toggle(isOn: selection(a.id)) {
                            HStack(spacing: 8) {
                                Text(a.bundleName)
                                if a.encrypted { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary) }
                                if let v = a.version {
                                    Text(v.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2).foregroundStyle(.blue)
                                }
                                Text(formatLabel(a.format)).font(.caption2).foregroundStyle(.tertiary)
                                Text(ByteCountFormatter.string(fromByteCount: Int64(a.bytes), countStyle: .file))
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        Spacer(minLength: 0)
                        Menu {
                            if r.canRestoreInPlace(a) { Button("Restore in place…") { r.requestInPlace(a) } }
                            Button("Browse contents…") { r.browse(a) }
                            Divider()
                            Button("Delete this version…", role: .destructive) { r.pendingDelete = a }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                }
            }
        }
    }

    private var destination: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("3 · Restore into").font(.headline)
            HStack {
                Button("Choose…") { chooseFolder { r.destFolder = $0 } }
                if let d = r.destFolder {
                    Text(d.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Toggle("Verify checksums before restoring", isOn: $r.verify)
            if r.needsPassphrase {
                SecureField("Passphrase", text: $r.passphrase)
                    .textFieldStyle(.roundedBorder)
                Text("This archive is encrypted — enter its passphrase to open it.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text("The library is copied next to anything already there — it never overwrites your live library. Move it into place (or double-click to open) once it's restored.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("Results").font(.headline)
            ForEach(r.results) { o in
                HStack(spacing: 8) {
                    Image(systemName: o.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(o.ok ? .green : .red)
                    Text(o.name)
                    Text(o.detail).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    if let url = o.url {
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(.link)
                    }
                }
                .font(.callout)
            }
        }
    }

    private var actionRow: some View {
        HStack {
            if r.running {
                ProgressView().controlSize(.small)
                Text(r.stage).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Restore") { r.run() }
                .keyboardShortcut(.return)
                .disabled(r.running || r.destFolder == nil || r.selected.isEmpty
                          || (r.needsPassphrase && r.passphrase.isEmpty))
        }
        .padding(.top, 8)
    }

    // MARK: helpers

    private func selection(_ id: String) -> Binding<Bool> {
        Binding(get: { r.selected.contains(id) },
                set: { if $0 { r.selected.insert(id) } else { r.selected.remove(id) } })
    }

    private func chooseFolder(_ then: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { then(url) }
    }

    private func formatLabel(_ f: ArchiveFormat) -> String {
        switch f { case .sealedDMG: "Sealed DMG"; case .sealedZip: "Sealed zip"; case .liveMirror: "Live mirror" }
    }
}
