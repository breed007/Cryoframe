# Health and verification

[← Back to contents](README.md)

A backup you cannot read is not a backup. Cryoframe checks archives at two points: right after writing one, and again later while it sits in cold storage. This page covers both.

## Verification at write time

Every archive gets a checksum manifest when it is written, listing each file and its hash. This is always on. It is how Cryoframe knows later whether an archive still matches what was written.

A job's verify level adds an optional second check:

- Checksum hashes the archive after writing and compares it to the manifest. This is the default.
- Mount & open does that, then also mounts the finished archive and confirms the library's database opens clean. It is slower, and it catches the case where the bytes are intact but the library itself is damaged.

Set the level when you make the job, or set a default in Settings ▸ General.

## Archive health (re-checking cold archives)

Stored archives can rot. A bit flips, a drive drops a file, a NAS quietly loses a block. The data looked fine the day it was written and is broken the day you need it. Archive health re-reads existing archives against the checksums recorded when they were made, so you find the damage early.

### Running a health check

Check a single job any time from its ⋯ menu with Verify archives. Check every job at once with Verify all archives in the menu-bar item. Verify all runs the jobs one after another so it does not saturate the disk.

To run health checks on their own, set a schedule in Settings ▸ General ▸ Archive health: off, weekly, or monthly.

### Scope

The Scope setting next to the schedule controls how much each check covers:

- Latest version only checks the newest archive per library. This keeps the work down on a job that keeps many versions.
- All versions re-checks every version. It is thorough and slower.

For a job with a long retention history, Latest version only is usually the right balance. Use All versions when you want to audit the whole archive set.

### Results

Each job shows its last health check. A failure turns the menu-bar item red and sends a notification, so a silent corruption does not stay silent. The check reports which library and which version failed and why.

### What gets verified, exactly

A sealed archive is verified byte for byte against its checksums, so a single flipped bit is caught.

A live mirror is verified structurally: its files and their sizes are compared to the manifest. This catches dropped or truncated files, which are the common mirror failures, but not an in-place bit flip inside an otherwise intact file. Full-hashing a mirror on every check would mean re-reading the entire library each time, which would undo the reason a mirror is fast. If you need byte-for-byte assurance, use a sealed format.
