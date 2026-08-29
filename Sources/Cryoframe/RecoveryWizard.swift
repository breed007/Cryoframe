//
//  RecoveryWizard.swift
//  Cryoframe (app)
//
//  The worst day, as a walkthrough: a new (or wiped) Mac, a drive full of archives,
//  and everything to bring back. Four steps — find the backups, unlock them with the
//  recovery key, choose the moment to rebuild to, review — then restore every library
//  in one pass.
//
//  This is the counterpart to the restore timeline: the timeline answers "give me
//  THAT library from SOME night", this answers "rebuild this Mac as it was".
//

import SwiftUI
import AppKit
import CryoframeKit

@MainActor
final class RecoveryModel: ObservableObject {
    @Published var sourceFolder: URL?
    @Published var archives: [RestorableArchive] = []
    @Published var scanning = false

    // unlock
    @Published var keyFile: URL?
    @Published var masterPassword = ""
    @Published var unlockError: String?
    /// library display name → passphrase, recovered from the escrow file. On a new Mac
    /// there are no jobs, so escrow entries are matched by library name, not job id.
    @Published var passphrases: [String: String] = [:]
    @Published var unlockedCount = 0

    // moment
    @Published var momentIndex: Int = 0

    // destination
    @Published var toOriginalLocations = true
    @Published var customFolder: URL? = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first

    // run
    @Published var running = false
    @Published var stage = ""
    @Published var results: [Outcome] = []

    struct Outcome: Identifiable { let id = UUID(); let library: String; let ok: Bool; let detail: String; let url: URL? }

    var moments: [Date] { RecoveryPlan.moments(in: archives) }
    var moment: Date? { moments.indices.contains(momentIndex) ? moments[momentIndex] : moments.last }
    var selections: [RecoveryPlan.Selection] {
        guard let m = moment else { return [] }
        return RecoveryPlan.selections(at: m, in: archives)
    }
    var encryptedLibraries: [String] {
        Array(Set(archives.filter(\.encrypted).map(\.libraryName))).sorted()
    }
    var hasEncrypted: Bool { !encryptedLibraries.isEmpty }
    /// encrypted libraries we still have no passphrase for — they can't be restored.
    var lockedOut: [String] { encryptedLibraries.filter { passphrases[$0] == nil } }
    var totalBytes: UInt64 { RecoveryPlan.totalBytes(selections) }

    func scan(_ folder: URL) {
        sourceFolder = folder
        scanning = true
        Task {
            let found = await Task.detached { RestoreDiscovery.scan(folder) }.value
            archives = found
            momentIndex = max(0, RecoveryPlan.moments(in: found).count - 1)   // default: the latest moment
            scanning = false
        }
    }

    /// open the escrow file and map every recovered passphrase onto its libraries.
    func unlock() {
        unlockError = nil
        guard let url = keyFile, let data = try? Data(contentsOf: url) else {
            unlockError = "Couldn't read that recovery file."; return
        }
        guard let entries = PassphraseEscrow.importEntries(data, password: masterPassword) else {
            unlockError = "Wrong master password, or this isn't a Cryoframe recovery file."; return
        }
        passphrases = PassphraseEscrow.passphrasesByLibrary(entries)
        unlockedCount = entries.count
        masterPassword = ""                       // don't keep it around once it's been used
    }

    func passphrase(for library: String) -> String? { passphrases[library] }

    /// restore every selected version, one library at a time.
    func run(destinationFor: @escaping @Sendable (String) -> URL?) {
        guard !running else { return }
        let items = selections
        guard !items.isEmpty else { return }
        let keys = passphrases
        running = true; results = []
        Task {
            var out: [Outcome] = []
            for s in items {
                let lib = s.library
                guard let dest = destinationFor(lib) else {
                    out.append(Outcome(library: lib, ok: false,
                                       detail: "couldn't work out where this library belongs — restore it from the timeline instead", url: nil))
                    continue
                }
                if s.archive.encrypted, keys[lib] == nil {
                    out.append(Outcome(library: lib, ok: false, detail: "encrypted, and no passphrase was recovered", url: nil))
                    continue
                }
                stage = "\(lib): starting"
                let pass = s.archive.encrypted ? keys[lib] : nil
                out.append(await Self.restoreOne(s.archive, library: lib, to: dest, passphrase: pass) { st in
                    Task { @MainActor in self.stage = "\(lib): \(st.rawValue)" }
                })
            }
            results = out; running = false; stage = ""
        }
    }

