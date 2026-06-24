//
//  BackupJob.swift
//  CryoframeKit
//
//  A self-contained, persistable backup job (content type + target + format +
//  schedule). RunPolicy decides what to do when the owning app is open — the
//  snapshot makes quiescing largely unnecessary, so the default is to proceed.
//

import Foundation

public enum RunPolicy: String, Codable, Sendable {
    case proceed          // snapshot is point-in-time consistent; run regardless (default)
    case warnIfRunning    // run, but surface that the owning app is open
    case deferIfRunning   // skip this fire while the owning app is open
}

public enum RunDecision: Sendable, Equatable {
    case proceed
    case proceedWithWarning(String)
    case deferred(String)

    public var warning: String? {
        if case .proceedWithWarning(let w) = self { return w }
        return nil
    }
}

/// decide how to handle a job given whether its owning app is currently running.
public func decide(_ policy: RunPolicy, type: ContentType, detector: ProcessDetector) -> RunDecision {
    let running = type.owningProcessRunning(detector)
    let owner = type.owningProcess?.displayName ?? type.displayName
    switch policy {
    case .proceed:
        return .proceed
    case .warnIfRunning:
        return running ? .proceedWithWarning("\(owner) is open — snapshot is still point-in-time consistent")
                       : .proceed
    case .deferIfRunning:
        return running ? .deferred("\(owner) is open — deferring this run") : .proceed
    }
}

public struct BackupJob: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public var name: String
    public var contentType: ContentType
    public var target: Target
    public var format: FormatChoice
    public var frequency: BackupFrequency
    public var verification: VerificationPolicy
    public var runPolicy: RunPolicy
    public var createdAt: Date

    public init(id: String = UUID().uuidString, name: String,
                contentType: ContentType, target: Target, format: FormatChoice,
                frequency: BackupFrequency, verification: VerificationPolicy = .checksumOnly,
                runPolicy: RunPolicy = .proceed, createdAt: Date) {
        self.id = id; self.name = name; self.contentType = contentType; self.target = target
        self.format = format; self.frequency = frequency; self.verification = verification
        self.runPolicy = runPolicy; self.createdAt = createdAt
    }

    /// if this job targets a built-in library, use its current (possibly
    /// overridden) descriptor rather than the one captured when the job was made.
    /// Generic-folder and template jobs (not in the registry) are left as-is.
    public func resolvingContentType(in registry: ContentTypeRegistry) -> BackupJob {
        guard let resolved = registry.type(id: contentType.id) else { return self }
        var copy = self
        copy.contentType = resolved
        return copy
    }
}
