# Changelog

Notable changes to Cryoframe. Versions follow [semantic versioning](https://semver.org).

## [0.5.0] — 2026-06-25

Closes the loop and hardens the archives.

### Added
- **Restore.** A Restore window finds archives in a folder, verifies their checksums, mounts or extracts them, and copies the library back out with its original folder name — beside your live library, never over it. Handles split volumes and every format.
- **Encryption.** Optionally encrypt a job's archive with AES-256 (sealed DMG and live mirror). The passphrase is kept in your Keychain so scheduled runs encrypt without prompting; verify and restore unlock with it. Losing the passphrase means the backup is unrecoverable, by design.
- **Versions & retention.** Each run of a sealed job is saved as a dated version, so you can restore a point in time. Keep all versions, the last N, or a daily/weekly/monthly scheme — older versions are pruned automatically. (Live mirror stays a single, continuously-updated copy.)
- **Notifications & menu bar.** A menu-bar status item shows each job's last run at a glance and turns red on failure. Cryoframe stays resident there so it can notify you of scheduled-run results — never, on failure, or on every run — even with the window closed.

## [0.3.2] — 2026-06-25

### Added
- Live throughput while a job runs: current speed, time elapsed, and estimated time remaining under the progress bar (smoothed for archives, cumulative for transfers).
- Persistent run history. Every run — manual or scheduled — is recorded with its outcome, per-library detail, duration, size, and any error, and survives quitting the app. A new History button (top right) lists past runs, including scheduled ones that ran while the app was closed. Each job also shows a last-run summary, and the activity log is seeded from recent history and narrates per library during a run.
- Mirror size is now a numeric field with a GB/TB unit picker (matching the resumable-transfer part size), in the New Job sheet and Settings.

### Changed
- The job row shows which library is being processed during a multi-library run.

## [0.3.1] — 2026-06-25

### Added
- "Keep the Mac awake while a backup runs" (Settings ▸ General, on by default). Holds an idle-sleep assertion for the duration of a run so an unattended or scheduled backup isn't cut off when the Mac idle-sleeps. Prevents idle sleep only — it never forces the display on, and is released while a job is paused.
- "Wake the Mac for scheduled backups" (off by default). Asks the helper to set a system wake a couple of minutes before the next due job, so an idle Mac runs its scheduled backup near the intended time. It only ever manages its own wake event, can't wake a Mac that's shut down, and can't beat a closed lid.

### Internal
- Removed the superseded `BackupRunner`/`TargetedBackupRunner` paths; all runs go through `JobExecutor`.

## [0.3.0] — 2026-06-25

### Added
- Multiple libraries per job. A job takes one APFS snapshot and archives every selected library from that single point-in-time set, each into its own subfolder at the destination. Libraries are now picked from one unified checklist (built-ins, templates, and folders together).
- Resumable transfers to network shares and external drives. The archive is built locally, then shipped in numbered part files (default 2 GB, configurable in GB or TB under Settings ▸ Transfers). A dropped connection or unplugged drive resumes from the last whole part on reconnect.
- Concurrent jobs, bounded by a "maximum jobs running at once" setting (default 2). Snapshot creation is serialized in the helper so parallel jobs stay consistent.
- Job controls: Run now, Stop, Pause/Resume, Edit, Delete, and enable/disable scheduling — from the job row and its ⋯ menu. Pause suspends the in-flight tool in place; it's offered for live-mirror and sealed-zip archives and for transfers (sealed-DMG imaging can't be safely paused, so a DMG job shows only Stop while building).
- Live progress: a determinate bar with bytes-written and percentage during archiving, and part counts during transfers.

### Changed
- Live mirror is now the default output format, ahead of sealed zip and sealed DMG.
- After an app update the helper reloads itself on next launch, so helper fixes take effect without a reboot.

### Fixed
- Snapshot unmount retries and force-unmounts when the mount is briefly busy after a run, instead of failing with "Resource busy".

## [0.2.0] — 2026-06-24

### Added
- Custom locations for built-in libraries, in Settings ▸ Libraries. Repoint a library kept somewhere other than its default path — an external drive, or a moved library — without losing its owning-app detection or integrity check. Each library has its own reset, plus a restore-all-defaults button. Jobs that target a built-in pick up the new path on their next run.

### Docs
- Added app screenshots to the README.

## [0.1.0] — 2026-06-24

First public release. Signed with a Developer ID and notarized.

### Added
- Consistent point-in-time backups of live libraries using APFS snapshots, created and torn down per run.
- Root helper plus the app, talking over XPC. The helper takes, mounts, and deletes snapshots; the app reads the frozen library with Full Disk Access. Each verifies the other's code signature on every connection.
- Built-in libraries: Photos, Apple Music, iMovie, GarageBand, Messages, Mail, and Microsoft Outlook.
- Templates for libraries that live anywhere: Final Cut Pro, Lightroom Classic, Capture One, and Logic Pro. Plus a plain-folder option for anything else.
- Two output formats: a sealed DMG or zip (immutable, checksummed, split into volumes for cloud targets), and an incremental sparsebundle mirror.
- Verification: a checksum manifest on every archive, and an optional mount-and-open check that confirms the library's database opens clean. Cold archives can be re-verified later.
- Targets for local disks, network shares, and cloud-sync folders, each with a size cap and an availability preflight.
- Scheduling through a launchd agent, with per-job control over what happens when the owning app is open.

[0.5.0]: https://github.com/breed007/Cryoframe/releases/tag/v0.5.0
[0.3.2]: https://github.com/breed007/Cryoframe/releases/tag/v0.3.2
[0.3.1]: https://github.com/breed007/Cryoframe/releases/tag/v0.3.1
[0.3.0]: https://github.com/breed007/Cryoframe/releases/tag/v0.3.0
[0.2.0]: https://github.com/breed007/Cryoframe/releases/tag/v0.2.0
[0.1.0]: https://github.com/breed007/Cryoframe/releases/tag/v0.1.0
