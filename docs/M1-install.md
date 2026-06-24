# M1 — install, register, and run the live snapshot path

M1 is code-complete (helper daemon + XPC + SMAppService client + app), builds,
and signs with both code-signing requirements verified. This is the interactive
finish: register the root daemon and run one real backup-shaped round through XPC.

## build + install

```
./scripts/build-and-install.sh
```

Signed Release build → verifies signatures + the helper's connection requirement
→ installs to `/Applications/Cryoframe.app`.

## register the helper (one time)

1. Open `/Applications/Cryoframe.app`.
2. Click **Register**. macOS shows a background-item prompt; approve and
   authenticate (registering a root LaunchDaemon needs admin).
3. Go to **System Settings ▸ General ▸ Login Items & Extensions** and make sure
   Cryoframe's background item is **on**. Back in the app, **Refresh** — status
   should read **enabled**.

## grant Full Disk Access

The app reads the frozen Photos library (snapshotting doesn't bypass TCC):

4. **System Settings ▸ Privacy & Security ▸ Full Disk Access** → add
   `/Applications/Cryoframe.app` → toggle on. Relaunch the app.

## run the live round

5. Click **Run snapshot test**. Expected log:
   ```
   helper 0.1.0-m1 (pid …)
   ✓ mounted com.apple.TimeMachine.<date>.local; read 16 bytes from frozen Photos.sqlite
   ✓ teardown complete (unmounted + deleted)
   ```
   That exercises the whole M1 boundary: app → XPC → **root helper** creates +
   mounts the snapshot → **app (FDA)** reads the frozen library → helper unmounts
   + deletes. Same path the spikes proved, now through the shipping architecture.

6. Click **Reconcile** to confirm orphan-sweep returns cleanly (0/0 on a clean run).

## what success proves for M1

- SMAppService root daemon registers and vends XPC.
- Mutual code-signing trust (app ↔ helper) holds at runtime.
- The privilege split works end to end: root mounts, FDA app reads.
- Lifecycle + teardown + reconcile run through the real seam.

## troubleshooting

- **status stuck at "requires approval"** — toggle the item in Login Items; it
  can take a moment to flip to enabled.
- **connection interrupted / invalid** — the app and helper signatures must both
  be Developer ID, same team. `./scripts/build-and-install.sh` re-verifies this.
- **"mount_apfs: Operation not permitted" (status 77)** or **read fails with
  "Operation not permitted"** — Full Disk Access isn't active. FDA gates BOTH the
  helper's `mount_apfs` and the app's read; the daemon rides the app's grant via
  `AssociatedBundleIdentifiers`, so grant FDA to `Cryoframe.app`, then relaunch.
- **re-installing** — click **Unregister** in the app before rebuilding, so the
  old daemon registration is cleared.
