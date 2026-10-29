//
//  HistoryLockTests.swift
//  CryoframeKitTests
//
//  The app and the scheduled agent each hold their own run history and health
//  history store, on the same files. Each change is a read, a change and a write,
//  and a lock held only within one process let a run finishing in the app at the
//  moment one finished in the agent lose one of the two records (see SharedJSONFile).
//

import Testing
import Foundation
@testable import CryoframeKit

private let start = Date(timeIntervalSince1970: 1_790_000_000)

private func scratch(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cf-histlock-\(tag)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return TempTracker.track(d)
}

private func job(_ id: String) -> BackupJob {
    BackupJob(id: id, name: id,
              libraries: [.genericFolder(id: "/p", displayName: "Papers", path: .absolute("/p"))],
              target: .localVolume(id: "/Volumes/NAS/Backups", name: "NAS", dir: URL(fileURLWithPath: "/Volumes/NAS/Backups")),
              format: .sealedDMG, frequency: .daily(hour: 2, minute: 0), createdAt: start)
}

@Suite struct HistoryLockTests {
    // two instances share only the file lock, as the app and the agent do

    @Test func twoRunHistoryStoresOnOneFileLoseNoRecord() async {
        let url = scratch("runs").appendingPathComponent("run-history.json")
        let a = RunHistoryStore(url: url), b = RunHistoryStore(url: url)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<60 {
                let store = i.isMultiple(of: 2) ? a : b
                group.addTask {
                    if i.isMultiple(of: 3) {
                        store.recordDeferral(job: job("held-\(i)"), reason: "on battery", at: start)
                    } else {
                        store.append(.failure(job: job("job-\(i)"), error: "failed", startedAt: start, finishedAt: start,
                                              trigger: "scheduled", id: "r\(i)"))
                    }
                }
            }
        }
        #expect(RunHistoryStore(url: url).all().count == 60)
    }

    @Test func twoHealthStoresOnOneFileLoseNoRecord() async {
        let url = scratch("health").appendingPathComponent("archive-health.json")
        let a = HealthStore(url: url), b = HealthStore(url: url)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<60 {
                let store = i.isMultiple(of: 2) ? a : b
                group.addTask {
                    store.append(HealthRecord(id: "h\(i)", jobID: "job-1", jobName: "Papers", checkedAt: start,
                                              archivesChecked: 1, failures: []))
                }
            }
        }
        #expect(HealthStore(url: url).all().count == 60)
    }

    @Test func aDeferralAlertMarkedInOneStoreIsSeenByTheOther() {
        let url = scratch("pending").appendingPathComponent("run-history.json")
        let a = RunHistoryStore(url: url), b = RunHistoryStore(url: url)
        let (record, _) = a.recordDeferral(job: job("job-1"), reason: "on battery", at: start)
        b.setDeferralAlertPending(recordID: record.id, true)
        #expect(a.all().first?.deferralAlertPending == true)
        #expect(a.recordDeferral(job: job("job-1"), reason: "on battery", at: start.addingTimeInterval(3600)).count == 2)
    }
}
