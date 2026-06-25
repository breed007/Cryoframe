# Resumable transfers (v0.3.0)

The gap: sealed DMG/zip archives written directly to a network share or external
drive have no resume. A disconnect at 150 of 200 GB corrupts the file and the
next run restarts from the snapshot. Cloud-sync targets don't have this (the sync
client resumes upload); the live mirror mostly handles it (sparsebundle bands).

## Constraint

You can't resume *building* a sealed archive (`hdiutil`/`ditto` have no resume; a
half-written dmg is garbage). You can only resume *transferring* a finished one.
So: build the archive locally, then ship it resumably. Cost: local scratch ~= one
archive (the snapshot is torn down right after the local build).

## Approach: stage single, stream as parts

1. Build a single archive in a local scratch dir (1× archive). The snapshot is
   released here. Optional mount-and-open verify runs on this local single file
   (no reassembly needed).
2. Ship it to the target as numbered 2 GB parts (`Foo.dmg.part.000`, `.001`, …),
   streaming each range straight from the scratch file — no pre-split, so peak
   scratch stays at 1×. Each part is written to a `.cryoframe-tmp` name and
   renamed into place only when fully written, so a completed part name is always
   whole. The per-part sha256 goes into the manifest.
3. The manifest is written to the target LAST. Its presence marks the archive
   complete; a partial set of parts without a manifest is plainly in-progress.
4. Progress (which parts are done) is persisted in a pending-transfer record. On
   the next app launch or scheduled tick, if the target is reachable again, the
   ship step resumes from the first missing part — no re-snapshot, no re-archive.
   Resume granularity is one part (≤ 2 GB re-sent after a drop).
5. On success the scratch file is deleted and the pending record cleared.

Reassemble at restore with `cat Foo.dmg.part.* > Foo.dmg` (same as cloud-cap splits).

## Scope

- Sealed archives to targets marked resumable (network shares, external drives):
  staged + chunked as above. Local targets keep writing a single file directly.
- Live mirror: `rsync --partial`; resilience to drops comes from re-running the
  idempotent sync, the same way resume-on-launch handles the sealed path. No
  separate backoff loop.
- Cloud-sync: unchanged.

Chunk size (default 2 GB) and scratch location are configurable in Settings ▸
Transfers, documented in Help.
