//
//  NewJobSheet.swift
//  Cryoframe (app)
//
//  Create or edit a job. Libraries are a multi-select checklist (built-ins and
//  added folders/templates in one list); all selected libraries are archived
//  from a single snapshot to one destination.
//

import SwiftUI
import AppKit
import CryoframeKit

struct NewJobSheet: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    var editing: BackupJob? = nil

    @State private var name = ""
    @State private var showLocations = false
    @State private var pendingCloudURL: URL?               // a cloud folder awaiting its plan/size confirmation
    @State private var pendingCloudProvider: CloudProvider = .generic
    @State private var libraries: [ContentType] = []
    @State private var selectedLibraryIDs: Set<String> = []
    @State private var targets: [Target] = []
    @State private var selectedTargetIDs: [String] = []     // ordered; first is primary
    @State private var format: FormatChoice = .liveMirror(sizeGB: 500)
    @State private var liveMirrorValue = 500
    @State private var liveMirrorUnit = "GB"
    private var liveMirrorGB: Int { liveMirrorUnit == "TB" ? liveMirrorValue * 1000 : liveMirrorValue }

    @State private var freqKind = FreqKind.daily
    @State private var dailyTime = Calendar.current.date(bySettingHour: 2, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var everyHours = 24
    @State private var onceDate = Date().addingTimeInterval(3600)

    @State private var verification: VerificationPolicy = .checksumOnly
    @State private var runPolicy: RunPolicy = .proceed
    @State private var encrypt = false
    @State private var passphrase = ""
    @State private var passphraseConfirm = ""
    @State private var revealedPassphrase: String?
    @State private var retentionKind = "all"        // all | lastN | gfs
    @State private var keepN = 7
    @State private var gfsDaily = 7
    @State private var gfsWeekly = 4
    @State private var gfsMonthly = 6

    enum FreqKind: String, CaseIterable, Identifiable { case daily, everyHours, once, manual; var id: String { rawValue } }

    private var selectedLibraries: [ContentType] { libraries.filter { selectedLibraryIDs.contains($0.id) } }
    private var selectedTargets: [Target] { selectedTargetIDs.compactMap { id in targets.first { $0.id == id } } }
    private var primaryTarget: Target? { selectedTargets.first }
    private var isEditing: Bool { editing != nil }

    /// selected destinations with duplicates-by-path collapsed. The built-in default and a
    /// manually-added copy of the same folder have different ids but the same path — writing
    /// to both would clobber one copy and report a phantom second. Keep the first (primary).
    private var dedupedTargets: [Target] {
        var seen = Set<String>(), out: [Target] = []
        for t in selectedTargets where seen.insert(t.destinationDir.path).inserted { out.append(t) }
        return out
    }
    private var hasDuplicateDestinations: Bool { dedupedTargets.count != selectedTargets.count }

    /// another sealed job already archiving the same library to the same destination —
    /// they'd share version folders and cross-prune each other's archives. Block it.
    private var destinationConflicts: [String] {
        guard isSealedFormat else { return [] }
        let mine = editing?.id
        var out = Set<String>()
        for job in model.jobs where job.id != mine && job.format.isSealed {
            for t in selectedTargets where job.targets.contains(where: { $0.destinationDir.path == t.destinationDir.path }) {
                for lib in selectedLibraries where job.libraries.contains(where: { $0.displayName == lib.displayName }) {
                    out.insert("“\(job.name)” already archives \(lib.displayName) to \(t.displayName)")
                }
            }
        }
        return out.sorted()
    }

    private var isSealedFormat: Bool { if case .liveMirror = format { return false }; return true }
    private var retentionPolicy: RetentionPolicy {
        switch retentionKind {
        case "lastN": return .keepLast(max(1, keepN))
        case "gfs":   return .gfs(daily: gfsDaily, weekly: gfsWeekly, monthly: gfsMonthly)
        default:      return .keepAll
        }
    }

    /// when encrypting, a new passphrase must be entered and confirmed — unless
    /// editing a job that's already encrypted and leaving the fields blank to keep it.
    private var encryptionValid: Bool {
        guard encrypt else { return true }
        // only allow "keep the current passphrase" when one is actually stored —
        // otherwise (e.g. a lost Keychain item) require entering a new one.
        if passphrase.isEmpty, passphraseConfirm.isEmpty,
           let id = editing?.id, editing?.encrypted == true, KeychainArchiveKey.exists(jobID: id) { return true }
        return !passphrase.isEmpty && passphrase == passphraseConfirm
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isEditing ? "Edit backup job" : "New backup job").font(.title2.bold())
                Spacer()
            }
            .padding([.horizontal, .top], 20).padding(.bottom, 8)

            Form {
                Section {
                    ForEach(libraries) { lib in
                        Toggle(isOn: selectionBinding(lib.id)) {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(lib.displayName)
                                    if let valid = model.libraryValid[lib.id] {
                                        Image(systemName: valid ? "checkmark.circle.fill" : "xmark.circle.fill")
                                            .font(.caption2).foregroundStyle(valid ? .green : .red)
                                    }
                                }
                                if let p = lib.paths.first {
                                    FinderPathLink(path: p.liveURL(home: NSHomeDirectory()).path)
                                }
                            }
                        }
                    }
                    HStack {
                        Menu("Add library…") {
                            ForEach(LibraryTemplate.all) { t in
                                Button(t.displayName + "…") { addTemplatedLibrary(t) }
                            }
                            Divider()
                            Button("Plain folder…") { addFolderContentType() }
                        }
                        Spacer()
                        Button("Edit locations…") { showLocations = true }
                    }
                } header: {
                    Text("Libraries")
                } footer: {
                    Text("Pick one or more. All selected libraries are frozen in one snapshot and archived together to the destination, each in its own folder.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    ForEach(targets) { t in
                        Toggle(isOn: destinationBinding(t.id)) {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(t.displayName)
                                    if primaryTarget?.id == t.id {
                                        Text("primary").font(.caption2)
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                FinderPathLink(path: t.destinationDir.path)
                            }
                        }
                        .contextMenu {
                            if model.canRemoveTarget(t.id) {
                                Button("Remove from list", role: .destructive) {
                                    selectedTargetIDs.removeAll { $0 == t.id }
                                    model.removeTarget(t.id)
                                    targets = model.targets
                                }
                            }
                        }
                    }
                    Menu("Add destination…") {
                        Button("Local folder…") { addTarget(.local) }
                        Button("Network or external drive (resumable)…") { addTarget(.external) }
                        Button("Cloud-sync folder…") { addTarget(.cloud) }
                        let detected = detectedCloudFolders
                        if !detected.isEmpty {
                            Divider()
                            ForEach(detected, id: \.url) { folder in
                                Button("\(folder.provider.displayName) — \(folder.url.lastPathComponent)") {
                                    addTargetAt(folder.url, kind: .cloud)
                                }
                            }
                        }
                    }
                    if hasDuplicateDestinations {
                        Label("Two destinations point at the same folder — only one copy will be kept.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).font(.caption)
                    }
                    if let cloud = selectedTargets.first(where: { $0.cloudProvider != nil })?.cloudProvider {
                        Label("\(cloud.displayName) uploads through its app and may offload files to save space. A scheduled health check skips offloaded copies rather than re-downloading them (changeable in Settings ▸ Archive health).",
                              systemImage: "cloud")
                            .foregroundStyle(.secondary).font(.caption)
                    }
                    if !destinationConflicts.isEmpty {
                        ForEach(destinationConflicts, id: \.self) { c in
                            Label(c, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange).font(.caption)
                        }
                    }
                } header: {
                    Text("Destinations")
                } footer: {
                    Text("Each selected destination gets its own copy from the same snapshot. The first is the primary — a run must reach it; if a secondary is offline the run finishes as a partial backup. A second copy on another drive or off-site is the 3-2-1 rule. Right-click a destination to remove it from the list.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Format") {
                    Picker("Format", selection: formatBinding) {
                        Text("Live mirror").tag("mirror")
                        if !encrypt { Text("Sealed zip").tag("zip") }   // zip can't be strongly encrypted
                        Text("Sealed DMG").tag("dmg")
                    }
                    if case .liveMirror = format {
                        HStack {
                            Text("Mirror size")
                            Spacer()
                            TextField("", value: $liveMirrorValue, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 64)
                                .onChange(of: liveMirrorValue) { _, v in if v < 1 { liveMirrorValue = 1 } }
                            Picker("", selection: $liveMirrorUnit) {
                                Text("GB").tag("GB")
                                Text("TB").tag("TB")
                            }
                            .labelsHidden()
                            .frame(width: 72)
                        }
                    }
                }

                Section {
                    Toggle("Encrypt with AES-256", isOn: $encrypt)
                        .onChange(of: encrypt) { _, on in
                            if on, case .sealedZip = format { format = .sealedDMG }   // zip can't be encrypted
                        }
                    if encrypt {
                        SecureField("Passphrase", text: $passphrase)
                        SecureField("Confirm passphrase", text: $passphraseConfirm)
                        if isEditing, editing?.encrypted == true {
                            if let saved = revealedPassphrase {
                                HStack {
                                    Text(saved).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                    Spacer()
                                    Button("Copy") { copyToClipboard(saved) }
                                }
                                Text("Leave the fields above blank to keep this passphrase.").font(.caption2).foregroundStyle(.secondary)
                            } else {
                                Button("Reveal saved passphrase…") { revealedPassphrase = KeychainArchiveKey.load(jobID: editing?.id ?? "") }
                            }
                        }
                    }
                } header: {
                    Text("Encryption")
                } footer: {
                    if encrypt {
                        Text("The archive is encrypted with AES-256; the passphrase is kept only in this Mac's Keychain. Copy it into your password manager now — if you lose it (or lose this Mac), the backup can't be decrypted. There is no reset. Sealed zip isn't available when encrypting.")
                            .font(.caption).foregroundStyle(.orange)
                    } else {
                        Text("Encrypt sealed-DMG and live-mirror archives so a copy on a drive, NAS, or cloud folder is unreadable without your passphrase.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if isSealedFormat {
                    Section {
                        Picker("Keep", selection: $retentionKind) {
                            Text("All versions").tag("all")
                            Text("Last N versions").tag("lastN")
                            Text("Daily / weekly / monthly").tag("gfs")
                        }
                        if retentionKind == "lastN" {
                            Stepper("Keep \(keepN) version\(keepN == 1 ? "" : "s")", value: $keepN, in: 1...365)
                        } else if retentionKind == "gfs" {
                            Stepper("Keep \(gfsDaily) daily", value: $gfsDaily, in: 0...60)
                            Stepper("Keep \(gfsWeekly) weekly", value: $gfsWeekly, in: 0...52)
                            Stepper("Keep \(gfsMonthly) monthly", value: $gfsMonthly, in: 0...60)
                        }
                    } header: {
                        Text("Versions to keep")
                    } footer: {
                        Text("Each run of a sealed job is saved as a dated version, so you can restore a point in time. Versions beyond this policy are pruned after a run. (Live mirror keeps a single up-to-date copy instead.)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Schedule") {
                    Picker("Run", selection: $freqKind) {
                        Text("Daily").tag(FreqKind.daily)
                        Text("Every N hours").tag(FreqKind.everyHours)
                        Text("Once").tag(FreqKind.once)
                        Text("Manual only").tag(FreqKind.manual)
                    }
                    switch freqKind {
                    case .daily:      DatePicker("At", selection: $dailyTime, displayedComponents: .hourAndMinute)
                    case .everyHours: Stepper("Every \(everyHours) hours", value: $everyHours, in: 1...168)
                    case .once:       DatePicker("At", selection: $onceDate)
                    case .manual:     EmptyView()
                    }
                }

                Section("Verification") {
                    Picker("Verify", selection: $verification) {
                        Text("Checksum").tag(VerificationPolicy.checksumOnly)
                        Text("Mount & open").tag(VerificationPolicy.mountAndOpen)
                    }
                    Picker("If app is open", selection: $runPolicy) {
                        Text("Proceed").tag(RunPolicy.proceed)
                        Text("Warn").tag(RunPolicy.warnIfRunning)
                        Text("Defer").tag(RunPolicy.deferIfRunning)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Create") { create() }.keyboardShortcut(.defaultAction)
                    .disabled(selectedLibraries.isEmpty || selectedTargets.isEmpty || !encryptionValid || !destinationConflicts.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 560, height: 640)
        .onAppear(perform: seed)
        .sheet(isPresented: Binding(get: { pendingCloudURL != nil }, set: { if !$0 { pendingCloudURL = nil } })) {
            if let url = pendingCloudURL {
                CloudDestinationSheet(url: url, provider: pendingCloudProvider,
                                      isPresented: Binding(get: { pendingCloudURL != nil }, set: { if !$0 { pendingCloudURL = nil } }),
                                      onConfirm: { confirmCloudTarget($0) })
            }
        }
        .sheet(isPresented: $showLocations) {
            LibraryLocationsSheet(isPresented: $showLocations) {
                // a built-in path changed: refresh the built-in rows but keep any
                // plain-folder / template libraries added this session (they aren't in
                // the registry, so a plain reassign would silently drop them).
                let builtins = model.registry.types
                let builtinIDs = Set(builtins.map(\.id))
                let extras = libraries.filter { !builtinIDs.contains($0.id) }
                libraries = builtins + extras
                model.revalidate()
            }
        }
    }

    // MARK: helpers

    private func selectionBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { selectedLibraryIDs.contains(id) },
                set: { if $0 { selectedLibraryIDs.insert(id) } else { selectedLibraryIDs.remove(id) } })
    }

    /// multi-select for destinations, preserving order so the first stays primary.
    private func destinationBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { selectedTargetIDs.contains(id) },
                set: { on in
                    if on { if !selectedTargetIDs.contains(id) { selectedTargetIDs.append(id) } }
                    else { selectedTargetIDs.removeAll { $0 == id } }
                })
    }

    private func copyToClipboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func pathCaption(_ path: String) -> some View {
        FinderPathLink(path: path, font: .caption)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var defaultName: String {
        let names = selectedLibraries.map(\.displayName)
        let lib = names.isEmpty ? "Libraries" : (names.count <= 2 ? names.joined(separator: ", ") : "\(names.count) libraries")
        let dest = primaryTarget?.displayName ?? "Target"
        let suffix = dedupedTargets.count > 1 ? " +\(dedupedTargets.count - 1)" : ""
        return "\(lib) → \(dest)\(suffix)"
    }

    private var formatBinding: Binding<String> {
        Binding(
            get: { switch format { case .sealedDMG: "dmg"; case .sealedZip: "zip"; case .liveMirror: "mirror" } },
            set: {
                switch $0 {
                case "dmg": format = .sealedDMG
                case "zip": format = .sealedZip
                default: format = .liveMirror(sizeGB: liveMirrorGB)
                }
            })
    }

    private func frequency() -> BackupFrequency {
        switch freqKind {
        case .daily:
            let c = Calendar.current.dateComponents([.hour, .minute], from: dailyTime)
            return .daily(hour: c.hour ?? 2, minute: c.minute ?? 0)
        case .everyHours: return .everyHours(everyHours)
        case .once:       return .oneTime(onceDate)
        case .manual:     return .manual
        }
    }

    private func seed() {
        libraries = model.registry.types
        targets = model.targets
        if let job = editing {
            name = job.name
            for lib in job.libraries where !libraries.contains(where: { $0.id == lib.id }) { libraries.append(lib) }
            selectedLibraryIDs = Set(job.libraries.map(\.id))
            for t in job.targets where !targets.contains(where: { $0.id == t.id }) { targets.append(t) }
            selectedTargetIDs = job.targets.map(\.id)
            switch job.format {
            case .sealedDMG: format = .sealedDMG
            case .sealedZip: format = .sealedZip
            case .liveMirror(let g):
                format = .liveMirror(sizeGB: g)
                if g >= 1000, g % 1000 == 0 { liveMirrorValue = g / 1000; liveMirrorUnit = "TB" }
                else { liveMirrorValue = g; liveMirrorUnit = "GB" }
            }
            verification = job.verification; runPolicy = job.runPolicy
            encrypt = job.encrypted
            switch job.retention {
            case .keepAll: retentionKind = "all"
            case .keepLast(let n): retentionKind = "lastN"; keepN = n
            case .gfs(let d, let w, let m): retentionKind = "gfs"; gfsDaily = d; gfsWeekly = w; gfsMonthly = m
            }
            seedFrequency(job.frequency)
        } else {
            selectedTargetIDs = targets.first.map { [$0.id] } ?? []
            let d = UserDefaults.standard
            if d.integer(forKey: Prefs.mirrorGB) > 0 { liveMirrorValue = d.integer(forKey: Prefs.mirrorGB) }
            if let u = d.string(forKey: Prefs.mirrorUnit) { liveMirrorUnit = u }
            switch d.string(forKey: Prefs.format) {
            case "dmg": format = .sealedDMG
            case "zip": format = .sealedZip
            default:    format = .liveMirror(sizeGB: liveMirrorGB)   // mirror is the default
            }
            if let v = d.string(forKey: Prefs.verify), let p = VerificationPolicy(rawValue: v) { verification = p }
            if let r = d.string(forKey: Prefs.runPolicy), let p = RunPolicy(rawValue: r) { runPolicy = p }
        }
    }

    private func seedFrequency(_ f: BackupFrequency) {
        switch f {
        case .daily(let h, let m):
            freqKind = .daily
            dailyTime = Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date()
        case .everyHours(let h): freqKind = .everyHours; everyHours = h
        case .oneTime(let date): freqKind = .once; onceDate = date
        case .manual: freqKind = .manual
        }
    }

    private func create() {
        guard !selectedLibraries.isEmpty, !selectedTargets.isEmpty, encryptionValid else { return }
        var fmt = format
        if case .liveMirror = fmt { fmt = .liveMirror(sizeGB: liveMirrorGB) }
        let id = editing?.id ?? UUID().uuidString
        if encrypt {
            if !passphrase.isEmpty { KeychainArchiveKey.save(passphrase, jobID: id) }   // else: keep existing
        } else if editing?.encrypted == true {
            KeychainArchiveKey.delete(jobID: id)                                        // encryption turned off
        }
        model.addJob(BackupJob(id: id,
                               name: name.isEmpty ? defaultName : name,
                               libraries: selectedLibraries, targets: dedupedTargets, format: fmt,
                               frequency: frequency(), verification: verification, runPolicy: runPolicy,
                               enabled: editing?.enabled ?? true, encrypted: encrypt,
                               retention: isSealedFormat ? retentionPolicy : .keepAll,
                               createdAt: editing?.createdAt ?? Date()))
        isPresented = false
    }

    private func addFolderContentType() {
        guard let url = pickFolder() else { return }
        let ct = ContentType.genericFolder(id: url.path, displayName: url.lastPathComponent,
                                           path: ContentView.libraryPath(for: url, home: NSHomeDirectory()))
        addLibrary(ct, at: url)
    }

    private func addTemplatedLibrary(_ template: LibraryTemplate) {
        guard let url = pickFolder() else { return }
        let ct = template.contentType(id: url.path, displayName: url.lastPathComponent,
                                      path: ContentView.libraryPath(for: url, home: NSHomeDirectory()))
        addLibrary(ct, at: url)
    }

    private func addLibrary(_ ct: ContentType, at url: URL) {
        libraries.removeAll { $0.id == ct.id }
        libraries.append(ct)
        selectedLibraryIDs.insert(ct.id)
        model.libraryValid[ct.id] = FileManager.default.fileExists(atPath: url.path)   // user just picked it: show the check
    }

    private enum DestKind { case local, external, cloud }

    private func addTarget(_ kind: DestKind) {
        guard let url = pickFolder() else { return }
        addTargetAt(url, kind: kind)
    }

    private func addTargetAt(_ url: URL, kind: DestKind) {
        switch kind {
        case .local:    finishAddTarget(.localVolume(id: url.path, name: url.lastPathComponent, dir: url))
        case .external: finishAddTarget(.externalDrive(id: url.path, name: url.lastPathComponent + " (resumable)", dir: url))
        case .cloud:
            // identify the provider, then let the user confirm the single-file limit (plan)
            // before creating the target.
            pendingCloudProvider = CloudProvider.identify(url)
            pendingCloudURL = url
        }
    }

    private func finishAddTarget(_ t: Target) {
        targets.removeAll { $0.id == t.id }; targets.append(t); model.addTarget(t)
        if !selectedTargetIDs.contains(t.id) { selectedTargetIDs.append(t.id) }   // auto-select the new destination
    }

    private func confirmCloudTarget(_ maxFileBytes: UInt64) {
        guard let url = pendingCloudURL else { return }
        finishAddTarget(.cloudSyncFolder(id: url.path, name: "\(url.lastPathComponent) (\(pendingCloudProvider.displayName))",
                                         dir: url, provider: pendingCloudProvider, maxFileBytes: maxFileBytes))
        pendingCloudURL = nil
    }

    /// cloud-sync folders detected on this Mac, for one-click adding.
    private var detectedCloudFolders: [(url: URL, provider: CloudProvider)] {
        CloudProvider.detectFolders(home: NSHomeDirectory())
    }

    private func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
