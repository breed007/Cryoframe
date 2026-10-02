//
//  RestoreView.swift
//  Cryoframe (app)
//
//  The other half of the loop, as a timeline: pick where the archives are, then
//  travel a library's saved versions and bring one back — as a copy beside your
//  live library (the safe default) or in place over it. A live mirror has no
//  history, so it shows a single "current" state instead of a timeline.
//

import SwiftUI
import AppKit
import CryoframeKit

@MainActor
final class RestoreModel: ObservableObject {
    @Published var sourceFolder: URL?
    @Published var archives: [RestorableArchive] = []
    @Published var destFolder: URL? = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
    @Published var passphrase = ""
    @Published var running = false
    @Published var stage = ""
    @Published var results: [Outcome] = []
    @Published var pendingInPlace: RestorableArchive?    // awaiting the replace-in-place confirmation
    @Published var pendingDelete: RestorableArchive?     // awaiting the delete-version confirmation
    @Published var errorMessage: String?
    @Published var browsingName: String?                 // an archive is mounted for in-app browsing
    @Published var browseWarning: String?                 // said in the browser: how the archive was opened
    @Published var browseRoot: URL?                       // the opened tree to browse, drives the sheet
    private var opened: OpenedArchive?

    /// `clashed`: the restore stopped because the name is taken in the destination,
    /// and can be run again alongside it
    struct Outcome: Identifiable {
        let id = UUID(); let name: String; let ok: Bool; let detail: String; let url: URL?
        var clashed: RestorableArchive? = nil
    }

    /// the live location of a library by display name, if Cryoframe knows it — gates
    /// the restore-in-place option.
    func liveLocation(forLibraryNamed name: String) -> (type: ContentType, url: URL)? {
        let reg = ContentTypeRegistry.withOverrides(LibraryOverrides.load())
        guard let type = reg.types.first(where: { $0.displayName == name }),
              let url = ContentLocator().liveRoots(of: type).first else { return nil }
        return (type, url)
    }

    func canRestoreInPlace(_ a: RestorableArchive) -> Bool { liveLocation(forLibraryNamed: a.displayName) != nil }

    // MARK: - timeline grouping

    // grouping lives in the engine (RestoreDiscovery) so it's unit-tested; these are
    // thin pass-throughs for the view.
    var orderedLibraries: [String] { RestoreDiscovery.libraries(in: archives) }
    func versions(of library: String) -> [RestorableArchive] { RestoreDiscovery.versions(of: library, in: archives) }
    func isSingleCurrent(_ library: String) -> Bool { RestoreDiscovery.isSingleCurrent(library, in: archives) }

    // MARK: - restore actions

    /// validate, then ask for confirmation (the actual replace runs in confirmInPlace).
    func requestInPlace(_ a: RestorableArchive) {
        guard let (type, _) = liveLocation(forLibraryNamed: a.displayName) else { return }
        if a.encrypted, passphrase.isEmpty { errorMessage = "Enter the archive's passphrase first."; return }
        if let proc = type.owningProcess, WorkspaceProcessDetector().isRunning(proc) {
            errorMessage = "Quit \(proc.displayName) before replacing its library in place."; return
        }
        pendingInPlace = a
    }

