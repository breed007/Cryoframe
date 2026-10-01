//
//  TransferConfig.swift
//  Cryoframe (app)
//
//  Reads the resumable-transfer settings (chunk size, scratch location) for the
//  runner and the scheduled agent.
//

import Foundation
import CryoframeKit

enum TransferConfig {
    static func chunkSize() -> UInt64 {
        let d = UserDefaults.standard
        let value = d.integer(forKey: Prefs.transferChunkValue)
        let n = UInt64(value > 0 ? value : 2)
        let unit = d.string(forKey: Prefs.transferChunkUnit) ?? "GB"
        return n * (unit == "TB" ? 1_000_000_000_000 : 1_000_000_000)
    }

    static func scratchBase() -> URL {
        if let path = UserDefaults.standard.string(forKey: Prefs.scratchDir), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return defaultScratchBase()
    }

    /// the system cache on the startup disk: where an encrypted job's plaintext copy
    /// of a folder is made, whatever Settings names (see JobExecutor.plaintextScratch)
    static func defaultScratchBase() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.cryoframe/scratch", isDirectory: true)
    }

    /// every place a build can leave something in, for the sweep at launch
    static func scratchBases() -> [URL] {
        scratchBase().standardizedFileURL == defaultScratchBase().standardizedFileURL ? [scratchBase()]
            : [scratchBase(), defaultScratchBase()]
    }

    static func maxConcurrentJobs() -> Int {
        let n = UserDefaults.standard.integer(forKey: Prefs.maxConcurrent)
        return n > 0 ? n : 2
    }

    /// battery level below which scheduled runs wait. 0 disables the check.
    /// Unset (the common case) means the default floor, not "off".
    static func batteryFloorPercent() -> Int {
        guard UserDefaults.standard.object(forKey: Prefs.batteryFloor) != nil else {
            return BatteryPolicy.defaultMinimumPercent
        }
        return UserDefaults.standard.integer(forKey: Prefs.batteryFloor)
    }

    /// a job executor configured with the resumable-transfer settings. Used by
    /// both the GUI and the scheduled agent.
    static func makeExecutor(detector: ProcessDetector, store: JobStore) -> JobExecutor {
        JobExecutor(helper: XPCPrivilegedHelper(),
                    detector: detector,
                    scratchBase: scratchBase(),
                    plaintextScratch: defaultScratchBase(),
                    chunkSize: chunkSize(),
                    pendingStore: PendingTransferStore.standard(),
                    jobStore: store,
                    passphraseProvider: { KeychainArchiveKey.load(jobID: $0) },
                    healthRecords: { HealthStore.standard().all() },
                    runHistory: { RunHistoryStore.standard().all() })
    }
}
