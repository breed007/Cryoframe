//
//  ExportMediaView.swift
//  Cryoframe (app)
//
//  Restore → Export Media…: one version's photos, videos or other files copied out
//  as ordinary files into month folders (see MediaExport). The version is opened
//  for the export and closed after it, or as soon as the sheet goes; an open still
//  running then is stopped, and what it opens anyway is closed (see ArchiveOpener).
//

import SwiftUI
import AppKit
import CryoframeKit

@MainActor
final class ExportMediaModel: ObservableObject {
    @Published var photos = true
    @Published var videos = true
    @Published var other = false
    @Published var limitMonths = false
    @Published var from = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
    @Published var through = Date()
    @Published var folder: URL? = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
    @Published private(set) var driveEncrypted = false

    @Published private(set) var running = false
    /// when the version began opening, while it opens (nil: not opening)
    @Published private(set) var openingSince: Date?
    @Published private(set) var progress: MediaExportProgress?
    @Published private(set) var stopping = false
    @Published var result: String?
    @Published var failed = false
    /// it finished, but some files couldn't be read and were left out
    @Published var warned = false

    private let opener = ArchiveOpener()
    private var control: RunControl?

    // a sheet closed mid-open: the open is stopped, and what it still opens is closed
    deinit { opener.close() }

    var filter: MediaExportFilter {
        var kinds: Set<MediaKind> = []
        if photos { kinds.insert(.photos) }
        if videos { kinds.insert(.videos) }
        if other { kinds.insert(.other) }
        guard limitMonths else { return MediaExportFilter(kinds: kinds) }
        let (a, b) = (MediaMonth(from), MediaMonth(through))
        return MediaExportFilter(kinds: kinds, from: min(a, b), through: max(a, b))
    }

    func checkDrive() async {
        guard let folder else { driveEncrypted = false; return }
        driveEncrypted = await Task.detached { MediaExportDrive.of(folder).encrypted }.value
    }

    func start(_ a: RestorableArchive, passphrases: [String]) {
        guard !running, let destination = folder, !filter.kinds.isEmpty else { return }
        if a.encrypted, passphrases.isEmpty { failed = true; result = "Enter the passphrase for \(a.displayName) first."; return }
        let filter = self.filter, opener = self.opener
        running = true; stopping = false; result = nil; failed = false; warned = false; progress = nil
        openingSince = Date()
        Task {
            let outcome = await opener.open(a, passphrases: a.encrypted ? passphrases : [])
            openingSince = nil
            switch outcome {
            case .canceled:
                finish("Stopped before anything was copied.", failed: false)
            case .failed(let why):
                finish(why, failed: true)
            case .opened(let o):
                let control = RunControl()
                self.control = control
                if stopping { control.cancel() }
                let source = MediaExportScope.folder(in: ArchiveLayout.libraryRoot(in: o.root, for: a), for: a)
                let ran: Result<MediaExportOutcome, Error> = await Task.detached {
                    Result {
                        try MediaExport().run(from: source, to: destination, filter: filter, control: control) { p in
                            // the export holds the model until it ends, so this never outlives it
                            Task { @MainActor in
                                guard self.running, !self.stopping else { return }
                                self.progress = p
                            }
                        }
                    }
                }.value
                self.control = nil
                // closed before the next export can open: a close landing after that open would stop it
                await Task.detached { opener.close() }.value
                switch ran {
                case .success(let r):
                    finish(r.summary(folder: destination.lastPathComponent), failed: false, warned: !r.unreadable.isEmpty)
                case .failure(let e): finish(e.localizedDescription, failed: true)
                }
            }
        }
    }

    private func finish(_ text: String, failed: Bool, warned: Bool = false) {
        result = text; self.failed = failed; self.warned = warned
        running = false; stopping = false; progress = nil; openingSince = nil
    }

    func stop() {
        guard running else { return }
        stopping = true
        if let control { control.cancel() } else { opener.close() }
    }
}

struct ExportMediaView: View {
    let archive: RestorableArchive
    /// the passphrases to try on an encrypted version
    let passphrases: [String]
    var onClose: () -> Void
    @StateObject private var m = ExportMediaModel()

    private var when: String { archive.version?.formatted(date: .abbreviated, time: .shortened) ?? "Current" }
    private var warning: String? { MediaExportScope.warning(for: archive, driveEncrypted: m.driveEncrypted) }

    var body: some View {
        VStack(spacing: 0) {
            CryoSheetHeader(title: "Export Media", symbol: "square.and.arrow.up.on.square",
                            subtitle: "Copy files out of this backup into a folder, sorted into month folders",
                            doneIsDefault: false) {
                m.stop(); onClose()
            }
            Divider()
            Form {
                Section {
                    LabeledContent("From") {
                        Text("\(archive.libraryName) · \(when)")
                    }
                }
                Section("What to copy") {
                    Toggle(MediaKind.photos.title, isOn: $m.photos)
                        .help("Pictures, and each Live Photo's video beside it")
                    Toggle(MediaKind.videos.title, isOn: $m.videos)
                    Toggle(MediaKind.other.title, isOn: $m.other)
                        .help("Everything else: documents, audio and the like")
                    Toggle("Only files from some months", isOn: $m.limitMonths)
                    if m.limitMonths {
                        DatePicker("From the month of", selection: $m.from, displayedComponents: .date)
                        DatePicker("Through the month of", selection: $m.through, displayedComponents: .date)
                    }
                }
                Section {
                    LabeledContent("Copy into") {
                        HStack(spacing: 6) {
                            Text(m.folder?.path ?? "No folder chosen").lineLimit(1).truncationMode(.middle)
                            Button("Choose…") { chooseFolder() }
                        }
                    }
                } footer: {
                    Text("Each file goes into a folder named for the month it was last changed, such as 2024-05. Exporting again copies only what isn't there yet.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .disabled(m.running)
            if let warning {
                Label(warning, systemImage: "lock.open")
                    .font(.caption).foregroundStyle(.cryoWarn)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.vertical, 8)
            }
            Divider()
            footer
        }
        .frame(width: 560)
        .frame(minHeight: 520)
        .interactiveDismissDisabled(m.running)
        .task(id: m.folder) { await m.checkDrive() }
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: 12) {
            status
            Spacer(minLength: 12)
            if m.running {
                Button("Stop") { m.stop() }.disabled(m.stopping)
            } else {
                Button("Export") { m.start(archive, passphrases: passphrases) }
                    .buttonStyle(.borderedProminent)
                    .disabled(m.folder == nil || m.filter.kinds.isEmpty)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .frame(minHeight: 58)
    }

    @ViewBuilder private var status: some View {
        if m.running {
            HStack(spacing: 8) {
                if let f = m.progress?.fraction {
                    ProgressView(value: min(max(f, 0), 1)).frame(width: 120)
                } else {
                    ProgressView().controlSize(.small)
                }
                // the time ticks while the backup opens: an open can't say how far it has got
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(statusText(now: context.date)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        } else if let result = m.result {
            Label(result, systemImage: m.failed ? "xmark.circle.fill" : m.warned ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.caption).foregroundStyle(m.failed ? Color.cryoCrit : m.warned ? Color.cryoWarn : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func statusText(now: Date) -> String {
        if m.stopping { return "Stopping…" }
        if let since = m.openingSince {
            return "Opening the backup… \(Duration.seconds(max(0, now.timeIntervalSince(since))).formatted(.time(pattern: .minuteSecond)))"
        }
        return m.progress?.detail ?? "Starting…"
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { m.folder = url }
    }
}
