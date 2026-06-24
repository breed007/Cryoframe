# Changelog

Notable changes to Cryoframe. Versions follow [semantic versioning](https://semver.org).

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

[0.2.0]: https://github.com/breed007/Cryoframe/releases/tag/v0.2.0
[0.1.0]: https://github.com/breed007/Cryoframe/releases/tag/v0.1.0
