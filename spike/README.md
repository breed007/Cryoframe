# M0 spike — snapshot → archive → reopen

proves the one real unknown: does archiving a `.photoslibrary` from a **frozen
APFS snapshot** produce a clean, reopenable library? this is a throwaway CLI
scaffold — not the shipping mechanism. if it passes, M1 promotes snapshot
create/mount/delete to `fs_snapshot_*` inside the root helper.

## lifecycle (deterministic, owned end-to-end)

```
reconcile   sweep orphan mounts (/private/tmp/cryoframe_snap.*) and orphan
            snapshots recorded in our own statefiles — never TM's snapshots
create      tmutil localsnapshot /        (M1: fs_snapshot_create,
                                            name app.cryoframe.snap.<unix-ts>)
            identify OURS by set-diff before/after — not "newest"
mount       mount_apfs -o rdonly -s <snap> /dev/disk3s5 <mountpoint>
archive     ditto|zip|dmg  from  <mountpoint>/Users/<you>/Pictures/<lib>
            (FDA-gated read — root does NOT bypass TCC for Photos content)
verify      sha256 checksum of the artifact
teardown    umount  +  tmutil deletelocalsnapshots <date>   (only OURS)
```

teardown runs from an EXIT trap, so a crash still cleans up; anything it misses,
the next run's reconcile step catches.

## run it

1. grant **Full Disk Access** to your terminal: System Settings → Privacy &
   Security → Full Disk Access → add Terminal/iTerm. **fully quit and reopen**
   the terminal afterwards (TCC only re-reads on launch).
2. run as root:
   ```
   sudo ./cryoframe-spike.sh
   ```
   overrides: `LIBRARY=...  DEST=...  MODE=copy|zip|dmg  KEEP=1`
3. when it finishes, do the **manual reopen check** it prints:
   hold Option, launch Photos, choose the archived library, and confirm it
   opens with **no repair/recover prompt** and content is intact.

`KEEP=1` leaves the snapshot mounted so you can poke at the frozen tree before
teardown.

## gate acceptance

- [ ] archived library reopens clean (no DB recovery prompt)   ← the real test
- [x] correct Data-volume targeting (`/dev/disk3s5`, not the root volume)
- [x] read-side FDA confirmed in practice (TCC blocks `ls` without it;
      the script's FDA probe fails fast if the terminal isn't granted)
- [x] create→mount→archive→unmount→delete lifecycle articulated, deterministic
      naming, orphan reconcile

three of four boxes are already provable from environment facts. the first box
needs the human reopen check — that's the gate.