    func confirmInPlace() {
        guard let a = pendingInPlace, let (_, liveURL) = liveLocation(forLibraryNamed: a.displayName) else { pendingInPlace = nil; return }
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
                let restored = try RestoreEngine().restore(a, to: staging, verify: true, passphrase: passphrase, inPlace: true)
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
                               detail: "in-place restore failed — \(RestoreFailureText.restoreMessage(error, encrypted: a.encrypted)). Your live library was left untouched.",
                               url: nil)
            }
        }.value
    }

    /// restore one version as a copy into the chosen destination folder (never over
    /// the live library). The timeline's "Beside" action.
    func restore(_ a: RestorableArchive, onClash: RestoreClash = .refuse) {
        guard let dest = destFolder, !running else { return }
        let pass = passphrase
        running = true; results = []
        Task {
            stage = "\(a.bundleName): starting"
            // always verify before writing — a restore you can't trust isn't a restore.
            let o = await Self.restoreOne(a, to: dest, verify: true, passphrase: a.encrypted ? pass : nil, onClash: onClash) { s in
                Task { @MainActor in self.stage = "\(a.bundleName): \(s.rawValue)" }
            }
            results = [o]; running = false; stage = ""
        }
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
                browseWarning = o.warning
                stage = ""
            } catch {
                stage = ""
                // only a passphrase the image refused is called a passphrase problem
                errorMessage = ArchiveOpener.failureText(error, name: a.bundleName, tried: a.encrypted ? 1 : 0)
            }
        }
    }

    func endBrowse() {
        opened?.close()
        opened = nil
        browsingName = nil
        browseWarning = nil
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
        results = []
    }

    /// the warning for the version and place last looked at (see checkRoom)
    @Published var roomWarning: (key: String, text: String?)?

    /// the key the view looks the warning up by: the version, where it goes, and how
    func roomKey(for a: RestorableArchive, inPlace: Bool) -> String {
        "\(a.id)|\(inPlace)|\(destFolder?.path ?? "")"
    }

    /// What stands in the way of restoring `a` to where it would go, said before
    /// anything starts: a drive too small for even a sealed archive (see RestoreRoom).
    /// Read off the main thread, once per version and place: asking a share that
    /// doesn't answer for its free space can take a long time, and this used to be
    /// asked on every redraw of the window.
    func checkRoom(for a: RestorableArchive, inPlace: Bool) async {
        let key = roomKey(for: a, inPlace: inPlace)
        guard roomWarning?.key != key else { return }
        let dest = inPlace ? liveLocation(forLibraryNamed: a.displayName)?.url.deletingLastPathComponent() : destFolder
        guard let dest, let floor = RestoreRoom.floor(for: a) else { roomWarning = (key, nil); return }
        let text = await Task.detached { () -> String? in
            guard let refusal = RestoreRoom.refusal(bytes: floor, free: JobExecutor.freeSpace(for: dest),
                                                    volume: RestoreRoom.volumeName(for: dest), inPlace: inPlace) else { return nil }
            return RestoreFailureText.restoreMessage(refusal, encrypted: false)
        }.value
        if roomKey(for: a, inPlace: inPlace) == key { roomWarning = (key, text) }
    }

    private nonisolated static func restoreOne(_ a: RestorableArchive, to dest: URL, verify: Bool, passphrase: String?,
                                               onClash: RestoreClash,
                                               onStage: @escaping @Sendable (RestoreStage) -> Void) async -> Outcome {
        await Task.detached {
            do {
                let url = try RestoreEngine().restore(a, to: dest, verify: verify, passphrase: passphrase, onClash: onClash, onStage: onStage)
                let renamed = url.lastPathComponent != a.bundleName ? " as “\(url.lastPathComponent)”" : ""
                return Outcome(name: a.bundleName, ok: true, detail: "copied to \(dest.lastPathComponent)\(renamed)", url: url)
            } catch {
                var clash: RestorableArchive?
                if case .destinationExists? = error as? RestoreError { clash = a }
                return Outcome(name: a.bundleName, ok: false, detail: RestoreFailureText.restoreMessage(error, encrypted: a.encrypted),
                               url: nil, clashed: clash)
            }
        }.value
    }
}

private enum RestoreMode: Hashable { case beside, inPlace }

