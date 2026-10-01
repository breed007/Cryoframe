//
//  FindFileView.swift
//  Cryoframe (app)
//
//  Restore → Find a File: which version holds a file, from each version's file
//  list (see ContentsListing), newest first, with Stop. A match opens the version
//  in the file browser at the item, ready for "Extract selected…". A version with
//  no list to search says so and offers to look inside it instead; nothing is
//  ever called "not in this version" unless its whole list was read.
//

import SwiftUI
import AppKit
import CryoframeKit

@MainActor
final class FindFileModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var results: [VersionSearchResult] = []
    @Published private(set) var running = false
    @Published private(set) var searchedFor: String?
    @Published private(set) var total = 0
    @Published private(set) var stopped = false
    @Published var opening: String?
    @Published var errorMessage: String?
    @Published var browsing: Browse?

    struct Browse: Identifiable {
        let id = UUID()
        let name: String
        let root: URL
        let reveal: URL?
    }

    /// keys derived during this sheet's searches, in memory only (see ContentsKeyring)
    private let keyring = ContentsKeyring()
    private var control: RunControl?
    private var task: Task<Void, Never>?
    private var opened: OpenedArchive?

    /// the passphrases to try on a version: the one typed in, and the one saved on
    /// this Mac for the job the list (or the version's folder) says made it
    nonisolated static func passphrases(typed: String, jobID: String?) -> [String] {
        var out: [String] = []
        if !typed.isEmpty { out.append(typed) }
        if let jobID, let saved = KeychainArchiveKey.load(jobID: jobID), !saved.isEmpty, saved != typed { out.append(saved) }
        return out
    }

    func search(_ archives: [RestorableArchive], passphrase: String) {
        guard !running, let q = ContentsQuery(query) else { return }
        let versions = ContentsSearch.versions(archives)
        let control = RunControl()
        self.control = control
        results = []; total = versions.count; stopped = false; searchedFor = q.text; running = true
        let search = ContentsSearch(keyring: keyring)
        task = Task {
            for v in versions {
                let r = await Task.detached {
                    search.search(q, in: v, passphrases: { job in Self.passphrases(typed: passphrase, jobID: job) }, control: control)
                }.value
                guard let r else { break }
                results.append(r)
                if control.isCancelled { break }
            }
            stopped = control.isCancelled
            running = false
        }
    }

    func stop() { control?.cancel() }

    var summary: String { ContentsSearch.summary(results, of: total, stopped: stopped) }

    /// Open `a` and show it in the file browser, at `path` (from its list) or at its
    /// top. An encrypted version takes the typed passphrase, or the one saved for
    /// the job its folder says made it.
    func open(_ a: RestorableArchive, at path: String?, passphrase: String) {
        guard opening == nil else { return }
        let job = a.libraryKey?.split(separator: "/", maxSplits: 1).first.map(String.init)
        let candidates = a.encrypted ? Self.passphrases(typed: passphrase, jobID: job) : [""]
        if a.encrypted, candidates.isEmpty { errorMessage = "Enter the passphrase for \(a.displayName) first."; return }
        opening = a.bundleName
        let result = a.archiveResult()
        Task {
            let o: OpenedArchive? = await Task.detached {
                for pass in candidates {
                    if let o = try? ArchiveReader().open(result, passphrase: a.encrypted ? pass : nil) { return o }
                }
                return nil
            }.value
            opening = nil
            guard let o else {
                errorMessage = "Couldn't open \(a.bundleName)" + (a.encrypted ? ". Check the passphrase." : ".")
                return
            }
            closeBrowse()
            opened = o
            browsing = Browse(name: a.bundleName, root: o.root,
                              reveal: path.map { ArchiveLayout.item($0, in: o.root, for: a) })
        }
    }

    func closeBrowse() {
        opened?.close()
        opened = nil
        browsing = nil
    }

    func tearDown() {
        stop()
        closeBrowse()
    }
}

struct FindFileView: View {
    @ObservedObject var restore: RestoreModel
    @StateObject private var f = FindFileModel()
    var onClose: () -> Void

    private var anyEncrypted: Bool { restore.archives.contains { $0.encrypted } }

