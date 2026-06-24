//
//  Wire.swift
//  CryoframeShared
//
//  XPC payloads cross as JSON Data so the @objc wire protocol stays tiny and we
//  reuse the Codable value types. Also the connection-trust requirement strings:
//  each side verifies the other's code signature (same Team ID + expected identifier).
//

import Foundation

public enum Wire {
    // fresh coders per call — no shared mutable state under strict concurrency.
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data?) throws -> T {
        try JSONDecoder().decode(type, from: data ?? Data())
    }
}

public extension CryoframeHelper {
    static let teamID = "YA83Q8FTH3"           // Brian Reed — Developer ID

    /// the daemon (root) accepts connections only from our signed app.
    static let clientRequirement =
        #"identifier "app.cryoframe" and anchor apple generic and certificate leaf[subject.OU] = "YA83Q8FTH3""#

    /// the app connects only to our signed helper.
    static let helperRequirement =
        #"identifier "app.cryoframe.helper" and anchor apple generic and certificate leaf[subject.OU] = "YA83Q8FTH3""#

    /// plist filename registered via SMAppService.daemon(plistName:).
    static let daemonPlistName = "app.cryoframe.helper.plist"
}