    private nonisolated static func restoreOne(_ a: RestorableArchive, library: String, to dest: URL,
                                               passphrase: String?,
                                               onStage: @escaping @Sendable (RestoreStage) -> Void) async -> Outcome {
        await Task.detached {
            do {
                try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                // always verify: a recovery you can't trust is worse than none.
                let url = try RestoreEngine().restore(a, to: dest, verify: true, passphrase: passphrase, onStage: onStage)
                return Outcome(library: library, ok: true, detail: "restored to \(dest.path)", url: url)
            } catch {
                return Outcome(library: library, ok: false, detail: Self.message(error, encrypted: a.encrypted), url: nil)
            }
        }.value
    }

    private nonisolated static func message(_ e: Error, encrypted: Bool) -> String {
        if let r = e as? RestoreError {
            switch r {
            case .verificationFailed(let d): return "verification failed — \(d)"
            case .destinationExists(let p):  return "something is already at \(  (p as NSString).lastPathComponent) — it was left alone"
            case .libraryNotFound:           return "the archive didn't contain the library"
            case .noManifest:                return "no checksum manifest beside the archive"
            }
        }
        if let a = e as? ArchiveError {
            switch a {
            case .toolFailed(_, _, let stderr):
                if encrypted { return "couldn't open — check the recovery key" }
                return "couldn't open the archive — \(stderr.split(separator: "\n").last.map(String.init) ?? "unreadable")"
            case .noArtifactProduced:    return "the archive is missing its files"
            case .sourceMissing(let s):  return "missing part of the archive — \(s)"
            case .passphraseUnavailable: return "encrypted, and no passphrase was recovered"
            }
        }
        return (e as NSError).localizedDescription
    }
}

