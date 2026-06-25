# Changelog

Notable changes to Cryoframe. Versions follow [semantic versioning](https://semver.org).

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

[0.3.0]: https://github.com/breed007/Cryoframe/releases/tag/v0.3.0
[0.2.0]: https://github.com/breed007/Cryoframe/releases/tag/v0.2.0
[0.1.0]: https://github.com/breed007/Cryoframe/releases/tag/v0.1.0
