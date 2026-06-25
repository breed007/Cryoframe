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
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.cryoframe/scratch", isDirectory: true)
    }

    static func maxConcurrentJobs() -> Int {
        let n = UserDefaults.standard.integer(forKey: Prefs.maxConcurrent)
        return n > 0 ? n : 2
    }

    /// a job executor configured with the resumable-transfer settings. Used by
    /// both the GUI and the scheduled agent.
    static func makeExecutor(detector: ProcessDetector, store: JobStore) -> JobExecutor {
        JobExecutor(helper: XPCPrivilegedHelper(),
                    detector: detector,
                    scratchBase: scratchBase(),
                    chunkSize: chunkSize(),
                    pendingStore: PendingTransferStore.standard(),
                    jobStore: store)
    }
}
