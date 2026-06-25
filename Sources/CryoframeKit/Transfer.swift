//
//  Transfer.swift
//  CryoframeKit
//
//  Resumable shipping of a staged sealed archive to a fragile target (network
//  share, external drive). The archive is built locally as a single file; the
//  shipper streams it to the target as numbered 2 GB parts and can resume from
//  the first missing part after a disconnect. See docs/M-transfers-design.md.
//

import Foundation
import CryptoKit

public struct PendingTransfer: Codable, Sendable, Identifiable {
    public var id: String { jobID }
    public var jobID: String
    public var sourceFile: String      // staged single archive (local scratch)
    public var baseName: String        // e.g. "Photos Library.photoslibrary.dmg"
    public var totalBytes: UInt64
    public var chunkSize: UInt64
    public var targetDir: String
    public var format: ArchiveFormat
    public var encrypted: Bool               // the staged archive is AES-256 encrypted
    public var completed: [ArtifactDigest]   // parts already shipped, in order

    public var totalParts: Int { Int((totalBytes + chunkSize - 1) / max(chunkSize, 1)) }

    public init(jobID: String, sourceFile: String, baseName: String, totalBytes: UInt64,
                chunkSize: UInt64, targetDir: String, format: ArchiveFormat,
                encrypted: Bool = false, completed: [ArtifactDigest] = []) {
        self.jobID = jobID; self.sourceFile = sourceFile; self.baseName = baseName
        self.totalBytes = totalBytes; self.chunkSize = chunkSize; self.targetDir = targetDir
        self.format = format; self.encrypted = encrypted; self.completed = completed
    }

    public init(from decoder: Decoder) throws {       // tolerate records written before `encrypted` existed
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jobID = try c.decode(String.self, forKey: .jobID)
        sourceFile = try c.decode(String.self, forKey: .sourceFile)
        baseName = try c.decode(String.self, forKey: .baseName)
        totalBytes = try c.decode(UInt64.self, forKey: .totalBytes)
        chunkSize = try c.decode(UInt64.self, forKey: .chunkSize)
        targetDir = try c.decode(String.self, forKey: .targetDir)
        format = try c.decode(ArchiveFormat.self, forKey: .format)
        encrypted = try c.decodeIfPresent(Bool.self, forKey: .encrypted) ?? false
        completed = try c.decodeIfPresent([ArtifactDigest].self, forKey: .completed) ?? []
    }
}

public final class PendingTransferStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    public init(url: URL) { self.url = url }

    public static func standard() -> PendingTransferStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.cryoframe", isDirectory: true)
        return PendingTransferStore(url: base.appendingPathComponent("pending-transfers.json"))
    }

    public func all() -> [PendingTransfer] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([PendingTransfer].self, from: data) else { return [] }
        return list
    }

    public func save(_ transfer: PendingTransfer) {
        lock.lock(); defer { lock.unlock() }
        var list = (try? JSONDecoder().decode([PendingTransfer].self, from: (try? Data(contentsOf: url)) ?? Data())) ?? []
        list.removeAll { $0.jobID == transfer.jobID }
        list.append(transfer)
        write(list)
    }

    public func remove(jobID: String) {
        lock.lock(); defer { lock.unlock() }
        var list = (try? JSONDecoder().decode([PendingTransfer].self, from: (try? Data(contentsOf: url)) ?? Data())) ?? []
        list.removeAll { $0.jobID == jobID }
        write(list)
    }

    private func write(_ list: [PendingTransfer]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(list) { try? data.write(to: url, options: .atomic) }
    }
}

public struct ChunkedShipper: Sendable {
    public init() {}

    public static func partName(_ base: String, _ index: Int) -> String {
        "\(base).part.\(String(format: "%03d", index))"
    }

    /// ship the staged archive as numbered parts into the target, resuming from
    /// `pending.completed`. Persists progress after each part. Writes the per-part
    /// manifest last (its presence marks the archive complete). Throws if the
    /// target becomes unreachable mid-part — the saved progress lets a later run
    /// pick up from the next part.
    @discardableResult
    public func ship(_ pending: PendingTransfer,
                     persist: @Sendable (PendingTransfer) -> Void,
                     control: RunControl? = nil,
                     onPart: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil) throws -> VerificationManifest {
        var state = pending
        let fm = FileManager.default
        let targetDir = URL(fileURLWithPath: state.targetDir)
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)

        let reader = try FileHandle(forReadingFrom: URL(fileURLWithPath: state.sourceFile))
        defer { try? reader.close() }
        let bufferSize = 8 * 1024 * 1024

        for index in state.completed.count..<state.totalParts {
            control?.waitWhilePaused()
            if control?.isCancelled == true { throw CancelledError() }
            let partName = Self.partName(state.baseName, index)
            let finalURL = targetDir.appendingPathComponent(partName)
            let tmpURL = targetDir.appendingPathComponent(partName + ".cryoframe-tmp")
            try? fm.removeItem(at: tmpURL)
            fm.createFile(atPath: tmpURL.path, contents: nil)
            let writer = try FileHandle(forWritingTo: tmpURL)

            try reader.seek(toOffset: UInt64(index) * state.chunkSize)
            var remaining = Int(min(state.chunkSize, state.totalBytes - UInt64(index) * state.chunkSize))
            var hasher = SHA256()
            while remaining > 0 {
                let chunk = try reader.read(upToCount: min(bufferSize, remaining)) ?? Data()
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
                try writer.write(contentsOf: chunk)
                remaining -= chunk.count
            }
            try writer.close()
            try? fm.removeItem(at: finalURL)
            try fm.moveItem(at: tmpURL, to: finalURL)   // a final-named part is always whole

            let size = (try? fm.attributesOfItem(atPath: finalURL.path)[.size]) as? UInt64 ?? 0
            let sha = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            state.completed.append(ArtifactDigest(name: partName, size: size, sha256: sha))
            persist(state)
            onPart?(state.completed.count, state.totalParts)
        }

        let manifest = VerificationManifest(format: state.format, artifacts: state.completed,
                                            encrypted: state.encrypted ? true : nil)
        try ArchiveManifest.write(manifest, toDir: targetDir)   // completion marker, written last
        return manifest
    }
}

/// resumes interrupted transfers whose target is reachable again. Call on app
/// launch and on each scheduled tick — the same reconnect pattern as snapshot reconcile.
public enum TransferResumer {
    @discardableResult
    public static func resumeAll(store: PendingTransferStore,
                                 reachable: @Sendable (String) -> Bool = {
                                     var dir: ObjCBool = false
                                     return FileManager.default.fileExists(atPath: $0, isDirectory: &dir)
                                         && FileManager.default.isWritableFile(atPath: $0)
                                 }) -> [String] {
        var resumed: [String] = []
        let fm = FileManager.default
        for pending in store.all() {
            guard fm.fileExists(atPath: pending.sourceFile), reachable(pending.targetDir) else { continue }
            do {
                _ = try ChunkedShipper().ship(pending, persist: { store.save($0) })
                try? fm.removeItem(at: URL(fileURLWithPath: pending.sourceFile).deletingLastPathComponent())
                store.remove(jobID: pending.jobID)
                resumed.append(pending.jobID)
            } catch {
                // target dropped again — leave the record, retry next launch/tick
            }
        }
        return resumed
    }
}
