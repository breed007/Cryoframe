//
//  BackupJob.swift
//  CryoframeKit
//
//  A self-contained, persistable backup job: a SET of libraries → one target,
//  with one schedule/format/verification. All selected libraries are archived
//  from a single APFS snapshot, so they're a consistent point-in-time set.
//

import Foundation

public enum RunPolicy: String, Codable, Sendable {
    case proceed          // snapshot is point-in-time consistent; run regardless (default)
    case warnIfRunning    // run, but surface that an owning app is open
    case deferIfRunning   // skip this fire while an owning app is open
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

/// decide how to handle a job given whether any selected library's owning app is running.
public func decide(_ policy: RunPolicy, libraries: [ContentType], detector: ProcessDetector) -> RunDecision {
    let open = libraries.compactMap(\.owningProcess).filter(detector.isRunning).map(\.displayName)
    switch policy {
    case .proceed:
        return .proceed
    case .warnIfRunning:
        return open.isEmpty ? .proceed
            : .proceedWithWarning("\(open.joined(separator: ", ")) open — snapshot is still point-in-time consistent")
    case .deferIfRunning:
        return open.isEmpty ? .proceed : .deferred("\(open.joined(separator: ", ")) open — deferring this run")
    }
}

public struct BackupJob: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public var name: String
    public var libraries: [ContentType]
    public var targets: [Target]        // one or more destinations; targets[0] is primary. Always non-empty.
    public var format: FormatChoice
    public var frequency: BackupFrequency
    public var verification: VerificationPolicy
    public var runPolicy: RunPolicy
    public var enabled: Bool            // false = paused (scheduler skips it; Run now still works)
    public var encrypted: Bool          // AES-256; passphrase lives in the Keychain, never in the job
    public var retention: RetentionPolicy   // version pruning for sealed archives (mirrors are single-copy)
    public var createdAt: Date

    /// the primary destination — the one a run must reach. Secondaries can fail to a
    /// partial-success without failing the whole run.
    public var target: Target { targets.first! }

    public init(id: String = UUID().uuidString, name: String,
                libraries: [ContentType], targets: [Target], format: FormatChoice,
                frequency: BackupFrequency, verification: VerificationPolicy = .checksumOnly,
                runPolicy: RunPolicy = .proceed, enabled: Bool = true, encrypted: Bool = false,
                retention: RetentionPolicy = .keepAll, createdAt: Date) {
        precondition(!targets.isEmpty, "a job needs at least one destination")
        self.id = id; self.name = name; self.libraries = libraries; self.targets = targets
        self.format = format; self.frequency = frequency; self.verification = verification
        self.runPolicy = runPolicy; self.enabled = enabled; self.encrypted = encrypted
        self.retention = retention; self.createdAt = createdAt
    }

    /// convenience for a single-destination job (most jobs, and the tests).
    public init(id: String = UUID().uuidString, name: String,
                libraries: [ContentType], target: Target, format: FormatChoice,
                frequency: BackupFrequency, verification: VerificationPolicy = .checksumOnly,
                runPolicy: RunPolicy = .proceed, enabled: Bool = true, encrypted: Bool = false,
                retention: RetentionPolicy = .keepAll, createdAt: Date) {
        self.init(id: id, name: name, libraries: libraries, targets: [target], format: format,
                  frequency: frequency, verification: verification, runPolicy: runPolicy,
                  enabled: enabled, encrypted: encrypted, retention: retention, createdAt: createdAt)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, libraries, contentType, target, targets, format, frequency, verification, runPolicy, enabled, encrypted, retention, createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        // migrate single-library jobs (pre-0.3.0) to a one-element set.
        if let libs = try c.decodeIfPresent([ContentType].self, forKey: .libraries) {
            libraries = libs
        } else {
            libraries = [try c.decode(ContentType.self, forKey: .contentType)]
        }
        // migrate single-target jobs (pre-1.1.0) to a one-element list.
        if let ts = try c.decodeIfPresent([Target].self, forKey: .targets), !ts.isEmpty {
            targets = ts
        } else {
            targets = [try c.decode(Target.self, forKey: .target)]
        }
        format = try c.decode(FormatChoice.self, forKey: .format)
        frequency = try c.decode(BackupFrequency.self, forKey: .frequency)
        verification = try c.decodeIfPresent(VerificationPolicy.self, forKey: .verification) ?? .checksumOnly
        runPolicy = try c.decodeIfPresent(RunPolicy.self, forKey: .runPolicy) ?? .proceed
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        encrypted = try c.decodeIfPresent(Bool.self, forKey: .encrypted) ?? false
        retention = try c.decodeIfPresent(RetentionPolicy.self, forKey: .retention) ?? .keepAll
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(libraries, forKey: .libraries)
        try c.encode(targets, forKey: .targets)
        try c.encode(targets[0], forKey: .target)   // also write the legacy key so an older build can still read the job
        try c.encode(format, forKey: .format)
        try c.encode(frequency, forKey: .frequency)
        try c.encode(verification, forKey: .verification)
        try c.encode(runPolicy, forKey: .runPolicy)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(encrypted, forKey: .encrypted)
        try c.encode(retention, forKey: .retention)
        try c.encode(createdAt, forKey: .createdAt)
    }

    /// re-resolve any built-in libraries to their current (possibly overridden) paths.
    public func resolvingLibraries(in registry: ContentTypeRegistry) -> BackupJob {
        var copy = self
        copy.libraries = libraries.map { registry.type(id: $0.id) ?? $0 }
        return copy
    }
}
