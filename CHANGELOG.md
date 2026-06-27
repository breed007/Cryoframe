# Changelog

Notable changes to Cryoframe. Versions follow [semantic versioning](https://semver.org).

## [1.1.0] — 2026-06-27

The 3-2-1 release: more copies, proven restores, and a way to find out when a backup breaks while you're away.

### Added
- **Multiple destinations per job.** A job can now write to more than one destination from the same snapshot — a local drive plus a NAS, an external plus a cloud-sync folder. The first is the primary; if a secondary is offline the run finishes as a *partial* backup (a new distinct state) rather than failing outright. Sealed archives are compressed once and copied to each destination, with no recompression per copy, and each copy is checksum-matched against the original.
- **Remote alerts.** Get a push on your phone or a chat channel when a backup fails, finishes partially, or an archive health check fails — even with the window closed. Settings ▸ General ▸ Remote alerts supports ntfy and a generic webhook (Slack/Discord/custom), with a Send test alert button. Fires independently of the local notification setting.
- **Restore drills.** A deeper archive check than a checksum re-hash: it reassembles, mounts or extracts, and reopens each archive (a database integrity check on Photos, Music, and other database libraries), proving the restore path itself works. Choose the depth in Settings ▸ General ▸ Archive health, or run one on demand from a job's ⋯ menu.

### Changed
- Storage and archive-health now report per destination, and Restore offers every destination a job writes to.
- The job list shows all of a job's destinations.

### Fixed
- Resuming an interrupted transfer no longer deletes a build artifact that another destination still needs (multi-destination jobs share one staged build).
- A single un-readable job no longer wipes the whole job list — jobs decode independently, and the legacy single-destination key is still written for older builds.
- Two destinations that resolve to the same folder are collapsed to one copy, with a warning, instead of silently reporting a phantom second copy.
- Two sealed jobs can no longer be created to archive the same library to the same destination (they would have cross-pruned each other's versions).
- Leftover staged build artifacts are swept at launch; version folders no longer collide when two runs land in the same second; a copy corrupted in transit is caught instead of reported as verified.

## [1.0.1] — 2026-06-25

### Added
- A full user guide under `docs/guide/`, covering setup, jobs, formats and destinations, encryption and recovery keys, versions and retention, health and verification, restoring, scheduling, and troubleshooting. The in-app Help links to it.

### Fixed
- The macOS Help menu (Help ▸ Cryoframe Help, ⌘?) opened a Help Book that was never shipped and errored with "Help isn't available for Cryoframe." It now opens the in-app help, same as the window's Help button.
- The New Job sheet's "Edit locations…" button did nothing, because it tried to open Settings behind the modal sheet. It now opens an inline editor for repointing a built-in library's location, and the checklist refreshes when you close it.

### Added
- Every displayed library and destination path is now a link: click it to reveal the item in Finder.
- The main window is resizable, with a sensible minimum size; the jobs list grows to fill the extra height.

### Fixed
- Editing a built-in library location from the New Job sheet no longer drops plain-folder or template libraries you added in the same session.
- A folder or template library you add now shows a green check, the same as a built-in.

### Changed
- Smaller, non-wrapping window title so it no longer hyphenates to "Cry-oframe" on a narrow window.
- In-app Help updated to match 1.0: Browse contents opens an in-app file browser (not Finder), and Help now covers recovery keys, Verify all archives, archive-health scope, and deleting a single version.

## [1.0.0] — 2026-06-25

The 1.0 release: the archives now watch themselves, recover themselves, and update themselves.

### Added
- **Archive health monitoring.** Cold archives can rot — a flipped bit, a file a NAS quietly dropped. Cryoframe re-hashes existing archives against the manifest written when they were made, catching corruption long before a restore needs it. Runs on demand from a job's ⋯ menu, or on a weekly/monthly schedule (Settings ▸ Archive health), scoped to the latest version per library or all versions. Works on encrypted archives with no passphrase, since checksums are over the on-disk bytes. A "Verify all archives" command in the menu bar checks every job at once.
- **In-app updates.** Cryoframe checks an Ed25519-signed appcast and can download and install new versions itself (Check for Updates, in the menu bar). Updates are signed and verified end to end.
- **Recovery-key escrow.** Settings ▸ Security exports every archive passphrase into one file encrypted with a master password you choose (PBKDF2 + AES-GCM), so encrypted backups are recoverable on a new Mac. Restore-from-file shows the saved passphrases to copy into a restore prompt.
- **Restore in place.** Restore an archive directly over its live library: the verified copy is staged first and the current library is moved to the Trash, so the live data is never at risk and the swap is reversible.
- **Browse inside an archive.** "Browse contents…" opens an in-app file browser over a mounted archive — drill into folders, select individual files, and extract just those, without restoring the whole library.
- **Storage overview.** A Storage window shows how much space each job's archives use, broken down per version, against the free space on the destination volume — so you can tune retention before a disk fills.
- **Onboarding.** A first-run walkthrough covers the helper, Full Disk Access, and creating a first job.
- **Manual version management.** Delete an individual archive version from the Restore window.

### Fixed
- Backups to network shares and non-APFS volumes no longer false-fail the free-space preflight (those filesystems report 0 for the capacity key macOS uses for local disks; a 0 is now read as "unknown," never "full").
- The mirror format's manifest no longer fails on directory-shaped artifacts (sparsebundles).
- Failed or cancelled runs no longer leave empty version folders that could occupy a retention slot.

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
