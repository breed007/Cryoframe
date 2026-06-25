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

    struct Outcome: Identifiable { let id = UUID(); let name: String; let ok: Bool; let detail: String; let url: URL? }

    /// any selected archive is encrypted → a passphrase is required to open it.
    var needsPassphrase: Bool { archives.contains { selected.contains($0.id) && $0.encrypted } }

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
            if !model.targets.isEmpty {
                HStack(spacing: 6) {
                    Text("Quick pick:").font(.caption).foregroundStyle(.tertiary)
                    ForEach(model.targets) { t in
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
