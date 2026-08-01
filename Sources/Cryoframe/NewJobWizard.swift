//
//  NewJobWizard.swift
//  Cryoframe (app)
//
//  The guided way to make a backup job: templates for the fast path, then one decision
//  per step (what → where → how often → review), with the expert knobs collapsed into an
//  editable Advanced section on the review. All state and logic live in JobDraft — this
//  view is only the guided presentation of it. Editing an existing job uses NewJobSheet.
//

import SwiftUI
import AppKit
import CryoframeKit

struct JobTemplate: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let systemImage: String
    let libraryNames: [String]       // matched against the registry by display name; empty = custom
    let formatKind: String
    let verify: VerificationPolicy
    let retention: RetentionPolicy
    let nightly: Bool

    static let all: [JobTemplate] = [
        .init(title: "Photos, nightly", subtitle: "Sealed DMG · keeps the last 14 nights",
              systemImage: "photo.on.rectangle.angled", libraryNames: ["Photos"],
              formatKind: "dmg", verify: .mountAndOpen, retention: .keepLast(14), nightly: true),
        .init(title: "Music mirror", subtitle: "Live mirror · updates in place, fast",
              systemImage: "music.note.list", libraryNames: ["Apple Music"],
              formatKind: "mirror", verify: .checksumOnly, retention: .keepAll, nightly: true),
        .init(title: "Photos + Music", subtitle: "Both, sealed, nightly · keeps last 7",
              systemImage: "square.stack.3d.up", libraryNames: ["Photos", "Apple Music"],
              formatKind: "dmg", verify: .checksumOnly, retention: .keepLast(7), nightly: true),
        .init(title: "Start from scratch", subtitle: "Choose everything yourself",
              systemImage: "plus", libraryNames: [], formatKind: "mirror", verify: .checksumOnly, retention: .keepAll, nightly: true),
    ]
}

