//
//  JobEditor.swift
//  Cryoframe (app)
//
//  The one editor for a backup job, new or existing: what to back up, where the
//  copies go, when, what to keep, and the details. All rules live in JobDraftState
//  (tested in the Kit); this view renders them and asks the Kit what a change does.
//
//  Nothing here touches a destination or a folder being backed up. Saving writes
//  the job; the next backup acts on it. The one exception is Rename this drive,
//  which renames a drive and saves the job by itself, and so is only offered when
//  there are no unsaved changes.
//
//  Words: a job backs up libraries and folders to destinations; the main destination
//  is the one a backup has to reach; drives can take turns; each backup keeps one
//  up-to-date copy or dated versions. (See EditorVocabularyTests.)
//

import SwiftUI
import AppKit
import CryoframeKit

struct JobEditor: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    var initialFolder: URL? = nil
    var initialLibraryID: String? = nil

    @StateObject private var draft: JobDraft
    @State private var seeded = false
    @State private var sourceIssues: [PlaceIssue] = []
    @State private var destinationIssues: [PlaceIssue] = []
    @State private var presence: [String: DestinationPresence] = [:]
    @State private var pendingCloudURL: URL?
    @State private var pendingCloudProvider: CloudProvider = .generic
    @State private var renamingLibrary: ContentType?
    @State private var pairingTarget: Target?
    @State private var renamingDrive: DriveToRename?
    @State private var summary: JobEditImpact?
    @State private var computingSummary = false
    @State private var deleting: BackupJob?
    @State private var revealedPassphrase: String?

    init(model: AppModel, isPresented: Binding<Bool>, editing: BackupJob? = nil,
         initialFolder: URL? = nil, initialLibraryID: String? = nil) {
        self.model = model
        self._isPresented = isPresented
        self.initialFolder = initialFolder
        self.initialLibraryID = initialLibraryID
        self._draft = StateObject(wrappedValue: JobDraft(model: model, editing: editing))
    }

    private var editing: BackupJob? { draft.state.base }
    private var busy: Bool { editing.map { model.isBusy($0.id) } ?? false }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(editing == nil ? "New backup job" : "Edit “\(editing?.name ?? "")”").font(.title2.bold())
                Spacer()
            }
            .padding([.horizontal, .top], 20).padding(.bottom, 8)

            Form {
                backUpSection
                copiesSection
                whenSection
                keepSection
                detailsSection
            }
            .formStyle(.grouped)

            Divider()
            footer
        }
        .frame(width: 640, height: 720)
        .onAppear(perform: seed)
        .task { await watchDrives() }
        .sheet(isPresented: Binding(get: { pendingCloudURL != nil }, set: { if !$0 { pendingCloudURL = nil } })) {
            if let url = pendingCloudURL {
                CloudDestinationSheet(url: url, provider: pendingCloudProvider,
                                      isPresented: Binding(get: { pendingCloudURL != nil }, set: { if !$0 { pendingCloudURL = nil } }),
                                      onConfirm: { confirmCloud($0) })
            }
        }
        .sheet(item: $renamingLibrary) { lib in
            LibraryRenameSheet(library: lib, isPresented: Binding(get: { renamingLibrary != nil }, set: { if !$0 { renamingLibrary = nil } })) { name in
                _ = draft.renameLibrary(lib.id, to: name)
            }
        }
        .sheet(item: $pairingTarget) { t in
            if let job = editing {
                PairingSheet(model: model, job: job, target: t, canRename: !draft.hasUnsavedEdits && !busy,
                             isPresented: Binding(get: { pairingTarget != nil }, set: { if !$0 { pairingTarget = nil } }),
                             onTakeTurns: { drive in _ = draft.pair(t.id, with: drive) },
                             onRename: { drive in
                                 pairingTarget = nil
                                 DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { renamingDrive = DriveToRename(target: t, drive: drive) }
                             })
            }
        }
        .sheet(item: $renamingDrive) { r in
            if let job = editing {
                RenameDriveSheet(model: model, job: job, request: r,
                                 isPresented: Binding(get: { renamingDrive != nil }, set: { if !$0 { renamingDrive = nil } })) { saved in
                    draft.reload(editing: saved)
                    refreshPresence()
                }
            }
        }
        .sheet(item: $summary) { impact in
            SaveSummarySheet(impact: impact, isPresented: Binding(get: { summary != nil }, set: { if !$0 { summary = nil } })) {
                summary = nil
                if draft.commit() { isPresented = false }
            }
        }
        .sheet(item: $deleting) { job in
            JobDeleteSheet(model: model, job: job,
                           isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                           onDeleted: { deleting = nil; isPresented = false })
        }
    }

    // MARK: Back up

    private var backUpSection: some View {
        Section {
            ForEach(draft.libraries) { lib in libraryRow(lib) }
            HStack(spacing: 16) {
                Button { addFolder() } label: { Label("Back up another folder…", systemImage: "folder.badge.plus") }
                Menu("A library from another app…") {
                    ForEach(LibraryTemplate.all) { t in Button(t.displayName + "…") { addTemplated(t) } }
                }
                .fixedSize()
            }
            .buttonStyle(.link)
            issueList(sourceIssues)
            ForEach(draft.libraryNameClashes, id: \.self) { c in
                Label(c, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
        } header: { Text("Back up") }
        footer: { Text("Everything chosen is backed up together, from one moment in time, each in a folder of its own.").font(.caption).foregroundStyle(.secondary) }
    }

    private func libraryRow(_ lib: ContentType) -> some View {
        let on = draft.selectedLibraryIDs.contains(lib.id)
        let path = lib.paths.first?.liveURL(home: NSHomeDirectory())
        let builtIn = model.registry.type(id: lib.id) != nil
        // the menu is the row button's sibling: a control inside a button's label never
        // gets its click (see the hit-testing notes)
        return HStack(spacing: 8) {
            Button { draft.toggleLibrary(lib.id) } label: {
                HStack(spacing: 10) {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)).font(.title3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(lib.displayName).font(.callout.weight(.semibold))
                        if let former = lib.formerNames?.last, editing?.libraries.first(where: { $0.id == lib.id })?.displayName != lib.displayName {
                            Text("was “\(former)”").font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(path?.path ?? "").font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    if model.libraryValid[lib.id] == false {
                        Text("not found there").font(.caption2).foregroundStyle(.cryoWarn)
                    } else if let size = model.librarySizes[lib.id] {
                        Text(human(size)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    } else if model.measuringSizes.contains(lib.id) {
                        ProgressView().controlSize(.mini)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(lib.displayName)
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)

            Menu {
                Button("Rename…") { renamingLibrary = lib }
                if let path { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([path]) } }
                if builtIn { Button("Choose where it's kept…") { relocate(lib) } }
                Divider()
                Button("Remove", role: .destructive) { draft.removeLibrary(lib.id) }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("More for \(lib.displayName)")
        }
    }

    // MARK: Copies go to

    private var copiesSection: some View {
        Section {
            ForEach(draft.targets) { t in destinationRow(t) }
            if draft.targets.isEmpty {
                Text("Add the drive, network share or folder the backups should go to.").font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                Button { addDestination() } label: { Label("Add destination…", systemImage: "plus.circle") }
                let detected = CloudProvider.detectFolders(home: NSHomeDirectory())
                if !detected.isEmpty {
                    Menu("Cloud folders") {
                        ForEach(detected, id: \.url) { f in
                            Button("\(f.provider.displayName): \(f.url.lastPathComponent)") { addCloud(f.url) }
                        }
                    }
                    .fixedSize()
                }
            }
            .buttonStyle(.link)
            issueList(destinationIssues)
            ForEach(draft.pathIssues, id: \.self) { m in
                Label(m, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.cryoCrit)
            }
            if draft.hasDuplicateDestinations {
                Label("Two destinations are the same folder; it gets one copy.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.cryoWarn)
            }
            ForEach(draft.destinationConflicts, id: \.self) { c in
                Label(c, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.cryoCrit)
            }
        } header: { Text("Copies go to") }
        footer: {
            Text("Each chosen destination gets its own copy. A backup has to reach the main destination; one that can't reach another finishes with a warning. Drives that take turns count as one destination: each backup goes to whichever is connected.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func destinationRow(_ t: Target) -> some View {
        let on = draft.selectedTargetIDs.contains(t.id)
        let main = on && draft.primaryTarget?.id == t.id
        let turns = draft.takesTurns(t.id)
        let others = draft.selectedTargets.filter { $0.id != t.id }
        let where_ = presence[t.id]
        return HStack(spacing: 8) {
            Button { draft.toggleTarget(t.id) } label: {
                HStack(spacing: 10) {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)).font(.title3)
                    Image(systemName: icon(t)).foregroundStyle(.secondary).frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(t.displayName).font(.callout.weight(.semibold))
                            if main { badge("main") }
                            if !turns.isEmpty { badge("takes turns") }
                        }
                        Text(t.destinationDir.path).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                        Text(statusLine(t, where_)).font(.caption2).foregroundStyle(statusColor(where_))
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(t.displayName)\(main ? ", main destination" : "")")
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)

            Menu {
                if on && !main { Button("Make main") { draft.makeMain(t.id) } }
                if on && !others.isEmpty {
                    Menu("Takes turns with") {
                        ForEach(others) { o in Button(o.displayName) { draft.takeTurns(t.id, with: o.id) } }
                    }
                }
                if !turns.isEmpty { Button("Stop taking turns") { draft.stopTakingTurns(t.id) } }
                if editing != nil, case .otherDrive = where_ {
                    Divider()
                    Button("Is this one of your drives?…") { pairingTarget = t }
                }
                if let connected = pairedDriveConnected(t) {
                    Divider()
                    Button("Rename this drive…") { renamingDrive = DriveToRename(target: t, drive: connected) }
                        .disabled(draft.hasUnsavedEdits || busy)
                }
                ForEach(t.otherVolumes ?? [], id: \.uuid) { v in
                    Button("Stop taking turns with the other “\(v.name)”") { draft.unpair(t.id, uuid: v.uuid) }
                }
                if model.canRemoveTarget(t.id), editing?.targets.contains(where: { $0.id == t.id }) != true {
                    Divider()
                    Button("Remove from list", role: .destructive) { draft.removeTarget(t.id) }
                }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("More for \(t.displayName)")
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(.tint)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(Color.cryoAccent.opacity(0.15)))
    }

    private func statusLine(_ t: Target, _ p: DestinationPresence?) -> String {
        var parts: [String] = []
        switch p {
        case .present(let url)?:
            parts.append("connected")
            if let vi = model.volumeInfo(for: url) { parts.append("\(human(vi.free)) free") }
        case .away?: parts.append(t.rotation != nil ? "away" : "not connected")
        case .otherDrive?: parts.append("another drive of this name is connected")
        case nil: break
        }
        if let id = editing?.id, let last = model.lastCopies[id]?[t.id] {
            parts.append("last copy \(last.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }

    private func statusColor(_ p: DestinationPresence?) -> Color {
        if case .otherDrive? = p { return .cryoWarn }
        return .secondary
    }

    private func icon(_ t: Target) -> String {
        switch t.kind {
        case .cloudSync: return "cloud"
        case .networkShare: return "network"
        case .local: return t.constraints.resumableTransfer ? "externaldrive" : "internaldrive"
        }
    }

    /// a connected drive `t` takes turns with under its name, or the other drive of its
    /// name at its folder: the one Rename this drive would rename
    private func pairedDriveConnected(_ t: Target) -> VolumeIdentity? {
        guard editing?.targets.contains(where: { $0.id == t.id }) == true, let own = t.volume, !own.isShare else { return nil }
        let table = SystemVolumeTable()
        for v in t.otherVolumes ?? [] where table.mounted().contains(where: { $0.uuid == v.uuid }) { return v }
        if case .otherDrive? = presence[t.id], let here = table.volume(containing: t.destinationDir), here.uuid != nil,
           here.uuid != own.uuid, var id = DestinationResolver(volumes: table).identity(for: t.destinationDir) {
            id.learnedAt = nil
            return id
        }
        return nil
    }

    // MARK: When

    private var whenSection: some View {
        Section("When") {
            Picker("Back up", selection: $draft.freqKind) {
                Text("Every day").tag(JobDraft.FreqKind.daily)
                Text("Every few hours").tag(JobDraft.FreqKind.everyHours)
                Text("Once").tag(JobDraft.FreqKind.once)
                Text("Only when I say").tag(JobDraft.FreqKind.manual)
            }
            switch draft.freqKind {
            case .daily:      DatePicker("At", selection: $draft.dailyTime, displayedComponents: .hourAndMinute)
            case .everyHours: Stepper("Every \(draft.everyHours) hours", value: $draft.everyHours, in: 1...168)
            case .once:       DatePicker("At", selection: $draft.onceDate)
            case .manual:     Text("Use Run now to back it up.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Keep

    private var keepSection: some View {
        Section {
            Picker("Each backup keeps", selection: keepKind) {
                Text("One up-to-date copy").tag("copy")
                Text("Dated versions").tag("versions")
            }
            .pickerStyle(.radioGroup)
            if draft.isSealed {
                Picker("As", selection: $draft.formatKind) {
                    Text("Disk images").tag("dmg")
                    if !draft.encrypt { Text("Zip files").tag("zip") }
                }
                Picker("Keep", selection: $draft.retentionKind) {
                    Text("Every version").tag("all"); Text("The last few").tag("lastN"); Text("Daily, weekly and monthly").tag("gfs")
                }
                if draft.retentionKind == "lastN" {
                    Stepper("The last \(draft.keepN) version\(draft.keepN == 1 ? "" : "s")", value: $draft.keepN, in: 1...365)
                } else if draft.retentionKind == "gfs" {
                    Stepper("\(draft.gfsDaily) daily", value: $draft.gfsDaily, in: 0...60)
                    Stepper("\(draft.gfsWeekly) weekly", value: $draft.gfsWeekly, in: 0...52)
                    Stepper("\(draft.gfsMonthly) monthly", value: $draft.gfsMonthly, in: 0...60)
                }
            }
            if let base = editing, base.format.isSealed != draft.isSealed {
                Label(draft.isSealed ? "Nothing is deleted: the up-to-date copy already made stays, marked kept."
                                     : "Nothing is deleted: the dated versions already made stay, marked kept.",
                      systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
        } header: { Text("Keep") }
        footer: {
            Text(draft.isSealed
                 ? "Each backup is saved as a dated version you can go back to. Versions beyond what you keep are deleted after a backup; the one last proven to restore never is."
                 : "Each backup brings one copy up to date, fast, with no history to go back to.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var keepKind: Binding<String> {
        Binding(get: { draft.isSealed ? "versions" : "copy" },
                set: { draft.formatKind = $0 == "copy" ? "mirror" : (draft.formatKind == "zip" && !draft.encrypt ? "zip" : "dmg") })
    }

    // MARK: Details

    private var detailsSection: some View {
        Section("Details") {
            TextField("Name", text: $draft.name, prompt: Text(draft.defaultName))
            Toggle("Encrypt with a passphrase", isOn: $draft.encrypt)
                .onChange(of: draft.encrypt) { _, on in if on, draft.formatKind == "zip" { draft.formatKind = "dmg" } }
                .disabled(draft.encryptionLocked)
            if draft.encryptionLocked {
                Text(draft.encrypt
                     ? "The passphrase can't be changed for an existing job: the backups made with it would stop opening. For another passphrase, make a new job."
                     : "Encryption can't be turned on for an existing job: its earlier backups would stay unencrypted. To encrypt, make a new job.")
                    .font(.caption).foregroundStyle(.secondary)
                if draft.encrypt, let id = editing?.id {
                    if let saved = revealedPassphrase {
                        HStack {
                            Text(saved).font(.body.monospaced()).textSelection(.enabled)
                            Spacer()
                            Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(saved, forType: .string) }
                        }
                    } else {
                        Button("Show the saved passphrase…") { revealedPassphrase = KeychainArchiveKey.load(jobID: id) }
                    }
                }
            } else if draft.encrypt {
                SecureField("Passphrase", text: $draft.passphrase)
                SecureField("Type it again", text: $draft.passphraseConfirm)
                Text("The passphrase is kept only in this Mac's Keychain. Keep a copy in your password manager, and export your recovery file: without it, nobody can open these backups on another Mac.")
                    .font(.caption).foregroundStyle(.cryoWarn)
            }
            Picker("Check each backup", selection: $draft.verification) {
                Text("Quick check").tag(VerificationPolicy.checksumOnly)
                Text("Full check (opens it)").tag(VerificationPolicy.mountAndOpen)
            }
            Picker("If the app is open", selection: $draft.runPolicy) {
                Text("Back up anyway").tag(RunPolicy.proceed)
                Text("Back up, and say so").tag(RunPolicy.warnIfRunning)
                Text("Wait until it's closed").tag(RunPolicy.deferIfRunning)
            }
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack {
            if let job = editing {
                Button("Delete job…", role: .destructive) { deleting = job }
                    .disabled(busy)
                    .help(busy ? "It's in use: a backup, a check or an upload is running or waiting." : "")
            }
            Spacer()
            if !draft.encryptionValid {
                Text(passphraseHint).font(.caption).foregroundStyle(.cryoWarn)
            }
            Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
            Button(editing == nil ? "Create" : (computingSummary ? "Looking…" : "Save…")) { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!draft.isValid || computingSummary)
        }
        .padding(18)
    }

    private var passphraseHint: String {
        if draft.passphrase.isEmpty { return "Enter a passphrase: encryption is on." }
        if draft.passphraseConfirm.isEmpty { return "Type the passphrase again." }
        return "The two passphrases don't match."
    }

    private func save() {
        guard editing != nil else {
            if draft.commit() { isPresented = false }
            return
        }
        computingSummary = true
        let state = draft.state
        Task {
            let impact = await model.impact(of: state)
            computingSummary = false
            summary = impact
        }
    }

    // MARK: actions

    private func seed() {
        guard !seeded else { return }
        seeded = true
        if editing == nil {
            draft.freqKind = .daily
            draft.dailyTime = Calendar.current.date(bySettingHour: 2, minute: 0, second: 0, of: Date()) ?? Date()
            if let f = initialFolder {
                let ct = ContentType.customFolder(f, path: ContentView.libraryPath(for: f, home: NSHomeDirectory()))
                sourceIssues = draft.addSource(ct, at: f)
            } else if let id = initialLibraryID, draft.libraries.contains(where: { $0.id == id }) {
                draft.selectedLibraryIDs = [id]
            }
        }
        model.measureLibraries(draft.libraries)
        refreshPresence()
    }

    /// where each destination is, now and every few seconds (drives come and go)
    private func watchDrives() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(4))
            refreshPresence()
        }
    }

    private func refreshPresence() {
        let targets = draft.targets
        Task.detached {
            let r = DestinationResolver()
            let found = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, r.locate($0)) })
            await MainActor.run { if presence != found { presence = found } }
        }
    }

    private func addFolder() {
        guard let url = pickFolder("Choose a folder to back up") else { return }
        let ct = ContentType.customFolder(url, path: ContentView.libraryPath(for: url, home: NSHomeDirectory()))
        sourceIssues = draft.addSource(ct, at: url)
        model.measureLibraries(draft.libraries)
    }

    private func addTemplated(_ t: LibraryTemplate) {
        guard let url = pickFolder("Where is the \(t.displayName)?") else { return }
        let ct = t.contentType(id: url.path, displayName: url.lastPathComponent,
                               path: ContentView.libraryPath(for: url, home: NSHomeDirectory()))
        sourceIssues = draft.addSource(ct, at: url)
        model.measureLibraries(draft.libraries)
    }

    /// point a library the app knows at where it really is (saved for every job)
    private func relocate(_ lib: ContentType) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.message = "Where is \(lib.displayName) kept?"
        panel.directoryURL = lib.paths.first?.liveURL(home: NSHomeDirectory()).deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        LibraryOverrides.set(id: lib.id, path: url.path)
        draft.refreshBuiltInLibraries()
        draft.selectedLibraryIDs.insert(lib.id)
        model.measureLibraries(draft.libraries)
    }

    private func addDestination() {
        guard let url = pickFolder("Choose where the backups go") else { return }
        let resolver = DestinationResolver()
        if resolver.kind(of: url) == .cloud { addCloud(url); return }
        destinationIssues = draft.addDestination(resolver.target(for: url))
        refreshPresence()
    }

    private func addCloud(_ url: URL) {
        pendingCloudProvider = CloudProvider.identify(url)
        pendingCloudURL = url
    }

    private func confirmCloud(_ bytes: UInt64) {
        guard let url = pendingCloudURL else { return }
        destinationIssues = draft.addDestination(DestinationResolver().target(for: url, cloudCap: bytes))
        pendingCloudURL = nil
        refreshPresence()
    }

    private func pickFolder(_ message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }

    @ViewBuilder private func issueList(_ issues: [PlaceIssue]) -> some View {
        ForEach(issues, id: \.message) { i in
            Label(i.message, systemImage: i.severity == .refusal ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(i.severity == .refusal ? Color.cryoCrit : Color.cryoWarn)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func human(_ b: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file) }
}

/// a drive Rename this drive would rename, for `target`
struct DriveToRename: Identifiable {
    var id: String { drive.uuid }
    let target: Target
    let drive: VolumeIdentity
}
