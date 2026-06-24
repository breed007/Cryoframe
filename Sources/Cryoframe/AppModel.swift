//
//  AppModel.swift
//  Cryoframe (app)
//
//  Central state for the GUI: jobs (persisted), targets, system services, and
//  the live run/verification status. Runs jobs through the same JobRunner the
//  scheduled agent uses.
//

import Foundation
import SwiftUI
import CryoframeKit

@MainActor
final class AppModel: ObservableObject {
    let helper = HelperManager()
    let schedule = ScheduleManager()
    let registry = ContentTypeRegistry()
    private let detector = WorkspaceProcessDetector()
    private let store = JobStore.standard()

    @Published var jobs: [BackupJob] = []
    @Published var targets: [Target] = []
    @Published var activity: [String] = []
    @Published var runningJobID: String?
    @Published var stage: BackupStage?
    @Published var lastResults: [String: RunResult] = [:]
    @Published var fullDiskAccess = false

    enum RunResult: Equatable { case verified(String), completed(String), deferred(String), failed(String) }

    init() {
        let pref = UserDefaults.standard.string(forKey: Prefs.archiveDir)
        let dir = (pref.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) })
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Cryoframe Archives", isDirectory: true)
        targets = [.localVolume(id: "local-default", name: dir.lastPathComponent, dir: dir)]
        jobs = store.load().jobs
        refreshDiskAccess()
    }

    func refreshDiskAccess() { fullDiskAccess = DiskAccess.hasFullDiskAccess() }

    // MARK: jobs / targets

    func addJob(_ job: BackupJob) { store.upsert(job); jobs = store.load().jobs }
    func deleteJob(_ id: String) { store.remove(id: id); jobs = store.load().jobs; lastResults[id] = nil }
    func addTarget(_ target: Target) { targets.removeAll { $0.id == target.id }; targets.append(target) }

    func owningAppRunning(_ type: ContentType) -> Bool { type.owningProcessRunning(detector) }

    func nextDue(_ job: BackupJob) -> Date? {
        let ref = store.load().lastRun[job.id] ?? job.createdAt
        return job.frequency.nextFireDate(after: ref)
    }

    // MARK: running

    func runNow(_ job: BackupJob) {
        guard runningJobID == nil else { return }
        runningJobID = job.id
        stage = .preparing
        lastResults[job.id] = nil
        log("▶ \(job.name)")

        Task {
            let runner = JobRunner(
                targeted: TargetedBackupRunner(backup: BackupRunner(helper: XPCPrivilegedHelper())),
                detector: detector, store: store)
            do {
                let result = try await runner.run(job, ownerUID: getuid(), now: Date(),
                    onStage: { s in Task { @MainActor in self.stage = s } })
                switch result {
                case .deferred(let reason):
                    log("⏸ \(job.name): \(reason)")
                    lastResults[job.id] = .deferred(reason)
                case .completed(let outcome, let warning):
                    if let warning { log("⚠︎ \(warning)") }
                    let count = outcome.result.artifacts.count
                    if let strong = outcome.strong {
                        if strong.passed {
                            log("✓ \(job.name): \(count) artifact(s), \(strong.details)")
                            lastResults[job.id] = .verified("\(count) artifact(s) · verified")
                        } else {
                            log("✗ \(job.name): verification FAILED — \(strong.details)")
                            lastResults[job.id] = .failed("verification failed")
                        }
                    } else {
                        log("✓ \(job.name): \(count) artifact(s) sealed")
                        lastResults[job.id] = .completed("\(count) artifact(s) sealed")
                    }
                }
            } catch {
                log("✗ \(job.name): \(error.localizedDescription)")
                lastResults[job.id] = .failed(error.localizedDescription)
            }
            jobs = store.load().jobs
            runningJobID = nil
            stage = nil
        }
    }

    private func log(_ line: String) {
        activity.insert(line, at: 0)
        if activity.count > 60 { activity.removeLast() }
    }
}

// MARK: - display helpers

extension BackupFrequency {
    var label: String {
        switch self {
        case .manual: return "Manual"
        case .oneTime(let d): return "Once · \(d.formatted(date: .abbreviated, time: .shortened))"
        case .everyHours(let h): return "Every \(h)h"
        case .daily(let h, let m): return String(format: "Daily · %02d:%02d", h, m)
        }
    }
}

extension FormatChoice {
    var label: String {
        switch self {
        case .sealedDMG: return "Sealed DMG"
        case .sealedZip: return "Sealed zip"
        case .liveMirror(let g): return "Live mirror · \(g)GB"
        }
    }
}