struct RestoreView: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    @StateObject private var r = RestoreModel()

    @State private var selectedLibrary: String?
    @State private var selectedVersionID: String?
    @State private var mode: RestoreMode = .beside
    @State private var finding = false

    // effective selection, with fallbacks so the view is always coherent
    private var activeLibrary: String? { selectedLibrary ?? r.orderedLibraries.first }
    private var activeVersions: [RestorableArchive] { activeLibrary.map { r.versions(of: $0) } ?? [] }
    private var activeVersion: RestorableArchive? {
        activeVersions.first { $0.id == selectedVersionID } ?? activeVersions.first
    }
    private var canInPlace: Bool { activeVersion.map { r.canRestoreInPlace($0) } ?? false }
    private var effectiveMode: RestoreMode { canInPlace ? mode : .beside }

    var body: some View {
        VStack(spacing: 0) {
            CryoSheetHeader(title: "Restore", symbol: "arrow.uturn.backward.circle",
                            subtitle: "Travel back to any saved version and bring it back") {
                isPresented = false
            }
            Divider()
            if r.sourceFolder == nil {
                chooseSourcePrompt
            } else {
                sourceBar
                Divider()
                if r.archives.isEmpty {
                    CryoEmptyState(symbol: "clock.badge.exclamationmark", title: "No archives here",
                                   message: "No Cryoframe archives were found in that folder. Choose the drive or folder your backups were written to.")
                } else {
                    HStack(spacing: 0) {
                        libraryRail.frame(width: 220)
                        Divider()
                        timelinePane.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(maxHeight: .infinity)
                    Divider()
                    restoreBar
                }
            }
        }
        // at least 740 × 600, and as tall as the window it covers (see ContentView)
        .frame(width: 740)
        .frame(minHeight: 600, maxHeight: .infinity)
        .onDisappear { r.endBrowse() }
        .sheet(isPresented: Binding(get: { r.browseRoot != nil }, set: { if !$0 { r.endBrowse() } })) {
            if let root = r.browseRoot {
                FileBrowserView(archiveName: r.browsingName ?? "archive", root: root, warning: r.browseWarning) { r.endBrowse() }
            }
        }
        .sheet(isPresented: $finding) {
            FindFileView(restore: r) { finding = false }
        }
        .alert("Replace your live library?",
               isPresented: Binding(get: { r.pendingInPlace != nil }, set: { if !$0 { r.pendingInPlace = nil } })) {
            Button("Cancel", role: .cancel) { r.pendingInPlace = nil }
            Button("Replace", role: .destructive) { r.confirmInPlace() }
        } message: {
            Text("Your current “\(r.pendingInPlace?.bundleName ?? "library")” will be moved to the Trash and replaced with this version. You can recover it from the Trash if needed.")
        }
        .alert("Restore", isPresented: Binding(get: { r.errorMessage != nil }, set: { if !$0 { r.errorMessage = nil } })) {
            Button("OK") { r.errorMessage = nil }
        } message: { Text(r.errorMessage ?? "") }
        .alert("Delete this archive version?",
               isPresented: Binding(get: { r.pendingDelete != nil }, set: { if !$0 { r.pendingDelete = nil } })) {
            Button("Cancel", role: .cancel) { r.pendingDelete = nil }
            Button("Delete", role: .destructive) { r.confirmDelete(); model.refreshProtectedSize(force: true) }
        } message: {
            Text("Permanently delete this version of “\(r.pendingDelete?.bundleName ?? "")”\(r.pendingDelete?.version.map { " from " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "")? This can't be undone.")
        }
    }

    // MARK: - source

    private var chooseSourcePrompt: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 36, weight: .light)).foregroundStyle(.tertiary)
            Text("Restore from a backup").font(.headline)
            Text("Choose the drive, NAS, or folder your Cryoframe archives were written to.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 340)
            Button { chooseFolder { scanned($0) } } label: { Label("Choose folder…", systemImage: "folder") }
                .controlSize(.large).padding(.top, 4)
            let sources = model.restoreSources
            if !sources.isEmpty {
                HStack(spacing: 6) {
                    Text("or").font(.caption).foregroundStyle(.tertiary)
                    ForEach(sources) { t in
                        Button(t.displayName) { scanned(DestinationResolver().locate(t).url ?? t.destinationDir) }.buttonStyle(.link).font(.caption)
                    }
                }
                .padding(.top, 2)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var sourceBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").font(.caption).foregroundStyle(.secondary)
            Text("From").font(.caption).foregroundStyle(.secondary)
            Text(r.sourceFolder?.path ?? "").font(.caption).lineLimit(1).truncationMode(.middle)
            Button("Change…") { chooseFolder { scanned($0) } }.buttonStyle(.link).font(.caption)
            Spacer()
            if !r.archives.isEmpty {
                Button { finding = true } label: { Label("Find a File…", systemImage: "magnifyingglass") }
                    .controlSize(.small)
                    .help("See which saved versions hold a file or folder")
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
    }

    // MARK: - library rail

    private var libraryRail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("IN THIS FOLDER").font(.system(size: 10.5, weight: .bold)).tracking(0.6)
                    .foregroundStyle(.tertiary).padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 2)
                ForEach(r.orderedLibraries, id: \.self) { libraryRow($0) }
            }
            .padding(10)
        }
        .background(Color.cryoElevated.opacity(0.5))
    }

    private func libraryRow(_ lib: String) -> some View {
        let vers = r.versions(of: lib)
        let mirror = r.isSingleCurrent(lib)
        let isActive = lib == activeLibrary
        return Button {
            selectedLibrary = lib
            selectedVersionID = vers.first?.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbolFor(lib))
                    .font(.system(size: 14)).frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.cryoAccent.opacity(0.15)))
                    .foregroundStyle(.cryoAccent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(lib).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(mirror ? "Live mirror" : "\(vers.count) version\(vers.count == 1 ? "" : "s")")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(mirror ? "current · no history" : (vers.first?.version).map { "newest " + relative($0) } ?? "")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(mirror ? Color.secondary.opacity(0.7) : Color.cryoAccent)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 10).fill(isActive ? AnyShapeStyle(.background) : AnyShapeStyle(Color.clear)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isActive ? Color.cryoAccent.opacity(0.5) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
        .accessibilityLabel("\(lib), \(mirror ? "live mirror" : "\(vers.count) versions")")
    }

    // MARK: - timeline

    @ViewBuilder private var timelinePane: some View {
        if let lib = activeLibrary {
            if r.isSingleCurrent(lib) {
                mirrorPane(lib)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        timelineHeader(lib)
                        timelineList(lib)
                    }
                    .padding(16)
                }
            }
        }
    }

    private func timelineHeader(_ lib: String) -> some View {
        let vers = r.versions(of: lib)
        let fmt = vers.first.map { formatLabel($0.format) } ?? ""
        let enc = vers.contains { $0.encrypted }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(lib).font(.system(size: 16, weight: .bold))
                    Text("\(vers.count) version\(vers.count == 1 ? "" : "s") · \(fmt)\(enc ? " · encrypted" : "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if vers.count >= 2 {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("SIZE OVER TIME").font(.system(size: 9, weight: .bold)).tracking(0.5).foregroundStyle(.tertiary)
                        Sparkline(values: vers.reversed().map { Double($0.bytes) }).frame(width: 120, height: 30)
                    }
                }
            }
            if enc { passphraseField(vers) }
            Divider()
        }
        .padding(.bottom, 4)
    }

    /// the job an encrypted library's backups were made by (its folder's identity), when
    /// this Mac still has its passphrase: a deleted job's is kept for exactly this
    private func savedPassphraseJob(_ vers: [RestorableArchive]) -> String? {
        vers.lazy.compactMap { $0.libraryKey?.split(separator: "/").first.map(String.init) }
            .first { KeychainArchiveKey.exists(jobID: $0) }
    }

    private func passphraseField(_ vers: [RestorableArchive]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                SecureField("Passphrase", text: $r.passphrase).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                if r.passphrase.isEmpty, let id = savedPassphraseJob(vers) {
                    Button("Use the passphrase saved on this Mac") { r.passphrase = KeychainArchiveKey.load(jobID: id) ?? "" }
                        .buttonStyle(.link).font(.caption)
                }
            }
            Text("This library is encrypted — enter its passphrase to restore or browse a version.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func timelineList(_ lib: String) -> some View {
        let vers = r.versions(of: lib)
        let maxB = vers.map(\.bytes).max() ?? 1
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(vers.enumerated()), id: \.element.id) { idx, v in
                if idx == 0 || groupLabel(vers[idx - 1].version) != groupLabel(v.version) {
                    Text(groupLabel(v.version)).font(.system(size: 10.5, weight: .bold)).tracking(0.6)
                        .foregroundStyle(.tertiary)
                        .padding(.top, idx == 0 ? 8 : 16).padding(.bottom, 8).padding(.leading, 30)
                }
                versionNode(v, index: idx, count: vers.count, isLatest: idx == 0, maxBytes: maxB)
            }
        }
    }

    private func versionNode(_ v: RestorableArchive, index: Int, count: Int, isLatest: Bool, maxBytes: UInt64) -> some View {
        let isSel = v.id == activeVersion?.id
        return HStack(alignment: .top, spacing: 0) {
            // gutter: a spine that connects the dots, with a node for this version
            VStack(spacing: 0) {
                Rectangle().fill(index == 0 ? Color.clear : Color.cryoLine).frame(width: 2, height: 18)
                Circle()
                    .fill(isSel ? AnyShapeStyle(Color.cryoAccent) : AnyShapeStyle(.background))
                    .overlay(Circle().strokeBorder(isLatest || isSel ? Color.cryoAccent : Color.cryoLine, lineWidth: 2))
                    .frame(width: 13, height: 13)
                Rectangle().fill(index == count - 1 ? Color.clear : Color.cryoLine).frame(width: 2).frame(maxHeight: .infinity)
            }
            .frame(width: 30)
            versionCard(v, isSel: isSel, isLatest: isLatest, maxBytes: maxBytes)
                .padding(.bottom, 10)
        }
        .contentShape(Rectangle())
        .onTapGesture { selectedLibrary = activeLibrary; selectedVersionID = v.id }
    }

    private func versionCard(_ v: RestorableArchive, isSel: Bool, isLatest: Bool, maxBytes: UInt64) -> some View {
        let frac = maxBytes > 0 ? Double(v.bytes) / Double(maxBytes) : 1
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(relative(v.version)).font(.system(size: 14, weight: .semibold))
                    if let d = v.version {
                        Text(d.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    if isLatest { pill("Latest", accent: true) }
                    pill(formatLabel(v.format), accent: false)
                    // made before the job changed kind: kept as it is, never pruned
                    // or read as the job's current backup
                    if LibraryFolders.isKept(v) {
                        pill("Kept", accent: false)
                            .help("Kept from before its job changed between one up-to-date copy and dated versions. Nothing deletes it; you can restore from it like any other.")
                    }
                    if v.encrypted {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                            .accessibilityLabel("encrypted")
                    }
                    assuranceChip(v)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Text(sizeStr(v.bytes)).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.cryoLine).frame(width: 100, height: 5)
                    Capsule().fill(Color.cryoAccent).frame(width: max(6, 100 * frac), height: 5)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(isSel ? Color.cryoAccent : Color.cryoLine, lineWidth: isSel ? 2 : 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(relative(v.version)) version, \(sizeStr(v.bytes))\(isSel ? ", selected" : "")")
    }

    private func mirrorPane(_ lib: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(lib).font(.system(size: 16, weight: .bold))
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 22)).foregroundStyle(.cryoAccent).frame(width: 40)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Current mirror — no version history").font(.callout.weight(.semibold))
                    Text("A live mirror is one copy kept up to date in place, so there's a single state to restore: right now. Point-in-time versions are only kept for sealed archives (DMG or zip).")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.cryoLine, style: StrokeStyle(lineWidth: 1, dash: [5])))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
    }

    // MARK: - restore bar

    private var restoreBar: some View {
        HStack(spacing: 14) {
            restoreLead
            Spacer(minLength: 12)
            restoreActions
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .frame(minHeight: 58)
    }

    @ViewBuilder private var restoreLead: some View {
        if r.running {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(r.stage).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        } else if let o = r.results.first {
            HStack(spacing: 8) {
                Image(systemName: o.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(o.ok ? .cryoGood : .cryoCrit)
                VStack(alignment: .leading, spacing: 1) {
                    Text(o.ok ? "Restored \(o.name)" : "Couldn't restore \(o.name)").font(.callout.weight(.semibold))
                    Text(o.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        } else if let v = activeVersion {
            VStack(alignment: .leading, spacing: 2) {
                Text("Restore \(activeLibrary ?? "") from \(relative(v.version))\(v.version.map { " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "")")
                    .font(.callout)
                if let w = r.roomWarning, w.key == r.roomKey(for: v, inPlace: effectiveMode == .inPlace), let warning = w.text {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.cryoWarn).lineLimit(3)
                }
                if effectiveMode == .inPlace {
                    Text("This version is verified and copied beside your live library, then swapped in; the live library moves to the Trash.")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                } else {
                    HStack(spacing: 4) {
                        Text("Copies to").font(.caption2).foregroundStyle(.secondary)
                        Text(r.destFolder?.lastPathComponent ?? "a folder").font(.caption2).foregroundStyle(.secondary)
                        Button("Change…") { chooseFolder { r.destFolder = $0 } }.buttonStyle(.link).font(.caption2)
                        Text("— never touches your live library.").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .task(id: r.roomKey(for: v, inPlace: effectiveMode == .inPlace)) { await r.checkRoom(for: v, inPlace: effectiveMode == .inPlace) }
        } else {
            Text("Select a version to restore.").font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var restoreActions: some View {
        if r.running {
            EmptyView()
        } else if !r.results.isEmpty {
            if let url = r.results.first?.url {
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            if let clashed = r.results.first?.clashed {
                Button("Restore Alongside") { r.restore(clashed, onClash: .alongside) }
                    .help("Keep what's there, and restore this version beside it under a new name, such as “\(clashed.bundleName) (2)”")
            }
            Button("Done") { r.results = [] }.buttonStyle(.borderedProminent)
        } else if let v = activeVersion {
            if canInPlace {
                Picker("", selection: $mode) {
                    Text("Beside").tag(RestoreMode.beside)
                    Text("In place").tag(RestoreMode.inPlace)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .accessibilityLabel("Restore location")
            }
            Button("Browse…") { r.browse(v) }
                .disabled(v.encrypted && r.passphrase.isEmpty)
            Button(effectiveMode == .inPlace ? "Replace live library" : "Restore this version") { doRestore(v) }
                .buttonStyle(.borderedProminent)
                .disabled(v.encrypted && r.passphrase.isEmpty)
        }
    }

    // MARK: - actions & helpers

    private func doRestore(_ v: RestorableArchive) {
        switch effectiveMode {
        case .beside:  r.restore(v)
        case .inPlace: r.requestInPlace(v)   // opens the confirm alert
        }
    }

    private func scanned(_ url: URL) {
        r.scan(url)
        selectedLibrary = nil
        selectedVersionID = nil
        mode = .beside
    }

    /// "has this exact version been checked, and how thoroughly?" A drill proves the
    /// restore path works; a checksum only proves the bytes still match. Versions that
    /// were never checked show nothing rather than an implied all-clear.
    @ViewBuilder private func assuranceChip(_ v: RestorableArchive) -> some View {
        if let a = ArchiveAssurance.lastVerified(library: v.libraryName, key: v.libraryKey, version: v.version,
                                                 in: model.healthRecords) {
            let drill = a.level == .drill
            let text = drill ? "Restore-tested" : "Checksum verified"
            let when = relative(a.checkedAt).lowercased()
            HStack(spacing: 4) {
                Image(systemName: drill ? "checkmark.seal.fill" : "checkmark.circle")
                    .font(.system(size: 10, weight: .semibold))
                Text(text).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(drill ? AnyShapeStyle(Color.cryoGood) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(drill ? Color.cryoGood.opacity(0.13) : Color.cryoLine))
            .overlay(Capsule().strokeBorder(drill ? Color.cryoGood.opacity(0.35) : Color.cryoLine, lineWidth: 1))
            .help(drill ? "Reassembled, opened, and reopened \(when) — the restore path is proven."
                        : "Checksums re-verified \(when). This confirms the bytes, not that it opens.")
            .accessibilityLabel(drill ? "Restore-tested \(when)" : "Checksum verified \(when)")
        }
    }

    private func pill(_ text: String, accent: Bool) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(accent ? AnyShapeStyle(Color.cryoAccent) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(accent ? Color.cryoAccent.opacity(0.14) : Color.cryoLine))
            .overlay(Capsule().strokeBorder(Color.cryoLine, lineWidth: 1))
    }

    private func chooseFolder(_ then: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { then(url) }
    }

    private func formatLabel(_ f: ArchiveFormat) -> String {
        switch f { case .sealedDMG: "Sealed DMG"; case .sealedZip: "Sealed zip"; case .liveMirror: "Live mirror" }
    }

    private func sizeStr(_ b: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file) }

    private func symbolFor(_ name: String) -> String {
        switch name {
        case "Photos":            "photo.on.rectangle.angled"
        case "Apple Music":       "music.note"
        case "iMovie":            "film"
        case "GarageBand":        "pianokeys"
        case "Messages":          "message.fill"
        case "Mail":              "envelope.fill"
        case "Microsoft Outlook": "envelope.fill"
        default:                  "externaldrive.fill"
        }
    }

    /// a relative day label for a version: Today / Yesterday / weekday / "Jul 18".
    private func relative(_ d: Date?) -> String {
        guard let d else { return "Current" }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day ?? 0
        switch days {
        case ..<0:  return d.formatted(.dateTime.month(.abbreviated).day())
        case 0:     return "Today"
        case 1:     return "Yesterday"
        case 2...6: return d.formatted(.dateTime.weekday(.wide))
        default:    return d.formatted(.dateTime.month(.abbreviated).day())
        }
    }

    private func groupLabel(_ d: Date?) -> String {
        guard let d else { return "Current" }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day ?? 0
        return days <= 6 ? "This week" : "Earlier"
    }
}

/// a tiny area sparkline of a library's size across versions (oldest → newest).
/// An honest coarse trend — not a per-file diff (sealed containers aren't byte-stable).
private struct Sparkline: View {
    let values: [Double]
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            // inset so the endpoint dot and the stroke's round caps sit INSIDE the
            // frame — drawn edge to edge they get sliced in half by the clip.
            let inset: CGFloat = 3
            let plotW = max(w - inset * 2, 1)
            let mn = values.min() ?? 0, mx = values.max() ?? 1, span = max(mx - mn, 1)
            let pts: [CGPoint] = values.count < 2 ? [] : values.enumerated().map { i, v in
                CGPoint(x: inset + plotW * Double(i) / Double(values.count - 1),
                        y: h - (v - mn) / span * (h - 4) - 2)
            }
            ZStack {
                if pts.count >= 2 {
                    Path { p in
                        p.move(to: CGPoint(x: inset, y: h)); pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: w - inset, y: h)); p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [Color.cryoAccent.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom))
                    Path { p in p.move(to: pts[0]); pts.dropFirst().forEach { p.addLine(to: $0) } }
                        .stroke(Color.cryoAccent, style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
                    if let last = pts.last { Circle().fill(Color.cryoAccent).frame(width: 5, height: 5).position(last) }
                }
            }
        }
        .accessibilityHidden(true)
    }
}
