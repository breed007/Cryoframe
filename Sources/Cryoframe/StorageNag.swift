//
//  StorageNag.swift
//  Cryoframe (app)
//
//  A destination stays full until someone does something about it, and the agent
//  wakes every hour. Without a memory that would be twenty-four warnings a day for
//  one problem, which is how people learn to ignore the channel.
//

import Foundation

enum StorageNag {
    private static let key = "storage.lastWarned"          // destination name → epoch seconds
    private static let interval: TimeInterval = 24 * 60 * 60

    static func shouldWarn(_ destination: String, now: Date) -> Bool {
        let map = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        guard let last = map[destination] else { return true }
        return now.timeIntervalSince1970 - last >= interval
    }

    static func recordWarned(_ destination: String, now: Date) {
        var map = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        map[destination] = now.timeIntervalSince1970
        UserDefaults.standard.set(map, forKey: key)
    }
}
