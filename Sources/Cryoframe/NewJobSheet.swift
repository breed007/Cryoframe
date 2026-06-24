//
//  NewJobSheet.swift
//  Cryoframe (app)
//
//  Job creation, grouped into clear sections: Library, Destination, Format,
//  Schedule, Verification. Long paths truncate with a full-path tooltip.
//

import SwiftUI
import AppKit
import CryoframeKit

struct NewJobSheet: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool

    @State private var name = ""
    @State private var contentTypes: [ContentType] = []
    @State private var selectedContentID = ContentType.photos.id
    @State private var targets: [Target] = []
    @State private var selectedTargetID = "local-default"
    @State private var format: FormatChoice = .sealedDMG
    @State private var liveMirrorGB = 500

    @State private var freqKind = FreqKind.daily
    @State private var dailyTime = Calendar.current.date(bySettingHour: 2, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var everyHours = 24
    @State private var onceDate = Date().addingTimeInterval(3600)

    @State private var verification: VerificationPolicy = .checksumOnly
    @State private var runPolicy: RunPolicy = .proceed

    enum FreqKind: String, CaseIterable, Identifiable { case daily, everyHours, once, manual; var id: String { rawValue } }

    private var contentType: ContentType? { contentTypes.first { $0.id == selectedContentID } }
    private var target: Target? { targets.first { $0.id == selectedTargetID } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New backup job").font(.title2.bold())
                Spacer()
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 8)

            Form {
                Section("Library") {
                    Picker("Library", selection: $selectedContentID) {
                        ForEach(contentTypes) { Text($0.displayName).tag($0.id) }
                    }
                    .help("The live library to back up. Photos and Apple Music are built in.")
                    if let ct = contentType, let p = ct.paths.first {
                        pathCaption(p.liveURL(home: NSHomeDirectory()).path)
                    }
                    Menu("Add library…") {
                        ForEach(LibraryTemplate.all) { t in
                            Button(t.displayName + "…") { addTemplatedLibrary(t) }
                        }
                        Divider()
                        Button("Plain folder…") { addFolderContentType() }
                    }
                }

                Section("Destination") {
                    Picker("Target", selection: $selectedTargetID) {
                        ForEach(targets) { Text($0.displayName).tag($0.id) }
                    }
                    .help("Where archives are written.")
                    if let t = target { pathCaption(t.destinationDir.path) }
                    Menu("Add destination…") {
                        Button("Local folder…") { addTarget(cloud: false) }
                        Button("Cloud-sync folder (splits over 250GB)…") { addTarget(cloud: true) }
                    }
                }

                Section("Format") {
                    Picker("Format", selection: formatBinding) {
                        Text("Sealed DMG").tag("dmg")
                        Text("Sealed zip").tag("zip")
                        Text("Live mirror").tag("mirror")
                    }
                    .help("Sealed is one immutable, checksummed file for cold storage. Live mirror is an incremental sparsebundle for a working backup.")
                    if case .liveMirror = format {
                        Stepper("Mirror size: \(liveMirrorGB) GB", value: $liveMirrorGB, in: 50...8000, step: 50)
                    }
                }

                Section("Schedule") {
                    Picker("Run", selection: $freqKind) {
                        Text("Daily").tag(FreqKind.daily)
                        Text("Every N hours").tag(FreqKind.everyHours)
                        Text("Once").tag(FreqKind.once)
                        Text("Manual only").tag(FreqKind.manual)
                    }
                    .help("How often this job runs in the background. Manual runs only when you press Run now.")
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
                    .help("Checksum hashes every archive (always on). Mount & open also mounts the archive and confirms the library's database opens clean.")
                    Picker("If app is open", selection: $runPolicy) {
                        Text("Proceed").tag(RunPolicy.proceed)
                        Text("Warn").tag(RunPolicy.warnIfRunning)
                        Text("Defer").tag(RunPolicy.deferIfRunning)
                    }
                    .help("The snapshot is consistent whether or not the app is open. Defer only if you'd rather skip a run while it's in use.")
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Create") { create() }.keyboardShortcut(.defaultAction)
                    .disabled(contentType == nil || target == nil)
            }
            .padding(20)
        }
        .frame(width: 540, height: 620)
        .onAppear(perform: seedDefaults)
    }

    // MARK: helpers

    private func pathCaption(_ path: String) -> some View {
        Text(path)
            .font(.caption).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(path)
    }

    private var defaultName: String {
        "\(contentType?.displayName ?? "Library") → \(target?.displayName ?? "Target")"
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

    private func seedDefaults() {
        contentTypes = model.registry.types
        targets = model.targets
        selectedTargetID = targets.first?.id ?? ""
        let d = UserDefaults.standard
        switch d.string(forKey: Prefs.format) {
        case "zip": format = .sealedZip
        case "mirror": format = .liveMirror(sizeGB: liveMirrorGB)
        default: format = .sealedDMG
        }
        if let v = d.string(forKey: Prefs.verify), let p = VerificationPolicy(rawValue: v) { verification = p }
        if let r = d.string(forKey: Prefs.runPolicy), let p = RunPolicy(rawValue: r) { runPolicy = p }
        if d.integer(forKey: Prefs.mirrorGB) > 0 { liveMirrorGB = d.integer(forKey: Prefs.mirrorGB) }
    }

    private func create() {
        guard let ct = contentType, let tgt = target else { return }
        var fmt = format
        if case .liveMirror = fmt { fmt = .liveMirror(sizeGB: liveMirrorGB) }
        model.addJob(BackupJob(name: name.isEmpty ? defaultName : name,
                               contentType: ct, target: tgt, format: fmt,
                               frequency: frequency(), verification: verification,
                               runPolicy: runPolicy, createdAt: Date()))
        isPresented = false
    }

    private func addFolderContentType() {
        guard let url = pickFolder() else { return }
        let ct = ContentType.genericFolder(id: url.path, displayName: url.lastPathComponent,
                                           path: ContentView.libraryPath(for: url, home: NSHomeDirectory()))
        contentTypes.removeAll { $0.id == ct.id }; contentTypes.append(ct); selectedContentID = ct.id
    }

    private func addTemplatedLibrary(_ template: LibraryTemplate) {
        guard let url = pickFolder() else { return }
        let ct = template.contentType(id: url.path, displayName: url.lastPathComponent,
                                      path: ContentView.libraryPath(for: url, home: NSHomeDirectory()))
        contentTypes.removeAll { $0.id == ct.id }; contentTypes.append(ct); selectedContentID = ct.id
    }

    private func addTarget(cloud: Bool) {
        guard let url = pickFolder() else { return }
        let t = cloud
            ? Target.cloudSyncFolder(id: url.path, name: url.lastPathComponent + " (cloud)", dir: url)
            : Target.localVolume(id: url.path, name: url.lastPathComponent, dir: url)
        targets.removeAll { $0.id == t.id }; targets.append(t); model.addTarget(t); selectedTargetID = t.id
    }

    private func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
