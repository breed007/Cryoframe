//
//  PassphraseEscrow.swift
//  CryoframeKit
//
//  The recovery file: every archive passphrase in one place, encrypted with a
//  master password, so encrypted backups survive the Mac that made them. On a new
//  Mac there are no jobs and an empty Keychain, so the file is matched back to
//  archives by LIBRARY NAME — which makes how those names are stored load-bearing.
//
//  They used to be stored as one comma-joined string and split back apart on
//  import. A library whose own name contained a comma ("Client Work, 2026" — a
//  perfectly ordinary folder name, and custom libraries take their name from the
//  folder) came back as two names, neither of which matched anything, so that
//  library could never be unlocked. Names are a list now. The joined string is
//  still written so a file made here stays readable by older builds, and still
//  read as a fallback so their files stay readable here.
//

import Foundation

public enum PassphraseEscrow {

    public struct Entry: Codable, Identifiable, Sendable, Equatable {
        public var id = UUID()
        public var jobName: String
        /// the libraries this passphrase opens.
        public var libraries: [String]
        public var passphrase: String

        /// for display, and for the legacy `library` key on the wire.
        public var libraryList: String { libraries.joined(separator: ", ") }

        public init(jobName: String, libraries: [String], passphrase: String) {
            self.jobName = jobName; self.libraries = libraries; self.passphrase = passphrase
        }

        enum CodingKeys: String, CodingKey { case jobName, libraries, library, passphrase }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            jobName = try c.decode(String.self, forKey: .jobName)
            passphrase = try c.decode(String.self, forKey: .passphrase)
            if let list = try c.decodeIfPresent([String].self, forKey: .libraries) {
                libraries = list
            } else {
                // pre-1.5 file: one joined string, so a comma inside a name is
                // ambiguous and always was. Split it and accept the old behaviour.
                let joined = try c.decodeIfPresent(String.self, forKey: .library) ?? ""
                libraries = joined.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(jobName, forKey: .jobName)
            try c.encode(libraries, forKey: .libraries)
            try c.encode(libraryList, forKey: .library)   // legacy key, for older builds
            try c.encode(passphrase, forKey: .passphrase)
        }
    }

    // MARK: - file

    public static func exportData(_ entries: [Entry], password: String) -> Data? {
        guard let json = try? JSONEncoder().encode(entries) else { return nil }
        return EscrowCrypto.encrypt(json, password: password)
    }

    public static func importEntries(_ data: Data, password: String) -> [Entry]? {
        guard let json = EscrowCrypto.decrypt(data, password: password) else { return nil }
        return try? JSONDecoder().decode([Entry].self, from: json)
    }

    // MARK: - matching archives to keys

    /// library name → passphrase, which is what recovery needs: it has archives on
    /// disk named by library and no jobs to match ids against. When two entries
    /// claim the same library the first wins, so the newest export should be first.
    public static func passphrasesByLibrary(_ entries: [Entry]) -> [String: String] {
        var map: [String: String] = [:]
        for e in entries {
            for lib in e.libraries where !lib.isEmpty {
                if map[lib] == nil { map[lib] = e.passphrase }
            }
        }
        return map
    }
}