struct RecoveryWizard: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    @StateObject private var r = RecoveryModel()
    @State private var step = 0

    private let titles = ["Find backups", "Unlock", "Point in time", "Review"]

    var body: some View {
        VStack(spacing: 0) {
            header
            stepBar
            Divider()
            ScrollView { body(for: step).padding(22).frame(maxWidth: .infinity, alignment: .leading) }
            Divider()
            footer
        }
        .frame(width: 640, height: 620)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [.cryoAccent, .cryoGood], startPoint: .topLeading, endPoint: .bottomTrailing)))
            VStack(alignment: .leading, spacing: 3) {
                Text("Recover to this Mac").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Text(subhead).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button { isPresented = false } label: { Image(systemName: "xmark") }
                .buttonStyle(.bordered).help("Close").accessibilityLabel("Close recovery")
        }
        .padding([.horizontal, .top], 22).padding(.bottom, 14)
    }

    private var subhead: String {
        ["New Mac, or a fresh start? Let's bring your libraries back.",
         "Unlock the encrypted ones with your recovery key.",
         "Choose the moment to rebuild to.",
         "Ready when you are — nothing here is overwritten."][step]
    }

    private var stepBar: some View {
        HStack(spacing: 8) {
            ForEach(Array(titles.enumerated()), id: \.offset) { i, title in
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 3).fill(i <= step ? Color.cryoAccent : Color.cryoLine).frame(height: 4)
                    Text("\(i + 1). \(title)").font(.caption2.weight(.semibold))
                        .foregroundStyle(i == step ? .primary : .secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
    }

    @ViewBuilder private func body(for step: Int) -> some View {
        switch step {
        case 0: stepFind
        case 1: stepUnlock
        case 2: stepMoment
        default: stepReview
        }
    }

    // MARK: - 1 · find

    private var stepFind: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("WHERE ARE YOUR BACKUPS?").font(.caption2.weight(.bold)).tracking(0.5).foregroundStyle(.tertiary)
            Text("Connect the drive, NAS, or cloud folder your archives were written to. Cryoframe reads what's there — nothing is changed until you say so.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Button { chooseFolder { r.scan($0) } } label: {
                Label(r.sourceFolder == nil ? "Choose folder…" : "Choose a different folder…", systemImage: "folder")
            }
            .controlSize(.large)

            let quick = model.restoreSources
            if !quick.isEmpty, r.sourceFolder == nil {
                HStack(spacing: 6) {
                    Text("or").font(.caption).foregroundStyle(.tertiary)
                    ForEach(quick) { t in Button(t.displayName) { r.scan(t.destinationDir) }.buttonStyle(.link).font(.caption) }
                }
            }

            if let f = r.sourceFolder {
                Text(f.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                if r.scanning {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking for archives…").font(.callout).foregroundStyle(.secondary) }
                } else if r.archives.isEmpty {
                    noticeBox(icon: "exclamationmark.triangle.fill", tint: .cryoWarn,
                              text: "No Cryoframe archives in that folder. Try the folder your backups were written to — it holds one folder per library.")
                } else {
                    noticeBox(icon: "checkmark.circle.fill", tint: .cryoGood, text: foundSummary)
                }
            }
        }
    }

    private var foundSummary: String {
        let libs = RestoreDiscovery.libraries(in: r.archives).count
        let moments = r.moments.count
        var s = "Found \(libs) \(libs == 1 ? "library" : "libraries")"
        if moments > 0 { s += " · \(moments) point\(moments == 1 ? "" : "s") in time" }
        if r.hasEncrypted { s += " · \(r.encryptedLibraries.count) encrypted" }
        return s
    }

    // MARK: - 2 · unlock

    private var stepUnlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("UNLOCK ENCRYPTED LIBRARIES").font(.caption2.weight(.bold)).tracking(0.5).foregroundStyle(.tertiary)
            if !r.hasEncrypted {
                noticeBox(icon: "checkmark.circle.fill", tint: .cryoGood,
                          text: "Nothing here is encrypted — there's nothing to unlock. Carry on.")
            } else if r.passphrases.isEmpty {
                Text("\(r.encryptedLibraries.count) of \(RestoreDiscovery.libraries(in: r.archives).count) libraries are encrypted. Open the recovery-key file you exported and kept somewhere safe — it recovers every passphrase at once.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button { chooseKeyFile() } label: { Label("Choose recovery file…", systemImage: "key.fill") }
                    if let k = r.keyFile {
                        Text(k.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                HStack(spacing: 10) {
                    SecureField("Master password", text: $r.masterPassword)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                        .onSubmit { r.unlock() }
                    Button("Unlock") { r.unlock() }
                        .disabled(r.keyFile == nil || r.masterPassword.isEmpty)
                }
                if let e = r.unlockError {
                    Label(e, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.cryoCrit)
                }
                Text("No recovery file? You can still restore anything that isn't encrypted — skip this step.")
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            } else {
                noticeBox(icon: "checkmark.circle.fill", tint: .cryoGood,
                          text: "Recovered \(r.unlockedCount) passphrase\(r.unlockedCount == 1 ? "" : "s").")
                VStack(spacing: 2) {
                    ForEach(r.encryptedLibraries, id: \.self) { lib in
                        HStack(spacing: 8) {
                            Image(systemName: r.passphrase(for: lib) != nil ? "lock.open.fill" : "lock.fill")
                                .font(.caption).foregroundStyle(r.passphrase(for: lib) != nil ? .cryoGood : .cryoWarn)
                            Text(lib).font(.callout)
                            Spacer()
                            Text(r.passphrase(for: lib) != nil ? "unlocked" : "still locked")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6).padding(.horizontal, 10)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.cryoElevated))
                if !r.lockedOut.isEmpty {
                    Text("\(r.lockedOut.count) encrypted \(r.lockedOut.count == 1 ? "library has" : "libraries have") no matching passphrase — \(r.lockedOut.count == 1 ? "it" : "they") will be skipped.")
                        .font(.caption).foregroundStyle(.cryoWarn)
                }
            }
        }
    }

    // MARK: - 3 · point in time

    private var stepMoment: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("CHOOSE A MOMENT").font(.caption2.weight(.bold)).tracking(0.5).foregroundStyle(.tertiary)
            if r.moments.isEmpty {
                noticeBox(icon: "info.circle.fill", tint: .cryoAccent,
                          text: "These backups are live mirrors, which keep a single up-to-date copy. There's one state to restore: right now.")
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(r.moment.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                        .font(.system(size: 20, weight: .bold))
                    Spacer()
                    Button("Jump to latest") { r.momentIndex = max(0, r.moments.count - 1) }
                        .buttonStyle(.link).font(.caption)
                        .disabled(r.momentIndex == r.moments.count - 1)
                }
                if r.moments.count > 1 {
                    Slider(value: Binding(get: { Double(r.momentIndex) },
                                          set: { r.momentIndex = Int($0.rounded()) }),
                           in: 0...Double(r.moments.count - 1), step: 1)
                        .accessibilityLabel("Point in time")
                        .accessibilityValue(r.moment.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
                    HStack {
                        Text(r.moments.first!.formatted(.dateTime.month(.abbreviated).day())).font(.caption2).foregroundStyle(.tertiary)
                        Spacer()
                        Text("latest").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Text("Each library restores the version it had at that moment — never a newer one, so you get your Mac as it actually was.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 2) { ForEach(r.selections) { selectionRow($0) } }
            }
        }
    }

    private func selectionRow(_ s: RecoveryPlan.Selection) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up.fill").font(.caption).foregroundStyle(.cryoAccent).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.library).font(.callout.weight(.medium))
                Text(versionLine(s)).font(.caption2).foregroundStyle(s.isAfterMoment ? .cryoWarn : .secondary)
            }
            Spacer()
            if s.archive.encrypted {
                Image(systemName: r.passphrase(for: s.library) != nil ? "lock.open.fill" : "lock.fill")
                    .font(.caption2).foregroundStyle(r.passphrase(for: s.library) != nil ? .cryoGood : .cryoWarn)
            }
            Text(ByteCountFormatter.string(fromByteCount: Int64(s.archive.bytes), countStyle: .file))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, 7).padding(.horizontal, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(s.library), \(versionLine(s))")
    }

    private func versionLine(_ s: RecoveryPlan.Selection) -> String {
        if s.isCurrentOnly { return "current mirror" }
        guard let v = s.archive.version else { return "current" }
        let d = v.formatted(date: .abbreviated, time: .shortened)
        return s.isAfterMoment ? "\(d) — its oldest backup, newer than the moment you picked" : d
    }

    // MARK: - 4 · review

    private var stepReview: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("REVIEW").font(.caption2.weight(.bold)).tracking(0.5).foregroundStyle(.tertiary)
            VStack(spacing: 0) {
                reviewRow("Restore", "\(r.selections.count) \(r.selections.count == 1 ? "library" : "libraries")",
                          detail: r.selections.map(\.library).joined(separator: ", "))
                Divider()
                reviewRow("From", r.moment.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "the current copy",
                          detail: r.momentIndex == r.moments.count - 1 && !r.moments.isEmpty ? "the latest backup" : "each library as it was then")
                Divider()
                reviewRow("Source", r.sourceFolder?.lastPathComponent ?? "—", detail: r.sourceFolder?.path ?? "")
                Divider()
                destinationRow
                Divider()
                reviewRow("Size", ByteCountFormatter.string(fromByteCount: Int64(r.totalBytes), countStyle: .file),
                          detail: freeSpaceLine)
            }
            .background(RoundedRectangle(cornerRadius: 11).fill(Color.cryoElevated))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.cryoLine, lineWidth: 1))

            if !r.lockedOut.isEmpty {
                noticeBox(icon: "lock.fill", tint: .cryoWarn,
                          text: "\(r.lockedOut.joined(separator: ", ")) will be skipped — still locked.")
            }
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "checkmark.shield.fill").foregroundStyle(.cryoGood).font(.callout)
                Text("Each archive is verified before it's written. If one can't be opened, that library is skipped and reported — the rest still restore. Nothing already on this Mac is overwritten.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !r.results.isEmpty { resultsBlock }
        }
    }

    private var destinationRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("To").font(.callout).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 10) {
                    Text(r.toOriginalLocations ? "Original locations" : (r.customFolder?.lastPathComponent ?? "a folder"))
                        .font(.callout.weight(.semibold))
                    Button("Change…") { changeDestination() }.buttonStyle(.link).font(.caption)
                }
                Text(r.toOriginalLocations
                     ? "Photos, Messages, and the rest go back where their apps look for them."
                     : (r.customFolder?.path ?? ""))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
        }
        .padding(.vertical, 10).padding(.horizontal, 13)
    }

    private func reviewRow(_ key: String, _ value: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(key).font(.callout).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.callout.weight(.semibold))
                if !detail.isEmpty {
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                }
            }
            Spacer()
        }
        .padding(.vertical, 10).padding(.horizontal, 13)
    }

    private var freeSpaceLine: String {
        let dest = r.toOriginalLocations
            ? FileManager.default.homeDirectoryForCurrentUser
            : (r.customFolder ?? FileManager.default.homeDirectoryForCurrentUser)
        // "important usage" only means anything on the volume holding the home
        // directory. An external drive — where someone recovering onto a fresh Mac
        // is most likely to point this — answers 0, and saying "only Zero KB free,
        // not enough room" on the worst day is how you talk someone out of a
        // recovery that would have worked. JobExecutor.freeSpace already reads a
        // volume correctly; use it rather than a third private copy of the rule.
        guard let free = JobExecutor.freeSpace(for: dest) else { return "" }
        let freeStr = ByteCountFormatter.string(fromByteCount: Int64(free), countStyle: .file)
        return r.totalBytes > free ? "only \(freeStr) free — not enough room" : "\(freeStr) free"
    }

    private var resultsBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("RESULTS").font(.caption2.weight(.bold)).tracking(0.5).foregroundStyle(.tertiary)
            ForEach(r.results) { o in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: o.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(o.ok ? .cryoGood : .cryoCrit)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(o.library).font(.callout.weight(.medium))
                        Text(o.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                    }
                    Spacer()
                    if let u = o.url {
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([u]) }.buttonStyle(.link).font(.caption)
                    }
                }
            }
        }
    }

    // MARK: - footer

    private var footer: some View {
        HStack(spacing: 10) {
            if r.running {
                ProgressView().controlSize(.small)
                Text(r.stage).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else if step == 3 && !r.results.isEmpty {
                let ok = r.results.filter(\.ok).count
                Text("\(ok) of \(r.results.count) restored").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Nothing on this Mac is overwritten.").font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            if step > 0 && r.results.isEmpty {
                Button("Back") { step -= 1 }.disabled(r.running)
            }
            if !r.results.isEmpty {
                Button("Done") { isPresented = false }.buttonStyle(.borderedProminent)
            } else if step < 3 {
                Button("Continue") { step += 1 }
                    .buttonStyle(.borderedProminent).disabled(!canContinue)
            } else {
                Button("Restore everything") { startRestore() }
                    .buttonStyle(.borderedProminent)
                    .disabled(r.running || r.selections.isEmpty || r.selections.count == r.lockedOut.count)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 13)
    }

    private var canContinue: Bool {
        switch step {
        case 0: return !r.archives.isEmpty && !r.scanning
        default: return true
        }
    }

    // MARK: - actions

    private func startRestore() {
        let toOriginal = r.toOriginalLocations
        let custom = r.customFolder
        r.run { library in
            guard toOriginal else { return custom }
            return Self.originalParent(for: library)
        }
    }

    /// where a library normally lives on this Mac — the PARENT folder, since the
    /// engine writes `<dest>/<bundle name>`. nil when Cryoframe doesn't know the
    /// library (a custom folder someone backed up), so the caller can report it.
    private nonisolated static func originalParent(for library: String) -> URL? {
        let reg = ContentTypeRegistry.withOverrides(LibraryOverrides.load())
        guard let type = reg.types.first(where: { $0.displayName == library }),
              let live = ContentLocator().liveRoots(of: type).first else { return nil }
        return live.deletingLastPathComponent()
    }

    private func changeDestination() {
        let alert = NSAlert()
        alert.messageText = "Where should the libraries go?"
        alert.informativeText = "Original locations put each library back where its app looks for it — best on a fresh Mac. Or restore everything into one folder and move it yourself."
        alert.addButton(withTitle: "Original locations")
        alert.addButton(withTitle: "Choose a folder…")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:  r.toOriginalLocations = true
        case .alertSecondButtonReturn: chooseFolder { r.customFolder = $0; r.toOriginalLocations = false }
        default: break
        }
    }

    private func chooseFolder(_ then: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "Choose the folder holding your Cryoframe archives"
        if panel.runModal() == .OK, let url = panel.url { then(url) }
    }

    private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choose your Cryoframe recovery file"
        if panel.runModal() == .OK, let url = panel.url { r.keyFile = url; r.unlockError = nil }
    }

    private func noticeBox(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon).foregroundStyle(tint).font(.callout)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.30), lineWidth: 1))
    }
}
