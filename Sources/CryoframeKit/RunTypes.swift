//
//  RunTypes.swift
//  CryoframeKit
//
//  Small shared value types for a backup run: how thoroughly to verify, and the
//  coarse phase a run is in (surfaced to the UI). The run itself lives in
//  JobExecutor.
//

import Foundation

public enum VerificationPolicy: String, Codable, Sendable {
    case checksumOnly      // manifest written (always); cheap
    case mountAndOpen      // also mount the archive and confirm the library reopens
}

/// coarse phase progress for the UI (the engines run synchronously).
public enum BackupStage: String, Sendable {
    case preparing, archiving, checksumming, verifying, transferring, completed
}
