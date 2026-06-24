//
//  LibraryTemplate.swift
//  CryoframeKit
//
//  Pro libraries (Final Cut, Lightroom, Capture One) live anywhere — often on
//  external drives — so a fixed-path built-in won't find them. A template knows
//  the owning app and integrity probe; the user supplies the path. Better than a
//  plain folder, which has no owning-process warning and no DB check.
//

import Foundation

public struct LibraryTemplate: Sendable, Identifiable, Equatable {
    public let id: String
    public let displayName: String
    public let owningProcess: OwningProcess?
    public let integrityProbe: String?
    public let kind: ContentKind

    /// build a concrete content type by attaching a user-picked path.
    public func contentType(id: String, displayName: String, path: LibraryPath) -> ContentType {
        ContentType(id: id, displayName: displayName, paths: [path],
                    owningProcess: owningProcess, kind: kind, integrityProbe: integrityProbe)
    }
}

public extension LibraryTemplate {
    static let finalCutPro = LibraryTemplate(
        id: "finalcut", displayName: "Final Cut Pro library",
        owningProcess: OwningProcess(displayName: "Final Cut Pro",
                                     bundleIdentifier: "com.apple.FinalCut", executableName: "Final Cut Pro"),
        integrityProbe: nil, kind: .liveDB)

    static let lightroom = LibraryTemplate(
        id: "lightroom", displayName: "Lightroom Classic catalog",
        owningProcess: OwningProcess(displayName: "Lightroom Classic",
                                     bundleIdentifier: "com.adobe.LightroomClassicCC7",
                                     executableName: "Adobe Lightroom Classic"),
        integrityProbe: nil, kind: .liveDB)

    static let captureOne = LibraryTemplate(
        id: "captureone", displayName: "Capture One catalog",
        owningProcess: OwningProcess(displayName: "Capture One",
                                     bundleIdentifier: "com.captureone.captureone16",
                                     executableName: "Capture One"),
        integrityProbe: nil, kind: .liveDB)

    static let logicPro = LibraryTemplate(
        id: "logic", displayName: "Logic Pro project",
        owningProcess: OwningProcess(displayName: "Logic Pro",
                                     bundleIdentifier: "com.apple.logic10", executableName: "Logic Pro"),
        integrityProbe: nil, kind: .staticContent)

    static let all: [LibraryTemplate] = [.finalCutPro, .lightroom, .captureOne, .logicPro]
}
