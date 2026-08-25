//
//  DiskImageGate.swift
//  CryoframeKit
//
//  `hdiutil attach` is not safely concurrent. Ask two of them to run at the same
//  moment and one comes back EAGAIN — "Resource temporarily unavailable" — which
//  reads to everything upstream as "this archive won't open."
//
//  That matters because Cryoframe runs jobs concurrently (two by default). Two jobs
//  each finishing with a mount-and-open verification, or a live-mirror job attaching
//  its sparsebundle while a health check attaches an archive, is an ordinary Tuesday
//  — and the loser gets told a perfectly good archive is broken. Retrying alone does
//  not fix it: under sustained contention the whole retry budget can expire.
//
//  So attaches queue. Only the attach call is held, not the mounted lifetime, so
//  verification and restore still overlap freely once each image is up.
//

import Foundation

public enum DiskImageGate {
    private static let semaphore = DispatchSemaphore(value: 1)

    /// run one `hdiutil attach` at a time, process-wide.
    public static func serialized<T>(_ body: () throws -> T) rethrows -> T {
        semaphore.wait()
        defer { semaphore.signal() }
        return try body()
    }
}
