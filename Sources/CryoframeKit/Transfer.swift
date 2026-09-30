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
    /// The drive `targetDir` was on when the transfer began: its volume UUID (a
    /// share's address). Two drives of one name mount at one path, so the path alone
    /// can't say whether the drive plugged in now is the one holding the first parts.
    /// nil: recorded before 1.6, or on a volume that couldn't be told.
    public var volumeUUID: String?

    public var totalParts: Int { Int((totalBytes + chunkSize - 1) / max(chunkSize, 1)) }

    public init(jobID: String, sourceFile: String, baseName: String, totalBytes: UInt64,
                chunkSize: UInt64, targetDir: String, format: ArchiveFormat,
                encrypted: Bool = false, completed: [ArtifactDigest] = [], volumeUUID: String? = nil) {
        self.jobID = jobID; self.sourceFile = sourceFile; self.baseName = baseName
        self.totalBytes = totalBytes; self.chunkSize = chunkSize; self.targetDir = targetDir
        self.format = format; self.encrypted = encrypted; self.completed = completed
        self.volumeUUID = volumeUUID
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
        volumeUUID = try c.decodeIfPresent(String.self, forKey: .volumeUUID)
    }

    /// The job this transfer belongs to: records are keyed `<job>:<dest>:<lib>`
    /// (older ones just `<job>`).
    public var owningJobID: String {
        jobID.split(separator: ":", maxSplits: 1).first.map(String.init) ?? jobID
    }

    /// Whether `volume`, the volume holding `targetDir` now, is the drive the
    /// transfer began on. Unknown when it began (before 1.6): any volume is.
    public func isOnItsDrive(_ volume: MountedVolume?) -> Bool {
        guard let id = volumeUUID else { return true }
        guard let volume else { return false }
        return volume.uuid == id || volume.shareKey == id.lowercased()
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
    ///
    /// Parts recorded as sent are looked at first: from the first one that isn't
    /// there at its size (its folder was swept or made again), they are sent again.
    /// The manifest is written only over every part, each there at its size; if one
    /// went missing meanwhile this throws, and the version is never marked complete.
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

        if let gone = Self.firstMissingPart(state, in: targetDir) {
            state.completed.removeSubrange(gone...)
            persist(state)
        }

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
                // a part can be gigabytes on a slow share; don't make Stop wait it out
                if control?.isCancelled == true {
                    try? writer.close(); try? fm.removeItem(at: tmpURL)
                    throw CancelledError()
                }
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

        if let gone = Self.firstMissingPart(state, in: targetDir) {
            state.completed.removeSubrange(gone...)
            persist(state)
            throw TransferPartMissing(part: Self.partName(state.baseName, gone))
        }
        let manifest = VerificationManifest(format: state.format, artifacts: state.completed,
                                            encrypted: state.encrypted ? true : nil)
        try ArchiveManifest.write(manifest, toDir: targetDir)   // completion marker, written last
        return manifest
    }

    /// the index of the first part recorded as sent that isn't in `dir` as a file of
    /// its size; nil when every one is
    static func firstMissingPart(_ p: PendingTransfer, in dir: URL) -> Int? {
        for (i, part) in p.completed.enumerated() {
            let expected = min(p.chunkSize, p.totalBytes - min(p.totalBytes, UInt64(i) * p.chunkSize))
            let url = dir.appendingPathComponent(Self.partName(p.baseName, i))
            var st = stat()
            guard part.name == Self.partName(p.baseName, i), lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
                  UInt64(st.st_size) == expected, part.size == expected else { return i }
        }
        return nil
    }
}

/// A part an interrupted transfer had sent was gone when its last part was: the
/// version isn't complete, and the parts from it on are sent again next time.
public struct TransferPartMissing: Error, LocalizedError, Equatable {
    public var part: String
    public var errorDescription: String? { "\(part) went missing from the destination while the rest was being copied; it's copied again next time." }
}

