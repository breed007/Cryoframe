# M1 design — helper, XPC contract, privilege boundary

**Status: CHECKPOINT. Review before I build the helper.** This documents the
privilege split and the XPC contract. No helper implementation exists yet.

Contract as code: [`Sources/CryoframeShared/PrivilegedHelper.swift`](../Sources/CryoframeShared/PrivilegedHelper.swift).

---

## 1. Privilege boundary (the thing to scrutinize)

M0 proved the load-bearing constraint: **root does not bypass TCC for Photos
content.** A non-FDA process gets `Operation not permitted` on `ls` of a
`.photoslibrary`; root-ness doesn't change that. So the two privileges are
orthogonal and must not collapse into "run everything as root."

| Capability | Who holds it | Process | Why there |
|---|---|---|---|
| Full Disk Access | GUI app / reader **and the helper** | `app.cryoframe` (user) + `app.cryoframe.helper` (daemon) | TCC gates both *reading* library content (app) and *mounting* the Data-volume snapshot via `mount_apfs` (helper). Root alone does not clear either. |
| root | helper only | `app.cryoframe.helper` (LaunchDaemon) | snapshot create/mount/delete + network mounts. |

**CORRECTION (proven in M1 live run):** the helper is NOT FDA-free. `mount_apfs`
on a Data-volume snapshot is itself TCC-gated — the first live run failed with
`mount_apfs: Operation not permitted` from the root daemon until Full Disk Access
was active. The fix is clean for UX: the daemon plist's
`AssociatedBundleIdentifiers = [app.cryoframe]` makes the daemon **ride the app's
single FDA grant**, so the user grants FDA once (to the app) and both the mount
(helper) and the read (app) are covered by the user's single grant to the app.

**Who reads the frozen tree → the GUI/reader, never the helper.** The helper
creates and mounts the snapshot, then hands back a `MountRef`. The FDA user
process walks `<mount>/Users/<you>/Pictures/<lib>` and builds the archive. The
helper mounts but never *opens* library files — reading stays on the app side.

```
  GUI (user, FDA)                         helper (root, no FDA)
  ───────────────                         ─────────────────────
  reconcile()            ───XPC──▶        sweep orphan mounts + app.cryoframe.snap.*
  createSnapshot(Data)   ───XPC──▶        fs_snapshot_create
  mountSnapshot(..,uid)  ───XPC──▶        fs_snapshot_mount ro, chown/chmod mountpoint
        ◀── MountRef ─────────────
  walk tree, ditto/zip/dmg  ◀── reads frozen library directly (FDA satisfies TCC)
  unmount(MountRef)      ───XPC──▶        umount
  deleteSnapshot(ref)    ───XPC──▶        fs_snapshot_delete  (prefix-guarded)
```

### The one unproven assumption — M1's cheap de-risk (do FIRST)

M0 had root do *both* the mount and the read. We have **not** proven the split
case: **can a user-level FDA process read a snapshot that root mounted?** Two
things must both hold:

1. **Filesystem traversal** — the mountpoint and its parents must be traversable
   by the user. Plan: helper mounts under `/private/var/run/app.cryoframe/mnt/<ts>`
   with parent dirs `0755`. Snapshot content keeps original ownership, so
   `/Users/<you>` is already user-readable.
2. **TCC attribution** — FDA is granted to `app.cryoframe`; the read happens
   *in* that process, so TCC should allow it regardless of who mounted. Needs
   confirmation in practice.

This is the M0-equivalent gate for M1. Proposed spike: extend the M0 script to
`KEEP=1` the mount, then read the frozen library from a *separate, non-root*
FDA-granted binary. If that reads clean, the boundary is sound and I build the
helper. If TCC blocks it, we rethink (e.g. an FDA-holding XPC reader service
that the helper launches in the user context) **before** writing helper code.

---

## 2. Snapshot create backend — swappable (UPDATED after de-risk)

**De-risk finding (2026-06-24):** `fs_snapshot_create` as plain root returns
**EPERM**. The original premise — "root sidesteps the restricted entitlement" —
is wrong. Snapshot *create* is gated by the Apple-restricted
`com.apple.developer.vfs.snapshot` entitlement (kernel checks
`com.apple.private.vfs.snapshot`, held only by Apple platform binaries). It's
granted only via a DTS request to backup apps after code review. By contrast,
`fs_snapshot_mount` and `fs_snapshot_delete` of an *existing* snapshot work as
root with no entitlement — which is why M0 worked (created via `tmutil`, mounted
via `mount_apfs`).

**Decision (2026-06-24): ship on tmutil only; entitlement track dropped.**
`fs_snapshot_create` is not worth the Apple DTS review for a free OSS app, and
the syscall path's only real advantage (owned namespace) is moot once we mount-
pin against purge. `FSSnapshotBackend` stays as a documented stub behind the seam
but is not pursued — no DTS request, no provisioning profile. (The entitlement
would not enable Mac App Store distribution anyway: the root daemon + FDA +
arbitrary-target writes are App-Sandbox-incompatible, which is why "Not MAS" is
locked regardless.) The create backend remains a protocol so the option stays open:

```
protocol SnapshotBackend {           // lives helper-side, behind PrivilegedHelper
    func create(on: VolumeRef) throws -> SnapshotRef
    func mount(_:, at:, flags:) throws -> MountRef
    func list(on: VolumeRef) throws -> [SnapshotRef]
    func delete(_: SnapshotRef) throws
}
```

