//
//  FileBrowserView.swift
//  Cryoframe (app)
//
//  In-app browser over an opened (mounted/extracted) archive. Drill into folders,
//  multi-select items, and extract them to a destination — no Finder hand-off, and
//  the archive stays mounted only while this sheet is up. Enumeration and copying
//  run off the main thread so a multi-GB archive doesn't freeze the UI.
//

import SwiftUI
import AppKit
import CryoframeKit

struct FileBrowserView: View {
    let archiveName: String
    let root: URL
    var onClose: () -> Void

    @State private var path: [URL] = []          // breadcrumb below root
    @State private var entries: [Entry] = []
    @State private var selected: Set<String> = []
    @State private var loading = true
    @State private var extracting = false
    @State private var status: String?

    struct Entry: Identifiable, Sendable {
        let url: URL
        let isDir: Bool
        let isPackage: Bool                       // a .photoslibrary etc — extract whole, don't drill in
        let size: UInt64
        var id: String { url.path }
        var name: String { url.lastPathComponent }
        var drillable: Bool { isDir && !isPackage }
    }

    private var current: URL { path.last ?? root }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Browse “\(archiveName)”").font(.title3.bold())
                Spacer()
                Button("Done") { onClose() }.keyboardShortcut(.cancelAction).disabled(extracting)
            }
            .padding()
            Divider()
            breadcrumb
            Divider()
            list
            Divider()
            footer
        }
        .frame(width: 560, height: 520)
        .onAppear { reload() }
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                crumb("Archive", to: 0)
                ForEach(Array(path.enumerated()), id: \.element) { i, url in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    crumb(url.lastPathComponent, to: i + 1)
                }
            }
            .padding(.horizontal).padding(.vertical, 6)
        }
    }

    private func crumb(_ label: String, to depth: Int) -> some View {
        Button(label) {
            guard !extracting, depth != path.count else { return }
            path = Array(path.prefix(depth))
            selected.removeAll(); reload()
        }
        .buttonStyle(.link).font(.caption)
    }

    private var list: some View {
        Group {
            if loading {
                VStack { Spacer(); ProgressView("Reading…"); Spacer() }
            } else if entries.isEmpty {
                VStack { Spacer(); Text("This folder is empty.").foregroundStyle(.secondary); Spacer() }
            } else {
                List {
                    ForEach(entries) { e in row(e) }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func row(_ e: Entry) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: selBinding(e.id)).labelsHidden().disabled(extracting)
            Image(systemName: icon(e))
                .foregroundStyle(e.drillable ? Color.accentColor : Color.secondary)
            Text(e.name)
            Spacer()
            if e.drillable {
                Button { drill(into: e) } label: { Image(systemName: "chevron.right").font(.caption) }
                    .buttonStyle(.borderless).disabled(extracting)
            } else if !e.isDir {
                Text(ByteCountFormatter.string(fromByteCount: Int64(e.size), countStyle: .file))
                    .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
            } else if e.isPackage {
                Text("package").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { drill(into: e) }
    }

    private func icon(_ e: Entry) -> String {
        if e.isPackage { return "shippingbox" }
        return e.isDir ? "folder.fill" : "doc"
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(selected.count == selectableCount && selectableCount > 0 ? "Deselect all" : "Select all") {
                selected = selected.count == selectableCount ? [] : Set(entries.map(\.id))
            }
            .disabled(entries.isEmpty || extracting)
            if extracting {
                ProgressView().controlSize(.small)
                Text("Extracting…").font(.caption).foregroundStyle(.secondary)
            } else if let status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !selected.isEmpty { Text("\(selected.count) selected").font(.caption).foregroundStyle(.secondary) }
            Button("Extract selected…") { extract() }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty || extracting)
        }
        .padding()
    }

    private var selectableCount: Int { entries.count }

    // MARK: navigation

    private func drill(into e: Entry) {
        guard e.drillable, !extracting else { return }
        path.append(e.url); selected.removeAll(); reload()
    }

    // MARK: data (off-main)

    private func reload() {
        loading = true
        let dir = current
        Task {
            let result = await Task.detached { Self.enumerate(dir) }.value
            guard current == dir else { return }      // user navigated again mid-read
            entries = result
            loading = false
        }
    }

    private nonisolated static func enumerate(_ dir: URL) -> [Entry] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey]
        let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [])) ?? []
        return urls.map { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            return Entry(url: url, isDir: v?.isDirectory ?? false, isPackage: v?.isPackage ?? false,
                         size: UInt64(v?.fileSize ?? 0))
        }
        .sorted { a, b in
            if a.drillable != b.drillable { return a.drillable }     // folders first
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    // MARK: extract (off-main)

    private func extract() {
        let picks = entries.filter { selected.contains($0.id) }.map(\.url)
        guard !picks.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "Choose where to extract \(picks.count) item\(picks.count == 1 ? "" : "s")"
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        extracting = true; status = nil
        Task {
            let (copied, failed) = await Task.detached { Self.copyOut(picks, to: dest) }.value
            extracting = false
            status = failed == 0 ? "Extracted \(copied) item\(copied == 1 ? "" : "s")."
                                 : "Extracted \(copied), \(failed) failed."
            if copied > 0 { NSWorkspace.shared.activateFileViewerSelecting([dest]) }
        }
    }

    private nonisolated static func copyOut(_ urls: [URL], to dest: URL) -> (copied: Int, failed: Int) {
        let fm = FileManager.default
        var copied = 0, failed = 0
        for src in urls {
            let name = src.lastPathComponent
            var target = dest.appendingPathComponent(name)
            if fm.fileExists(atPath: target.path) {
                let stem = (name as NSString).deletingPathExtension
                let ext = (name as NSString).pathExtension
                var n = 2
                repeat {
                    let candidate = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
                    target = dest.appendingPathComponent(candidate)
                    n += 1
                } while fm.fileExists(atPath: target.path) && n < 1000
            }
            do { try fm.copyItem(at: src, to: target); copied += 1 }
            catch { failed += 1 }
        }
        return (copied, failed)
    }

    private func selBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { selected.contains(id) },
                set: { if $0 { selected.insert(id) } else { selected.remove(id) } })
    }
}
