//
//  SnapshotLedger.swift
//  CryoframeKit
//
//  Crash-safe record of snapshots THIS helper created. Because tmutil snapshots
//  live in Time Machine's namespace, names alone can't distinguish ours from
//  TM's — the ledger is the ownership boundary. reconcile-on-launch deletes only
//  ledger-recorded names, so it can never purge a Time Machine snapshot.
//

import Foundation

public final class SnapshotLedger: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    public init(path: String) { self.url = URL(fileURLWithPath: path) }

    public func record(_ name: String) {
        mutate { $0.insert(name) }
    }
    public func forget(_ name: String) {
        mutate { $0.remove(name) }
    }
    public func all() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return load()
    }

    private func mutate(_ change: (inout Set<String>) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var set = load()
        change(&set)
        save(set)
    }

    private func load() -> Set<String> {
        guard let data = try? Data(contentsOf: url),
              let names = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(names)
    }

    private func save(_ set: Set<String>) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(set.sorted()) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