/// resumes interrupted transfers whose target is reachable again. Call on app
/// launch and on each scheduled tick — the same reconnect pattern as snapshot reconcile.
public enum TransferResumer {
    /// what one pass over the pending transfers did.
    public struct Pass: Sendable, Equatable {
        /// pending-transfer records finished this pass
        public var resumed: [String] = []
        /// jobs whose resume was stopped this pass. Stop means "not now": the same pass
        /// must not go on to start a full run of the job instead.
        public var stoppedJobIDs: Set<String> = []
    }

    @discardableResult
    public static func resumeAll(store: PendingTransferStore,
                                 reachable: @Sendable (String) -> Bool = TransferResumer.isReachable,
                                 locks: RunLocks? = nil, volumes: VolumeTable = SystemVolumeTable(),
                                 afterPart: (@Sendable (RunLease) -> Void)? = nil) -> [String] {
        resume(store: store, reachable: reachable, locks: locks, volumes: volumes, afterPart: afterPart).resumed
    }

    @Sendable public static func isReachable(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &dir)
            && FileManager.default.isWritableFile(atPath: path)
    }

    /// Resume every interrupted transfer whose destination is reachable again, on the
    /// drive it began on: another drive of that name at the same path gets none of
    /// its parts (see PendingTransfer.volumeUUID).
    public static func resume(store: PendingTransferStore,
                              reachable: @Sendable (String) -> Bool = TransferResumer.isReachable,
                              locks: RunLocks? = nil, volumes: VolumeTable = SystemVolumeTable(),
                              afterPart: (@Sendable (RunLease) -> Void)? = nil) -> Pass {
        var resumed: [String] = []
        var stopped = Set<String>()          // jobs whose resume was stopped: none of theirs this pass
        let fm = FileManager.default
        for pending in store.all() {
            guard fm.fileExists(atPath: pending.sourceFile), reachable(pending.targetDir),
                  !stopped.contains(jobID(of: pending)),
                  pending.isOnItsDrive(volumes.volume(containing: URL(fileURLWithPath: pending.targetDir, isDirectory: true)))
            else { continue }
            // A job that is running right now, here or in the other process, is
            // shipping its own transfers; resuming alongside it writes the same parts
            // twice at once. Leave it to the run, or to the next pass.
            let lease: RunLease?
            if let locks {
                guard let held = try? locks.acquire(jobID: jobID(of: pending), trigger: .resume) else { continue }
                lease = held
            } else {
                lease = nil
            }
            defer { lease?.release() }
            // Stop, pressed in the app, reaches a resume like any run: the transfer
            // stops at the next block and its record stays for the next pass.
            let control = RunControl()
            lease?.onStopRequest { control.cancel() }
            do {
                _ = try ChunkedShipper().ship(pending, persist: { state in
                    store.save(state)
                    guard let lease else { return }
                    afterPart?(lease)                        // tests: act between parts
                    if lease.stopRequested { control.cancel() }
                }, control: control)
                store.remove(jobID: pending.jobID)
                // a multi-destination job stages ONE build for several resumable copies,
                // so several pendings can share a sourceFile. Only delete the scratch
                // artifact once no other pending still needs it — otherwise we orphan
                // the remaining destinations' transfers.
                let stillNeeded = store.all().contains { $0.sourceFile == pending.sourceFile }
                if !stillNeeded {
                    try? fm.removeItem(at: URL(fileURLWithPath: pending.sourceFile).deletingLastPathComponent())
                }
                resumed.append(pending.jobID)
            } catch is CancelledError {
                stopped.insert(jobID(of: pending))
            } catch {
                // target dropped again — leave the record, retry next launch/tick
            }
        }
        return Pass(resumed: resumed, stoppedJobIDs: stopped)
    }

    /// the job a pending transfer belongs to: records are keyed `<job>:<dest>:<lib>`
    /// (older ones just `<job>`).
    static func jobID(of pending: PendingTransfer) -> String { pending.owningJobID }
}
