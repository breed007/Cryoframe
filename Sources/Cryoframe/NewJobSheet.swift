//
//  NewJobSheet.swift
//  Cryoframe (app)
//
//  The full form for editing a job (and a fallback create path). All job-building state
//  and logic lives in JobDraft — this view only renders and binds to it.
//

import SwiftUI
import AppKit
import CryoframeKit

struct NewJobSheet: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    @StateObject private var draft: JobDraft

    @State private var showLocations = false
    @State private var pendingCloudURL: URL?
    @State private var pendingCloudProvider: CloudProvider = .generic
    @State private var revealedPassphrase: String?

    init(model: AppModel, isPresented: Binding<Bool>, editing: BackupJob? = nil) {
        self.model = model
        self._isPresented = isPresented
        self._draft = StateObject(wrappedValue: JobDraft(model: model, editing: editing))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(draft.isEditing ? "Edit backup job" : "New backup job").font(.title2.bold())
                Spacer()
            }
            .padding([.horizontal, .top], 20).padding(.bottom, 8)

            Form {
                librariesSection
                destinationsSection
                formatSection
                encryptionSection
                if draft.isSealed { retentionSection }
                scheduleSection
                verificationSection
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button(draft.isEditing ? "Save" : "Create") { if draft.commit() { isPresented = false } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isValid)
            }
            .padding(20)
        }
        .frame(width: 560, height: 640)
        .sheet(isPresented: Binding(get: { pendingCloudURL != nil }, set: { if !$0 { pendingCloudURL = nil } })) {
            if let url = pendingCloudURL {
                CloudDestinationSheet(url: url, provider: pendingCloudProvider,
                                      isPresented: Binding(get: { pendingCloudURL != nil }, set: { if !$0 { pendingCloudURL = nil } }),
                                      onConfirm: { confirmCloud($0) })
            }
        }
        .sheet(isPresented: $showLocations) {
            LibraryLocationsSheet(isPresented: $showLocations) { draft.refreshBuiltInLibraries() }
        }
    }

    // MARK: sections

    private var librariesSection: some View {
        Section {
            ForEach(draft.libraries) { lib in
                Toggle(isOn: libBinding(lib.id)) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(lib.displayName)
                            if let valid = model.libraryValid[lib.id] {
                                Image(systemName: valid ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .font(.caption2).foregroundStyle(valid ? .cryoGood : .cryoCrit)
                            }
                        }
                        if let p = lib.paths.first { FinderPathLink(path: p.liveURL(home: NSHomeDirectory()).path) }
                    }
                }
            }
            HStack {
                Menu("Add library…") {
                    ForEach(LibraryTemplate.all) { t in Button(t.displayName + "…") { addTemplatedLibrary(t) } }
                    Divider()
                    Button("Plain folder…") { addFolderContentType() }
                }
                Spacer()
                Button("Edit locations…") { showLocations = true }
            }
        } header: { Text("Libraries") }
        footer: { Text("Pick one or more. All selected libraries are frozen in one snapshot and archived together to the destination, each in its own folder.").font(.caption).foregroundStyle(.secondary) }
    }

    private var destinationsSection: some View {
        Section {
            ForEach(draft.targets) { t in
                Toggle(isOn: destBinding(t.id)) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(t.displayName)
                            if draft.primaryTarget?.id == t.id {
                                Text("primary").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(Color.cryoAccent.opacity(0.2))).foregroundStyle(.tint)
                            }
                        }
                        FinderPathLink(path: t.destinationDir.path)
                    }
                }
                .contextMenu {
                    if model.canRemoveTarget(t.id) {
                        Button("Remove from list", role: .destructive) { draft.removeTarget(t.id) }
                    }
                }
            }
            Menu("Add destination…") {
                Button("Local folder…") { addTarget(.local) }
                Button("Network or external drive (resumable)…") { addTarget(.external) }
                Button("Cloud-sync folder…") { addTarget(.cloud) }
                let detected = CloudProvider.detectFolders(home: NSHomeDirectory())
                if !detected.isEmpty {
                    Divider()
                    ForEach(detected, id: \.url) { folder in
                        Button("\(folder.provider.displayName) — \(folder.url.lastPathComponent)") { addTargetAt(folder.url, kind: .cloud) }
                    }
                }
            }
            if draft.hasDuplicateDestinations {
                Label("Two destinations point at the same folder — only one copy will be kept.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.cryoWarn).font(.caption)
            }
            if let cloud = draft.selectedTargets.first(where: { $0.cloudProvider != nil })?.cloudProvider {
                Label("\(cloud.displayName) uploads through its app and may offload files to save space. A scheduled health check skips offloaded copies rather than re-downloading them (changeable in Settings ▸ Archive health).", systemImage: "cloud")
                    .foregroundStyle(.secondary).font(.caption)
            }
            ForEach(draft.destinationConflicts, id: \.self) { c in
                Label(c, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.cryoWarn).font(.caption)
            }
        } header: { Text("Destinations") }
        footer: { Text("Each selected destination gets its own copy from the same snapshot. The first is the primary — a run must reach it; if a secondary is offline the run finishes as a partial backup. A second copy on another drive or off-site is the 3-2-1 rule. Right-click a destination to remove it from the list.").font(.caption).foregroundStyle(.secondary) }
    }

    private var formatSection: some View {
        Section("Format") {
            Picker("Format", selection: $draft.formatKind) {
                Text("Live mirror").tag("mirror")
                if !draft.encrypt { Text("Sealed zip").tag("zip") }
                Text("Sealed DMG").tag("dmg")
            }
            if draft.formatKind == "mirror" {
                HStack {
                    Text("Mirror size"); Spacer()
                    TextField("", value: $draft.mirrorValue, format: .number).textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing).frame(width: 64)
                        .onChange(of: draft.mirrorValue) { _, v in if v < 1 { draft.mirrorValue = 1 } }
                    Picker("", selection: $draft.mirrorUnit) { Text("GB").tag("GB"); Text("TB").tag("TB") }.labelsHidden().frame(width: 72)
                }
            }
        }
    }

    private var encryptionSection: some View {
        Section {
            Toggle("Encrypt with AES-256", isOn: $draft.encrypt)
                .onChange(of: draft.encrypt) { _, on in if on, draft.formatKind == "zip" { draft.formatKind = "dmg" } }
            if draft.encrypt {
                SecureField("Passphrase", text: $draft.passphrase)
                SecureField("Confirm passphrase", text: $draft.passphraseConfirm)
                if draft.isEditing {
                    if let saved = revealedPassphrase {
                        HStack {
                            Text(saved).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            Spacer(); Button("Copy") { copyToClipboard(saved) }
                        }
                        Text("Leave the fields above blank to keep this passphrase.").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Button("Reveal saved passphrase…") { revealedPassphrase = KeychainArchiveKey.load(jobID: draft.editingID ?? "") }
                    }
                }
            }
        } header: { Text("Encryption") }
        footer: {
            if draft.encrypt {
                Text("The archive is encrypted with AES-256; the passphrase is kept only in this Mac's Keychain. Copy it into your password manager now — if you lose it (or lose this Mac), the backup can't be decrypted. There is no reset. Sealed zip isn't available when encrypting.").font(.caption).foregroundStyle(.cryoWarn)
            } else {
                Text("Encrypt sealed-DMG and live-mirror archives so a copy on a drive, NAS, or cloud folder is unreadable without your passphrase.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var retentionSection: some View {
        Section {
            Picker("Keep", selection: $draft.retentionKind) {
                Text("All versions").tag("all"); Text("Last N versions").tag("lastN"); Text("Daily / weekly / monthly").tag("gfs")
            }
            if draft.retentionKind == "lastN" {
                Stepper("Keep \(draft.keepN) version\(draft.keepN == 1 ? "" : "s")", value: $draft.keepN, in: 1...365)
            } else if draft.retentionKind == "gfs" {
                Stepper("Keep \(draft.gfsDaily) daily", value: $draft.gfsDaily, in: 0...60)
                Stepper("Keep \(draft.gfsWeekly) weekly", value: $draft.gfsWeekly, in: 0...52)
                Stepper("Keep \(draft.gfsMonthly) monthly", value: $draft.gfsMonthly, in: 0...60)
            }
        } header: { Text("Versions to keep") }
        footer: { Text("Each run of a sealed job is saved as a dated version, so you can restore a point in time. Versions beyond this policy are pruned after a run. (Live mirror keeps a single up-to-date copy instead.)").font(.caption).foregroundStyle(.secondary) }
    }

    private var scheduleSection: some View {
        Section("Schedule") {
            Picker("Run", selection: $draft.freqKind) {
                Text("Daily").tag(JobDraft.FreqKind.daily); Text("Every N hours").tag(JobDraft.FreqKind.everyHours)
                Text("Once").tag(JobDraft.FreqKind.once); Text("Manual only").tag(JobDraft.FreqKind.manual)
            }
            switch draft.freqKind {
            case .daily:      DatePicker("At", selection: $draft.dailyTime, displayedComponents: .hourAndMinute)
            case .everyHours: Stepper("Every \(draft.everyHours) hours", value: $draft.everyHours, in: 1...168)
            case .once:       DatePicker("At", selection: $draft.onceDate)
            case .manual:     EmptyView()
            }
        }
    }

    private var verificationSection: some View {
        Section("Verification") {
            Picker("Verify", selection: $draft.verification) {
                Text("Checksum").tag(VerificationPolicy.checksumOnly); Text("Mount & open").tag(VerificationPolicy.mountAndOpen)
            }
            Picker("If app is open", selection: $draft.runPolicy) {
                Text("Proceed").tag(RunPolicy.proceed); Text("Warn").tag(RunPolicy.warnIfRunning); Text("Defer").tag(RunPolicy.deferIfRunning)
            }
        }
    }

    // MARK: helpers

    private func libBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { draft.selectedLibraryIDs.contains(id) }, set: { _ in draft.toggleLibrary(id) })
    }
    private func destBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { draft.selectedTargetIDs.contains(id) }, set: { _ in draft.toggleTarget(id) })
    }
    private func copyToClipboard(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }

    private func addFolderContentType() {
        guard let url = pickFolder() else { return }
        draft.addLibrary(ContentType.genericFolder(id: url.path, displayName: url.lastPathComponent,
                                                   path: ContentView.libraryPath(for: url, home: NSHomeDirectory())), at: url)
    }
    private func addTemplatedLibrary(_ template: LibraryTemplate) {
        guard let url = pickFolder() else { return }
        draft.addLibrary(template.contentType(id: url.path, displayName: url.lastPathComponent,
                                              path: ContentView.libraryPath(for: url, home: NSHomeDirectory())), at: url)
    }

    private enum DestKind { case local, external, cloud }
    private func addTarget(_ kind: DestKind) { guard let url = pickFolder() else { return }; addTargetAt(url, kind: kind) }
    private func addTargetAt(_ url: URL, kind: DestKind) {
        switch kind {
        case .local:    draft.addTarget(.localVolume(id: url.path, name: url.lastPathComponent, dir: url))
        case .external: draft.addTarget(.externalDrive(id: url.path, name: url.lastPathComponent + " (resumable)", dir: url))
        case .cloud:    pendingCloudProvider = CloudProvider.identify(url); pendingCloudURL = url
        }
    }
    private func confirmCloud(_ bytes: UInt64) {
        guard let url = pendingCloudURL else { return }
        draft.addTarget(.cloudSyncFolder(id: url.path, name: "\(url.lastPathComponent) (\(pendingCloudProvider.displayName))",
                                         dir: url, provider: pendingCloudProvider, maxFileBytes: bytes))
        pendingCloudURL = nil
    }
    private func pickFolder() -> URL? {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