| Step | `TMUtilSnapshotBackend` (ships now, no entitlement) | `FSSnapshotBackend` (drop-in IF Apple grants entitlement) |
|---|---|---|
| create | `tmutil localsnapshot /` → identify ours by set-diff, record date | `fs_snapshot_create(dirfd, "app.cryoframe.snap.<ts>", 0)` |
| mount ro | `mount_apfs -o rdonly -s <name> <dev> <mnt>` | `fs_snapshot_mount(dirfd, mnt, name, DONTBROWSE\|NOSUID\|NODEV)` |
| list | `tmutil listlocalsnapshots /` | `fs_snapshot_list(dirfd, &attrlist, buf, len, 0)` |
| unmount | `unmount(mnt, 0)` | `unmount(mnt, 0)` |
| delete | `tmutil deletelocalsnapshots <date>` | `fs_snapshot_delete(dirfd, name, 0)` |

The `PrivilegedHelper` XPC contract does **not** change between backends —
`SnapshotRef.name` just carries whatever the backend produced
(`com.apple.TimeMachine.<date>.local` vs `app.cryoframe.snap.<ts>`). Validated
syscall surface: [`spike/fs_snapshot_spike.c`](../spike/fs_snapshot_spike.c).

**Purge-under-pressure mitigation (the original objection to tmutil):** the
helper mounts the snapshot immediately after create; an active APFS mount pins
its data regardless of Time Machine's purgeable-namespace bookkeeping, and the
archive reads from the live mount, not the namespace entry. Exposed window =
the few ms between create and mount. As a belt-and-suspenders guard, the helper
re-confirms the mount is live before returning the `MountRef`.

**Delete guard:** `TMUtilSnapshotBackend` deletes only snapshot dates it
recorded in its own run state (never an arbitrary `com.apple.TimeMachine.*`).
`FSSnapshotBackend` refuses any name without the `app.cryoframe.snap.` prefix
(`HelperError.refusedForeignSnapshot`). Both are structurally unable to delete a
foreign / Time Machine snapshot.

---

## 3. XPC contract

Mirrors Crossbar's `PrivilegedToggle`: a Swift `PrivilegedHelper` protocol is
the swappable seam. Two impls — `XPCPrivilegedHelper` (wraps `NSXPCConnection`)
and `FakePrivilegedHelper` (in-memory, lets the lifecycle be unit-tested with no
root). The wire face is `@objc CryoframeHelperXPC` with reply blocks; Codable
payloads cross as `Data`. Full surface in the contract file. Operations:

`handshake · createSnapshot · mountSnapshot · unmount · deleteSnapshot · listSnapshots · reconcile · mountNetworkTarget`

`mountNetworkTarget` is declared now (used at M5) so the wire contract is frozen
early. `handshake` does version negotiation — GUI refuses a helper whose build
doesn't match (`HelperError.versionMismatch`).

---

## 4. SMAppService + signing

- Helper ships inside the app bundle at
  `Contents/Library/LaunchDaemons/app.cryoframe.helper.plist` and registered via
  `SMAppService.daemon(plistName:)`. GUI-side schedule (M6) is an
  `SMAppService.agent`.
- Connection trust: daemon validates the client's code-signing requirement
  (same Team ID + `app.cryoframe`) on `NSXPCConnection` via
  `setCodeSigningRequirement(_:)` (macOS 13+). No legacy `SMJobBless`
  authorized-clients plist needed on this floor.
- Both signed Developer ID, hardened runtime, notarized (locked decision).
- First registration prompts the user once in System Settings > Login Items to
  enable the background daemon.

---

## 5. Proposed project structure

```
Cryoframe.xcodeproj
  Cryoframe            (app target, SwiftUI, FDA, agent)        → app.cryoframe
  CryoframeHelper      (daemon target, root, fs_snapshot_*)     → app.cryoframe.helper
  CryoframeShared      (XPC contract, value types — this exists) shared framework
  CryoframeKit         (snapshot/archive/verify engines, testable, no privilege)
  spike/               (M0 throwaway, kept for reference)
Tests/
  CryoframeKitTests    (uses FakePrivilegedHelper)
```

`CryoframeKit` holds the engine logic with the `PrivilegedHelper` injected, so
M2–M4 are testable without installing the daemon.

---

## 6. Decisions — RESOLVED (2026-06-24)

1. **De-risk spike first** — yes. `fs_snapshot_*` syscall path validated;
   surfaced the entitlement gate (§2). Split-read gate via the `tmutil` backend
   still to be confirmed before helper code.
2. **OS floor** — keep **macOS 15 Sequoia**. APIs used are 15-safe.
3. **Bundle namespace** — `app.cryoframe` / `app.cryoframe.helper`.
4. **Project generator** — **generated**, not a hand-built `.xcodeproj`
   (diffable for the OSS repo).
5. **Snapshot create backend** — **hybrid**: ship `TMUtilSnapshotBackend`;
   request `com.apple.developer.vfs.snapshot` from Apple DTS in parallel; drop in
   `FSSnapshotBackend` if granted (§2).

Remaining gate before helper code: run `spike/derisk-split-read.sh` (tmutil
backend) and confirm SPLIT READ PASSES.
