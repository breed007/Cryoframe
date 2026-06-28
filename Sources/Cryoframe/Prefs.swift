//
//  Prefs.swift
//  Cryoframe (app)
//
//  UserDefaults keys for job-creation defaults set in Settings.
//

import Foundation

enum Prefs {
    static let format = "default.format"          // "dmg" | "zip" | "mirror"
    static let verify = "default.verify"          // VerificationPolicy.rawValue
    static let runPolicy = "default.runPolicy"    // RunPolicy.rawValue
    static let archiveDir = "default.archiveDir"  // absolute path
    static let mirrorGB = "default.mirrorGB"      // Int — mirror size value (paired with mirrorUnit)
    static let mirrorUnit = "default.mirrorUnit"  // "GB" | "TB", default "GB"
    static let libraryOverrides = "library.overrides"  // [contentTypeID: absolute path]
    static let transferChunkValue = "transfer.chunkValue"  // Int, default 2
    static let transferChunkUnit = "transfer.chunkUnit"    // "GB" | "TB", default "GB"
    static let scratchDir = "transfer.scratchDir"          // absolute path (empty = system cache)
    static let maxConcurrent = "run.maxConcurrent"         // Int, default 2
    static let keepAwake = "run.keepAwake"                 // Bool, default true — prevent idle sleep during a run
    static let wakeForSchedule = "run.wakeForSchedule"     // Bool, default false — pmset wake before a due job
    static let notifyPolicy = "run.notifyPolicy"           // "never" | "failure" | "all", default "failure"
    static let healthInterval = "health.interval"          // "off" | "weekly" | "monthly", default "off"
    static let lastHealthCheck = "health.lastCheck"        // Double epoch — when the agent last re-verified
    static let healthScope = "health.scope"                // "latest" | "all", default "latest"
    static let healthDepth = "health.depth"                // "checksum" | "drill", default "checksum"
    static let verifyCloudArchives = "health.verifyCloud"  // Bool, default false — download evicted cloud archives to check them
    static let remoteAlertType = "remote.alertType"        // "off" | "webhook" | "ntfy", default "off"
    static let remoteAlertURL = "remote.alertURL"          // webhook endpoint or ntfy topic URL
    static let remoteAlertEvents = "remote.alertEvents"    // "failure" | "all", default "failure"
}
