//
//  ReportProblemView.swift
//  Cryoframe (app)
//
//  Help ▸ Report a Problem: builds the diagnostics report (see DiagnosticsReport),
//  shows it in full for reading, saves it where the user says, and offers to open a
//  new GitHub issue in the browser to attach it to. Nothing is sent from here.
//

import SwiftUI
import AppKit
import CryoframeKit

struct ReportProblemView: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    @State private var report = ""
    @State private var saved: URL?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            CryoSheetHeader(title: "Report a Problem", symbol: "ladybug",
                            subtitle: "A report to attach to a GitHub issue") { isPresented = false }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("This report holds versions, how your jobs are set up, and what recent backups and checks said. Names of jobs, folders and drives are replaced with numbers. Paths, file names, web addresses and anything else in a message that Cryoframe didn't write itself are replaced with [path], […] and the like, and passwords are never included. Read it through before you save it; nothing is sent anywhere.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    Text(report.isEmpty ? "Gathering…" : report)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.cryoElevated))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.cryoLine, lineWidth: 1))
                if let saved {
                    Label("Saved to \(saved.lastPathComponent). Attach it to the issue by dragging it into the comment box.",
                          systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.cryoGood)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.cryoCrit)
                }
            }
            .padding(18)
            Divider()
            HStack {
                Button("Open GitHub Issues") { NSWorkspace.shared.open(DiagnosticsReport.issuesURL) }
                    .help("Opens a new issue on github.com in your browser")
                Spacer()
                if let saved {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                }
                Button("Save Report…") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(report.isEmpty)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 680, height: 600)
        .task { report = await Self.build(model: model) }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Cryoframe report \(Date().formatted(.iso8601.year().month().day())).txt"
        panel.allowedContentTypes = [.plainText]
        panel.message = "Save the report, then attach it to your GitHub issue"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(report.utf8).write(to: url, options: .atomic)
            saved = url; error = nil
        } catch {
            self.error = "Couldn't save the report: \(error.localizedDescription)"
        }
    }

    /// gather what the report needs; the helper's version is asked for with a bound,
    /// so a helper that doesn't answer can't hold the report up
    private static func build(model: AppModel) async -> String {
        let info = Bundle.main.infoDictionary
        let app = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        let helperState = model.helper.statusText
        let helperVersion = model.helper.isEnabled ? await HelperProbe.version(timeout: 5) : nil
        let d = UserDefaults.standard
        func pref(_ key: String, _ fallback: String) -> String { d.string(forKey: key) ?? fallback }
        let alertType = pref(Prefs.remoteAlertType, "off")
        let settings: [(String, String)] = [
            ("Helper status", helperState),
            ("Full Disk Access", model.fullDiskAccess ? "granted" : "not granted"),
            ("Notifications", pref(Prefs.notifyPolicy, "failure")),
            ("Remote alerts", alertType == "off" ? "off" : "\(alertType), \(pref(Prefs.remoteAlertEvents, "failure"))"),
            ("Archive health", "\(pref(Prefs.healthInterval, "off")), \(pref(Prefs.healthScope, "latest")), \(pref(Prefs.healthDepth, "checksum"))"),
            ("Recovery rehearsal", pref(Prefs.rehearsalCadence, "monthly")),
            ("Runs at once", d.object(forKey: Prefs.maxConcurrent).map { "\($0)" } ?? "2"),
            ("Battery floor", d.object(forKey: Prefs.batteryFloor).map { "\($0)%" } ?? "default"),
        ]
        let input = DiagnosticsReport.Input(
            appVersion: app, helperVersion: helperVersion,
            agentState: model.schedule.statusText,
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            hardware: Self.hardware(),
            jobs: model.jobs, runs: model.runHistory(), health: model.healthRecords,
            settings: settings, now: Date())
        return await Task.detached { DiagnosticsReport.build(input, redactor: DiagnosticsReport.redactor(for: input)) }.value
    }

    private static func hardware() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let name = String(decoding: model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return name.isEmpty ? "unknown" : name + " (" + (ProcessInfo.processInfo.processorCount.description) + " cores)"
    }
}

/// asks the helper for its version, giving up after `timeout` seconds
enum HelperProbe {
    static func version(timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let once = Once(cont)
            Task.detached {
                let xpc = XPCPrivilegedHelper()
                defer { xpc.invalidate() }
                once.resume((try? await xpc.handshake())?.version)
            }
            Task.detached {
                try? await Task.sleep(for: .seconds(timeout))
                once.resume(nil)
            }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<String?, Never>?
        init(_ c: CheckedContinuation<String?, Never>) { cont = c }
        func resume(_ v: String?) {
            lock.lock(); let c = cont; cont = nil; lock.unlock()
            c?.resume(returning: v)
        }
    }
}