struct NewJobWizard: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    var initialFolder: URL? = nil
    var initialLibraryID: String? = nil    // preselect a built-in (from the coverage advisor)

    @StateObject private var draft: JobDraft
    @State private var step = 0
    @State private var freqPreset = FreqPreset.nightly
    @State private var pendingCloudURL: URL?
    @State private var pendingCloudProvider: CloudProvider = .generic
    @State private var seeded = false

    private let stepTitles = ["What to back up", "Where", "How often", "Review"]

    init(model: AppModel, isPresented: Binding<Bool>, initialFolder: URL? = nil, initialLibraryID: String? = nil) {
        self.model = model
        self._isPresented = isPresented
        self.initialFolder = initialFolder
        self.initialLibraryID = initialLibraryID
        self._draft = StateObject(wrappedValue: JobDraft(model: model))
    }

    enum FreqPreset: String, CaseIterable { case nightly, sixHours, twelveHours, manual
        var title: String { switch self { case .nightly: "Every night"; case .sixHours: "Every 6 hours"; case .twelveHours: "Twice a day"; case .manual: "Manual only" } }
        var detail: String { switch self { case .nightly: "Runs at 2:00 AM · recommended"; case .sixHours: "For libraries that change a lot"; case .twelveHours: "Morning and night"; case .manual: "Run it yourself with Run now" } }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            stepBar
            Divider()
            ScrollView { stepBody.padding(22).frame(maxWidth: .infinity, alignment: .leading) }
            Divider()
            footer
        }
        .frame(width: 640, height: 640)
        .onAppear { seedInitialFolder() }
        .sheet(isPresented: Binding(get: { pendingCloudURL != nil }, set: { if !$0 { pendingCloudURL = nil } })) {
            if let url = pendingCloudURL {
                CloudDestinationSheet(url: url, provider: pendingCloudProvider,
                                      isPresented: Binding(get: { pendingCloudURL != nil }, set: { if !$0 { pendingCloudURL = nil } }),
                                      onConfirm: { confirmCloud($0) })
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("New backup job").font(.title2.bold())
                Text(subhead).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button { isPresented = false } label: { Image(systemName: "xmark") }.buttonStyle(.bordered).help("Cancel")
                .accessibilityLabel("Cancel setup")
        }
        .padding([.horizontal, .top], 22).padding(.bottom, 14)
    }
    private var subhead: String {
        ["Start from a template, or build it your way.", "Add as many copies as you like — the first is your primary.",
         "Pick a rhythm; you can change it later.", "Looks good? These defaults are chosen for a trustworthy backup."][step]
    }

    private var stepBar: some View {
        HStack(spacing: 8) {
            ForEach(Array(stepTitles.enumerated()), id: \.offset) { i, title in
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 3).fill(i <= step ? Color.cryoAccent : Color.cryoLine).frame(height: 4)
                    Text("\(i + 1). \(title)").font(.caption2.weight(.semibold)).foregroundStyle(i == step ? .primary : .secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
    }

    @ViewBuilder private var stepBody: some View {
        switch step { case 0: stepLibraries; case 1: stepDestinations; case 2: stepFrequency; default: stepReview }
    }

    // MARK: step 1
    private var stepLibraries: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("QUICK START").font(.caption2.weight(.bold)).tracking(0.5).foregroundStyle(.tertiary)
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 10) {
                ForEach(JobTemplate.all) { t in templateCard(t) }
            }
            HStack { Rectangle().fill(Color.cryoLine).frame(height: 1); Text("or pick libraries").font(.caption).foregroundStyle(.tertiary).fixedSize(); Rectangle().fill(Color.cryoLine).frame(height: 1) }
            VStack(spacing: 2) { ForEach(draft.libraries) { lib in libraryRow(lib) } }
        }
    }
    private func templateCard(_ t: JobTemplate) -> some View {
        let active = matchesTemplate(t)
        return Button { applyTemplate(t) } label: {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: t.systemImage).font(.system(size: 17, weight: .medium)).foregroundStyle(.tint)
                    .frame(width: 34, height: 34).background(RoundedRectangle(cornerRadius: 9).fill(.background)).overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.cryoLine))
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).font(.callout.bold())
                    Text(t.subtitle).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(13)
            .background(RoundedRectangle(cornerRadius: 12).fill(active ? Color.cryoAccent.opacity(0.12) : Color.cryoElevated))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(active ? Color.cryoAccent : Color.cryoLine, lineWidth: active ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(t.title) template. \(t.subtitle)")
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }
    private func libraryRow(_ lib: ContentType) -> some View {
        let on = draft.selectedLibraryIDs.contains(lib.id)
        return Button { draft.toggleLibrary(lib.id) } label: {
            HStack(spacing: 11) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)).font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(lib.displayName).font(.callout.weight(.semibold))
                    Text(lib.paths.first?.liveURL(home: NSHomeDirectory()).path ?? "").font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                librarySizeTrailing(lib)
            }
            .padding(.vertical, 8).padding(.horizontal, 10).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 9).fill(on ? Color.cryoAccent.opacity(0.06) : .clear))
        .accessibilityLabel("\(lib.displayName)\(model.libraryValid[lib.id] == true ? ", found" : "")")
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: step 2
    private var stepDestinations: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("WHERE THE COPIES GO").font(.caption2.weight(.bold)).tracking(0.5).foregroundStyle(.tertiary)
            ForEach(draft.targets) { t in destRow(t) }
            Menu {
                Button("Local folder…") { addTarget(.local) }
                Button("Network or external drive…") { addTarget(.external) }
                Button("Cloud-sync folder…") { addTarget(.cloud) }
            } label: { Label("Add another destination", systemImage: "plus.circle") }
                .menuStyle(.borderlessButton).padding(.top, 2)
            if draft.dedupedTargets.count >= 2 {
                Label("A second copy on another drive or off-site is the 3-2-1 rule — you're covered.", systemImage: "checkmark.shield.fill").font(.caption).foregroundStyle(.cryoGood).padding(.top, 4)
            } else if !draft.dedupedTargets.isEmpty {
                Label("Tip: add a second destination (a NAS or cloud folder) for an off-site copy.", systemImage: "lightbulb").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            }
            ForEach(draft.destinationConflicts, id: \.self) { c in
                Label(c, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.cryoWarn)
            }
            headroom
        }
    }
    private func destRow(_ t: Target) -> some View {
        let on = draft.selectedTargetIDs.contains(t.id)
        let primary = draft.primaryTarget?.id == t.id
        return Button { draft.toggleTarget(t.id) } label: {
            HStack(spacing: 12) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)).font(.title3)
                Image(systemName: destIcon(t)).foregroundStyle(.secondary).frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.displayName).font(.callout.weight(.semibold))
                    Text(t.destinationDir.path).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    if let vi = model.volumeInfo(for: t.destinationDir) {
                        Text("\(human(vi.free)) free of \(human(vi.total))").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                if on && primary { Text("PRIMARY").font(.caption2.weight(.bold)).foregroundStyle(.tint).padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.cryoAccent.opacity(0.15))) }
            }
            .padding(12).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color.cryoElevated))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(on ? Color.cryoAccent.opacity(0.5) : Color.cryoLine, lineWidth: 1))
        .accessibilityLabel("\(t.displayName)\(primary && on ? ", primary destination" : "")")
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
    private func destIcon(_ t: Target) -> String {
        switch t.kind { case .local: "internaldrive"; case .networkShare: "externaldrive.connected.to.line.below"; case .cloudSync: "cloud" }
    }

    @ViewBuilder private func librarySizeTrailing(_ lib: ContentType) -> some View {
        if let sz = model.librarySizes[lib.id] {
            Text(human(sz)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        } else if model.measuringSizes.contains(lib.id) {
            ProgressView().controlSize(.mini)
        } else if model.libraryValid[lib.id] == true {
            Text("found").font(.caption2).foregroundStyle(.cryoGood)
        }
    }
    private func human(_ b: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file) }

    /// selected-size vs primary destination free space, so "not enough room" shows at setup.
    @ViewBuilder private var headroom: some View {
        let sel = draft.selectedLibraries
        let known = sel.compactMap { model.librarySizes[$0.id] }
        let total = known.reduce(UInt64(0), +)
        let allKnown = known.count == sel.count && !sel.isEmpty
        if total > 0, let primary = draft.primaryTarget, let vi = model.volumeInfo(for: primary.destinationDir) {
            let tight = total > vi.free
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: tight ? "exclamationmark.triangle.fill" : "internaldrive")
                VStack(alignment: .leading, spacing: 1) {
                    Text("About \(human(total))\(allKnown ? "" : "+") to back up · \(human(vi.free)) free on \(primary.displayName)")
                    if tight { Text("This may not fit on the primary destination.").foregroundStyle(.cryoWarn) }
                    else if draft.isSealed { Text("Sealed archives compress smaller than the source.").foregroundStyle(.tertiary) }
                }
            }
            .font(.caption).foregroundStyle(tight ? .cryoWarn : .secondary).padding(.top, 6)
        }
    }

    // MARK: step 3
    private var stepFrequency: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("HOW OFTEN").font(.caption2.weight(.bold)).tracking(0.5).foregroundStyle(.tertiary)
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 10) {
                ForEach(FreqPreset.allCases, id: \.self) { p in
                    Button { freqPreset = p; applyFreq(p) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(p.title).font(.callout.bold()); Text(p.detail).font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                        .background(RoundedRectangle(cornerRadius: 11).fill(freqPreset == p ? Color.cryoAccent.opacity(0.12) : Color.cryoElevated))
                        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(freqPreset == p ? Color.cryoAccent : Color.cryoLine, lineWidth: freqPreset == p ? 1.5 : 1))
                    }.buttonStyle(.plain)
                    .accessibilityLabel("\(p.title). \(p.detail)")
                    .accessibilityAddTraits(freqPreset == p ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
    }

    // MARK: step 4
    private var stepReview: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("REVIEW").font(.caption2.weight(.bold)).tracking(0.5).foregroundStyle(.tertiary)
            VStack(spacing: 0) {
                reviewRow("Back up", draft.selectedLibraries.map(\.displayName).joined(separator: ", "), first: true)
                reviewRow("To", draft.dedupedTargets.map(\.displayName).joined(separator: " + ") + (draft.dedupedTargets.count > 1 ? "  (\(draft.dedupedTargets.count) copies)" : ""))
                reviewRow("When", freqPreset == .nightly ? "Every night at 2:00 AM" : freqPreset.title)
                reviewRow("Format", formatSummary)
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.cryoElevated)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.cryoLine))

            DisclosureGroup {
                VStack(spacing: 0) {
                    advRow("Format", first: true) {
                        Picker("", selection: $draft.formatKind) { Text("Live mirror").tag("mirror"); if !draft.encrypt { Text("Sealed zip").tag("zip") }; Text("Sealed DMG").tag("dmg") }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                    advRow("Encryption") { Toggle("", isOn: $draft.encrypt).labelsHidden().toggleStyle(.switch).onChange(of: draft.encrypt) { _, on in if on, draft.formatKind == "zip" { draft.formatKind = "dmg" } } }
                    if draft.encrypt { advRow("Passphrase") { SecureField("Required", text: $draft.passphrase).textFieldStyle(.roundedBorder).frame(width: 190) } }
                    advRow("Verify") {
                        Picker("", selection: verifyBinding) { Text("Checksum").tag("c"); Text("Mount & open").tag("m") }.pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                    if draft.isSealed {
                        advRow("Keep versions") {
                            Picker("", selection: retentionBinding) { Text("Last 14").tag("14"); Text("Last 7").tag("7"); Text("All versions").tag("all"); Text("Daily/weekly/monthly").tag("gfs") }.labelsHidden().fixedSize()
                        }
                    }
                }
            } label: { Label("Advanced options — change any of these", systemImage: "slider.horizontal.3").font(.callout.weight(.semibold)) }
            .padding(14).background(RoundedRectangle(cornerRadius: 12).fill(Color.cryoElevated)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.cryoLine))

            if !draft.encryptionValid {
                Label("Enter a passphrase to finish — encryption is on.", systemImage: "lock.trianglebadge.exclamationmark").font(.caption).foregroundStyle(.cryoWarn)
            }
        }
    }
    private func reviewRow(_ k: String, _ v: String, first: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(k).font(.callout.weight(.semibold)).foregroundStyle(.tertiary).frame(width: 92, alignment: .leading)
            Text(v).font(.callout.weight(.medium)); Spacer(minLength: 0)
        }
        .padding(.horizontal, 15).padding(.vertical, 12)
        .overlay(alignment: .top) { if !first { Rectangle().fill(Color.cryoLine).frame(height: 1) } }
    }
    private func advRow<C: View>(_ label: String, first: Bool = false, @ViewBuilder _ control: () -> C) -> some View {
        HStack {
            Text(label).font(.callout.weight(.medium)).accessibilityHidden(true)
            Spacer()
            control().accessibilityLabel(label)      // the row's visible label, spoken with the control
        }
            .padding(.vertical, 9)
            .overlay(alignment: .top) { if !first { Rectangle().fill(Color.cryoLine).frame(height: 1) } }
    }
    private var formatSummary: String {
        let f = ["mirror": "Live mirror", "zip": "Sealed zip", "dmg": "Sealed DMG"][draft.formatKind] ?? "Sealed DMG"
        if draft.formatKind == "mirror" { return f + (draft.encrypt ? ", encrypted" : "") + " · single live copy" }
        let keep: String = { switch draft.retentionPolicy { case .keepAll: "all versions"; case .keepLast(let n): "last \(n)"; case .gfs: "daily/weekly/monthly" } }()
        return f + (draft.encrypt ? ", encrypted" : "") + " · keep \(keep)"
    }

    // MARK: footer
    private var footer: some View {
        HStack {
            Button("Back") { step -= 1 }.disabled(step == 0)
            Spacer()
            Button(step == stepTitles.count - 1 ? "Create job" : "Continue") {
                if step == stepTitles.count - 1 { if draft.commit() { isPresented = false } } else { step += 1 }
            }
            .buttonStyle(.borderedProminent).disabled(!canContinue).keyboardShortcut(.defaultAction)
        }
        .padding(18)
    }
    private var canContinue: Bool {
        switch step {
        case 0: return !draft.selectedLibraries.isEmpty
        case 1: return !draft.dedupedTargets.isEmpty && draft.destinationConflicts.isEmpty
        case 3: return draft.isValid
        default: return true
        }
    }

    // MARK: bindings
    private var verifyBinding: Binding<String> {
        Binding(get: { draft.verification == .mountAndOpen ? "m" : "c" }, set: { draft.verification = $0 == "m" ? .mountAndOpen : .checksumOnly })
    }
    private var retentionBinding: Binding<String> {
        Binding(get: { switch draft.retentionKind { case "lastN": draft.keepN == 7 ? "7" : "14"; case "gfs": "gfs"; default: "all" } },
                set: { switch $0 { case "all": draft.retentionKind = "all"; case "gfs": draft.retentionKind = "gfs"; case "7": draft.retentionKind = "lastN"; draft.keepN = 7; default: draft.retentionKind = "lastN"; draft.keepN = 14 } })
    }

    // MARK: actions
    private func seedInitialFolder() {
        guard !seeded else { return }; seeded = true
        applyFreq(.nightly)
        if let f = initialFolder {
            let ct = ContentType.genericFolder(id: f.path, displayName: f.lastPathComponent, path: ContentView.libraryPath(for: f, home: NSHomeDirectory()))
            draft.addLibrary(ct, at: f)
            draft.selectedLibraryIDs = [ct.id]
        } else if let id = initialLibraryID, draft.libraries.contains(where: { $0.id == id }) {
            draft.selectedLibraryIDs = [id]         // arrived from "this isn't backed up" — start with it chosen
        }
        model.measureLibraries(draft.libraries)     // fill in source sizes in the background
    }
    private func matchesTemplate(_ t: JobTemplate) -> Bool {
        guard !t.libraryNames.isEmpty else { return false }
        return Set(draft.selectedLibraries.map(\.displayName)) == Set(t.libraryNames) && draft.formatKind == t.formatKind
    }
    private func applyTemplate(_ t: JobTemplate) {
        guard !t.libraryNames.isEmpty else { return }
        draft.selectedLibraryIDs = Set(draft.libraries.filter { t.libraryNames.contains($0.displayName) }.map(\.id))
        draft.formatKind = t.formatKind; draft.verification = t.verify
        switch t.retention {
        case .keepAll: draft.retentionKind = "all"
        case .keepLast(let n): draft.retentionKind = "lastN"; draft.keepN = n
        case .gfs(let d, let w, let m): draft.retentionKind = "gfs"; draft.gfsDaily = d; draft.gfsWeekly = w; draft.gfsMonthly = m
        }
        freqPreset = t.nightly ? .nightly : .manual; applyFreq(freqPreset)
    }
    private func applyFreq(_ p: FreqPreset) {
        switch p {
        case .nightly:     draft.freqKind = .daily; draft.dailyTime = Calendar.current.date(bySettingHour: 2, minute: 0, second: 0, of: Date()) ?? Date()
        case .sixHours:    draft.freqKind = .everyHours; draft.everyHours = 6
        case .twelveHours: draft.freqKind = .everyHours; draft.everyHours = 12
        case .manual:      draft.freqKind = .manual
        }
    }
    private enum DestKind { case local, external, cloud }
    private func addTarget(_ kind: DestKind) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        switch kind {
        case .local:    draft.addTarget(.localVolume(id: url.path, name: url.lastPathComponent, dir: url))
        case .external: draft.addTarget(.externalDrive(id: url.path, name: url.lastPathComponent + " (resumable)", dir: url))
        case .cloud:    pendingCloudProvider = CloudProvider.identify(url); pendingCloudURL = url
        }
    }
    private func confirmCloud(_ bytes: UInt64) {
        guard let url = pendingCloudURL else { return }
        draft.addTarget(.cloudSyncFolder(id: url.path, name: "\(url.lastPathComponent) (\(pendingCloudProvider.displayName))", dir: url, provider: pendingCloudProvider, maxFileBytes: bytes))
        pendingCloudURL = nil
    }
}
