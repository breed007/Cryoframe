//
//  XPCPrivilegedHelper.swift
//  Cryoframe (app)
//
//  The real PrivilegedHelper: an async adapter over NSXPCConnection to the root
//  daemon. Same protocol SnapshotCoordinator already drives, so the app's
//  lifecycle logic is identical whether backed by this or FakePrivilegedHelper.
//

import Foundation
import CryoframeShared

enum XPCClientError: Error { case proxyUnavailable }

final class XPCPrivilegedHelper: PrivilegedHelper, @unchecked Sendable {
    private let connection: NSXPCConnection

    init() {
        connection = NSXPCConnection(machServiceName: CryoframeHelper.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: CryoframeHelperXPC.self)
        // only talk to our signed helper (enforced at call time).
        connection.setCodeSigningRequirement(CryoframeHelper.helperRequirement)
        connection.resume()
    }

    func invalidate() { connection.invalidate() }

    // MARK: PrivilegedHelper

    func handshake() async throws -> HelperInfo {
        try await call { $0.handshake(reply: $1) }
    }
    func createSnapshot(on volume: VolumeRef) async throws -> SnapshotRef {
        let v = try Wire.encode(volume)
        return try await call { $0.createSnapshot(volume: v, reply: $1) }
    }
    func mountSnapshot(_ snapshot: SnapshotRef, ownerUID: uid_t) async throws -> MountRef {
        let s = try Wire.encode(snapshot)
        return try await call { $0.mountSnapshot(snapshot: s, ownerUID: ownerUID, reply: $1) }
    }
    func unmount(_ mount: MountRef) async throws {
        let m = try Wire.encode(mount)
        try await callVoid { $0.unmount(mount: m, reply: $1) }
    }
    func deleteSnapshot(_ snapshot: SnapshotRef) async throws {
        let s = try Wire.encode(snapshot)
        try await callVoid { $0.deleteSnapshot(snapshot: s, reply: $1) }
    }
    func listSnapshots(on volume: VolumeRef) async throws -> [SnapshotRef] {
        let v = try Wire.encode(volume)
        return try await call { $0.listSnapshots(volume: v, reply: $1) }
    }
    func reconcile() async throws -> ReconcileReport {
        try await call { $0.reconcile(reply: $1) }
    }
    func mountNetworkTarget(_ spec: NetworkTargetSpec) async throws -> MountRef {
        let s = try Wire.encode(spec)
        return try await call { $0.mountNetworkTarget(spec: s, reply: $1) }
    }

    // MARK: continuation plumbing (single-resume guarded)

    private func call<T: Decodable & Sendable>(
        _ invoke: @escaping (CryoframeHelperXPC, @escaping (Data?, Error?) -> Void) -> Void
    ) async throws -> T {
        let once = ResumeOnce<T>()
        return try await withCheckedThrowingContinuation { cont in
            once.attach(cont)
            let proxy = connection.remoteObjectProxyWithErrorHandler { once.fail($0) }
            guard let helper = proxy as? CryoframeHelperXPC else {
                once.fail(XPCClientError.proxyUnavailable); return
            }
            invoke(helper) { data, error in
                if let error { once.fail(error); return }
                do { once.succeed(try Wire.decode(T.self, from: data)) }
                catch { once.fail(error) }
            }
        }
    }

    private func callVoid(
        _ invoke: @escaping (CryoframeHelperXPC, @escaping (Error?) -> Void) -> Void
    ) async throws {
        let once = ResumeOnce<Void>()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            once.attach(cont)
            let proxy = connection.remoteObjectProxyWithErrorHandler { once.fail($0) }
            guard let helper = proxy as? CryoframeHelperXPC else {
                once.fail(XPCClientError.proxyUnavailable); return
            }
            invoke(helper) { error in
                if let error { once.fail(error) } else { once.succeed(()) }
            }
        }
    }
}

/// guarantees a CheckedContinuation resumes exactly once even if both the proxy
/// error handler and the reply block fire. only Sendable values cross.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Error>?
    func attach(_ c: CheckedContinuation<T, Error>) { lock.lock(); cont = c; lock.unlock() }
    func succeed(_ value: T) { finish { $0.resume(returning: value) } }
    func fail(_ error: Error) { finish { $0.resume(throwing: error) } }
    private func finish(_ body: (CheckedContinuation<T, Error>) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard let c = cont else { return }
        cont = nil
        body(c)
    }
}