    var body: some View {
        VStack(spacing: 0) {
            CryoSheetHeader(title: "Find a File", symbol: "magnifyingglass",
                            subtitle: "See which saved versions hold a file or folder") {
                f.tearDown(); onClose()
            }
            Divider()
            searchBar
            Divider()
            resultsList
            Divider()
            footer
        }
        .frame(width: 640, height: 560)
        .onDisappear { f.stop() }
        .sheet(item: $f.browsing) { b in
            // the archive is closed when its browser goes, however it goes
            FileBrowserView(archiveName: b.name, root: b.root, reveal: b.reveal) { f.closeBrowse() }
                .onDisappear { f.closeBrowse() }
        }
        .alert("Find a File", isPresented: Binding(get: { f.errorMessage != nil }, set: { if !$0 { f.errorMessage = nil } })) {
            Button("OK") { f.errorMessage = nil }
        } message: { Text(f.errorMessage ?? "") }
    }

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("File or folder name, or part of its path", text: $f.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { start() }
                    .disabled(f.running)
                if f.running {
                    Button("Stop") { f.stop() }
                } else {
                    Button("Search") { start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(ContentsQuery(f.query) == nil)
                }
            }
            if anyEncrypted {
                HStack(spacing: 8) {
                    SecureField("Passphrase for encrypted backups", text: $restore.passphrase)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                        .disabled(f.running)
                    Text("A passphrase saved on this Mac is tried too.").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private func start() { f.search(restore.archives, passphrase: restore.passphrase) }

    @ViewBuilder private var resultsList: some View {
        if f.searchedFor == nil {
            CryoEmptyState(symbol: "magnifyingglass", title: "Search every version here",
                           message: "Type a name such as “Taxes 2024.pdf”, or part of a path such as “Documents/Taxes”. Each version is searched by the list of files saved with it.")
        } else {
            List {
                ForEach(f.results) { r in
                    Section { rows(r) } header: { versionHeader(r) }
                }
                if f.running {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Searching \(min(f.results.count + 1, f.total)) of \(f.total)…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func versionHeader(_ r: VersionSearchResult) -> some View {
        HStack(spacing: 6) {
            Text(r.archive.libraryName).font(.callout.weight(.semibold))
            Text(r.archive.version.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Current mirror")
                .font(.caption).foregroundStyle(.secondary)
            if r.archive.encrypted {
                Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary).accessibilityLabel("encrypted")
            }
        }
    }

    @ViewBuilder private func rows(_ r: VersionSearchResult) -> some View {
        switch r.answer {
        case .listed(let hits, let more, let partial):
            ForEach(hits, id: \.path) { hit in hitRow(hit, in: r.archive) }
            if hits.isEmpty || more || partial {
                Text(r.summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .noList:
            HStack(spacing: 8) {
                Image(systemName: "questionmark.folder").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(r.summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Look inside…") { f.open(r.archive, at: nil, passphrase: restore.passphrase) }
                    .disabled(f.opening != nil)
            }
        }
    }

    private func hitRow(_ hit: ContentsEntry, in a: RestorableArchive) -> some View {
        HStack(spacing: 8) {
            Image(systemName: hit.kind == .folder ? "folder.fill" : hit.kind == .link ? "arrow.turn.up.right" : "doc")
                .foregroundStyle(hit.kind == .folder ? Color.cryoAccent : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(hit.name).lineLimit(1)
                Text(hit.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if hit.kind == .file {
                Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: hit.size), countStyle: .file))
                    .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
            }
            Text(hit.modifiedDate.formatted(date: .abbreviated, time: .omitted))
                .font(.caption2).foregroundStyle(.tertiary)
            Button("Show") { f.open(a, at: hit.path, passphrase: restore.passphrase) }
                .disabled(f.opening != nil)
                .help("Open this version at \(hit.name), to extract it")
                .accessibilityLabel("Show \(hit.name)")
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let name = f.opening {
                ProgressView().controlSize(.small)
                Text("Opening \(name)…").font(.caption).foregroundStyle(.secondary)
            } else if f.searchedFor != nil, !f.running || !f.results.isEmpty {
                Text(f.summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .frame(minHeight: 40)
    }
}
