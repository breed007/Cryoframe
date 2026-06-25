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
    @State private var libraries: [ContentType] = []
    @State private var selectedLibraryIDs: Set<String> = []
    @State private var targets: [Target] = []
    @State private var selectedTargetID = "local-default"
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

    enum FreqKind: String, CaseIterable, Identifiable { case daily, everyHours, once, manual; var id: String { rawValue } }

    private var selectedLibraries: [ContentType] { libraries.filter { selectedLibraryIDs.contains($0.id) } }
    private var target: Target? { targets.first { $0.id == selectedTargetID } }
    private var isEditing: Bool { editing != nil }

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
                                    Text(p.liveURL(home: NSHomeDirectory()).path)
                                        .font(.caption2).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
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
                        Button("Edit locations…") { model.openLibrarySettings() }
                    }
                } header: {
                    Text("Libraries")
                } footer: {
                    Text("Pick one or more. All selected libraries are frozen in one snapshot and archived together to the destination, each in its own folder.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Destination") {
                    Picker("Target", selection: $selectedTargetID) {
                        ForEach(targets) { Text($0.displayName).tag($0.id) }
                    }
                    if let t = target { pathCaption(t.destinationDir.path) }
                    Menu("Add destination…") {
                        Button("Local folder…") { addTarget(.local) }
                        Button("Network or external drive (resumable)…") { addTarget(.external) }
                        Button("Cloud-sync folder (splits over 250GB)…") { addTarget(.cloud) }
                    }
                }

                Section("Format") {
                    Picker("Format", selection: formatBinding) {
                        Text("Live mirror").tag("mirror")
                        Text("Sealed zip").tag("zip")
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
                    .disabled(selectedLibraries.isEmpty || target == nil)
            }
            .padding(20)
        }
        .frame(width: 560, height: 640)
        .onAppear(perform: seed)
    }

    // MARK: helpers

    private func selectionBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { selectedLibraryIDs.contains(id) },
                set: { if $0 { selectedLibraryIDs.insert(id) } else { selectedLibraryIDs.remove(id) } })
    }

    private func pathCaption(_ path: String) -> some View {
        Text(path).font(.caption).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading).help(path)
    }

    private var defaultName: String {
        let names = selectedLibraries.map(\.displayName)
        let lib = names.isEmpty ? "Libraries" : (names.count <= 2 ? names.joined(separator: ", ") : "\(names.count) libraries")
        return "\(lib) → \(target?.displayName ?? "Target")"
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
            if !targets.contains(where: { $0.id == job.target.id }) { targets.append(job.target) }
            selectedTargetID = job.target.id
            switch job.format {
            case .sealedDMG: format = .sealedDMG
            case .sealedZip: format = .sealedZip
            case .liveMirror(let g):
                format = .liveMirror(sizeGB: g)
                if g >= 1000, g % 1000 == 0 { liveMirrorValue = g / 1000; liveMirrorUnit = "TB" }
                else { liveMirrorValue = g; liveMirrorUnit = "GB" }
            }
            verification = job.verification; runPolicy = job.runPolicy
            seedFrequency(job.frequency)
        } else {
            selectedTargetID = targets.first?.id ?? ""
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
        guard !selectedLibraries.isEmpty, let tgt = target else { return }
        var fmt = format
        if case .liveMirror = fmt { fmt = .liveMirror(sizeGB: liveMirrorGB) }
        model.addJob(BackupJob(id: editing?.id ?? UUID().uuidString,
                               name: name.isEmpty ? defaultName : name,
                               libraries: selectedLibraries, target: tgt, format: fmt,
                               frequency: frequency(), verification: verification, runPolicy: runPolicy,
                               enabled: editing?.enabled ?? true, createdAt: editing?.createdAt ?? Date()))
        isPresented = false
    }

    private func addFolderContentType() {
        guard let url = pickFolder() else { return }
        let ct = ContentType.genericFolder(id: url.path, displayName: url.lastPathComponent,
                                           path: ContentView.libraryPath(for: url, home: NSHomeDirectory()))
        libraries.removeAll { $0.id == ct.id }; libraries.append(ct); selectedLibraryIDs.insert(ct.id)
    }

    private func addTemplatedLibrary(_ template: LibraryTemplate) {
        guard let url = pickFolder() else { return }
        let ct = template.contentType(id: url.path, displayName: url.lastPathComponent,
                                      path: ContentView.libraryPath(for: url, home: NSHomeDirectory()))
        libraries.removeAll { $0.id == ct.id }; libraries.append(ct); selectedLibraryIDs.insert(ct.id)
    }

    private enum DestKind { case local, external, cloud }

    private func addTarget(_ kind: DestKind) {
        guard let url = pickFolder() else { return }
        let name = url.lastPathComponent
        let t: Target
        switch kind {
        case .local:    t = .localVolume(id: url.path, name: name, dir: url)
        case .external: t = .externalDrive(id: url.path, name: name + " (resumable)", dir: url)
        case .cloud:    t = .cloudSyncFolder(id: url.path, name: name + " (cloud)", dir: url)
        }
        targets.removeAll { $0.id == t.id }; targets.append(t); model.addTarget(t); selectedTargetID = t.id
    }

    private func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
