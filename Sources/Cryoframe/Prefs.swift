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
    static let mirrorGB = "default.mirrorGB"      // Int
}
