# Changelog

Notable changes to Cryoframe. Versions follow [semantic versioning](https://semver.org).

## [1.5.2] — 2026-08-28

A QA pass over 1.5.1 found one way to lose every backup you have. The rest are the
smaller things that pass turned up.

### Fixed
- **A retention setting could delete every version you had.** The daily/weekly/monthly steppers each allow zero, and setting all three to zero meant "keep nothing", so a run would archive the library and then delete the entire history, including the version it had just written, without reporting anything. Keeping the last N was already protected against this; the grandfather-father-son scheme was not. No retention policy can now select the newest version, whatever it is set to, and the setting that meant "keep nothing" resolves to keeping the newest. An individual bucket at zero is still allowed, because "no monthlies" is a real preference.
- **Retention could stop working without saying so.** A share that dropped, a file still held open, a permissions change: the deletion silently didn't happen, the destination went on growing, and the storage warning went on believing the job was bounded. A run that backs up cleanly but can't tidy up now says which versions it couldn't remove. It still counts as a successful run, because the backup was written and verified; only the tidying failed.
- **Recovering to an external drive said "Zero KB free — not enough room."** Free space in the recovery flow came from a figure that only means anything on the disk holding your home folder, so an external drive — the likeliest place to recover from onto a fresh Mac — reported nothing free. The check was advisory and never blocked the restore, but on the worst day it is the wrong sentence to read. Two earlier releases fixed this same figure elsewhere; this was the last place still reading it raw.
- **Two backup jobs could quietly share, and prune, each other's versions.** Cryoframe already refuses to let two sealed jobs write the same library to the same folder, but it compared the folders as plain text, so `/Volumes/Drive/Backups` and `/Volumes/Drive/backups`, which are the same folder, read as two different ones, and a shortcut got past it entirely.
- **The privileged helper would unmount any location it was asked to.** It is only reachable by Cryoframe itself, so nothing could ask it to, but it should not have been able to comply. It now only unmounts the temporary mounts it created.

### Changed
- The recovery-key file's documentation understated its own strength (it says 600,000 PBKDF2 rounds, which is what it has always done).

## [1.5.1] — 2026-08-26

### Fixed
- **A live mirror was dropping your files' extended attributes, resource forks, and ACLs** — every run, in the default format. The mirror syncs with `rsync -a`, and on macOS 15+ `/usr/bin/rsync` is openrsync, where `-a` carries none of the three (and `-X` is not even a recognised option). So Finder tags and anything else macOS keeps beside a file were discarded on the way in, while sealed zip (via `ditto`) and sealed DMG (a filesystem image) preserved them. Adding `-E` fixes it, and existing mirrors repair themselves on their next run — the metadata is restored without re-copying file contents, so there is no oversized catch-up run.
- **The README overstated what a mirror's health check proves.** It said a checksum manifest covers every archive and that re-hashing catches bit rot. A mirror is verified structurally, against its file list and sizes, which finds dropped or truncated files but not a flipped bit inside an intact one. The user guide already said so; the README now agrees with it. Byte-level verification for mirrors is a real gap, and a later release's problem.

## [1.5.0] — 2026-08-26

Making good on things the app already claimed. Every item here closes a gap between what Cryoframe said it did and what it actually did.

### Added
- **Libraries on other disks.** A library kept on an external SSD — where a photo or music library big enough to be worth backing up usually lives — could not be backed up at all. Cryoframe froze the boot disk wherever the library was, looked for it inside that snapshot, and reported "library not found" about a library sitting right there. Each library is now placed by asking the kernel which volume its files are on, and every disk involved is frozen; a job spanning two drives still captures one moment. Volumes that cannot be frozen (exFAT, HFS+) are read live instead, and the run refuses to start while that library's app is open, naming the drive, the format, and the app to quit.
- **Alerts from an unattended Mac.** Remote alerts existed to tell you a backup failed while you were away, but only the running app ever sent one. The scheduled runner — the thing actually running when you are away — sent nothing, and the app suppresses anything that predates its launch, so a failure it was not running for was never announced at all. The agent now alerts for the runs and health checks it performs.
- **Recovery rehearsal.** A restore drill proves an archive opens; it cannot prove a recovery works, because it derives every path from the job. A rehearsal looks where a recovery looks: it scans the destination, plans the newest moment, and opens what it finds. A library the jobs claim to protect but that a restore would not find is named. Monthly by default, on demand from a job's ⋯ menu, and bounded to the newest version of each library.
- **Storage pressure.** A destination that fills up does not degrade, it stops, and every run after it fails the same way. Cryoframe now says so first, measured against what the last run of that job actually took rather than a percentage of the volume. The agent sends it as an alert, at most once a day per destination.
- **Choosing sources and destinations.** Any library row can be pointed at where it is really kept, any folder can be added as a source, and destinations can be removed.

### Changed
- **New jobs keep the last 7 versions instead of every version.** Keeping everything meant a sealed job grew until the destination filled, while the app promised retention was what stopped that. Existing jobs are untouched.
- **There is no default destination.** The old one wrote a backup of the boot disk onto the boot disk, pre-selected, so the path of least resistance produced a copy that one drive failure would take along with the original. A destination on the same disk as its source now says so.
- Checks say what they actually did: *Recovery-rehearsed*, *Restore-drilled*, *Archives verified*.

### Fixed
- **A library name containing a comma locked you out of your own backup.** Recovery matches archives to keys by library name, and those names were stored joined by commas and split apart again — so "Client Work, 2026" came back as two names matching nothing, and that library could never be unlocked on a new Mac. Recovery files written by earlier versions still open.
- **An encrypted backup could not be created from the New Job wizard.** Turning encryption on and typing a passphrase left it asking for a passphrase, and Create job did nothing; the confirmation field it validated against did not exist.
- **Every external destination looked full.** Free space came from an APFS figure that only means anything on the disk holding your home folder; external drives, disk images, and network shares answer zero. So a drive with 50 GB free reported none, the dashboard showed nothing left, and the new storage warning fired nightly — to your phone — about a destination that was fine. Preflight already knew better; the rest of the app now reads a volume the same way it does.
- **A busy Mac was reported as a lost passphrase.** When the disk-image system was saturated, an encrypted archive failed to open the same way a wrong key does, and the rehearsal said the passphrase on this Mac may no longer match — sending you after a recovery key over a machine that was merely busy. Contention now says so, and says to rehearse again.
- **A failed backup said "The operation couldn't be completed. (CryoframeKit.ArchiveError error 3.)"** — in the job row, the activity log, the run history, and the alert sent to your phone. Failures now say what happened and what to do: an encrypted job whose key isn't on this Mac says so, and a tool failure quotes the tool's own last words.
- **Destinations could not actually be removed.** The ✕ beside a destination in the New Job wizard did nothing at all. It was a button inside another button's label, where the outer one takes every click, and the row's own border sat on top of both and swallowed what was left. Removing a destination works now, and the row selects when you click it.
- **A destination you can't remove now says so.** The ✕ beside one a job depends on was merely disabled, and a disabled ✕ looks almost exactly like a live one, so clicking it said nothing. It is a lock, and it names the job holding the destination.
- **A failed disk-image attach left a device behind**, and each one made the next attach likelier to fail, until nothing on the Mac would mount. Attaches also queue now, so two concurrent jobs cannot fail each other's verification. The cleanup that removes those devices is itself patient: it runs in the moment the disk-image system is busiest, where firing one detach and ignoring the result left the device exactly where it was and kept the spiral going.
- The job list could be squeezed to nothing at the default window size when a coverage card was showing.

## [1.4.1] — 2026-08-01

### Fixed
- **The job list could be squeezed to nothing.** With the new coverage card showing, the main window at its default size gave the dashboard, the card, and the activity log their space and left none for the jobs — so a Mac with one job and one unprotected library, which is a common setup, showed an empty gap where the backups should be. The list now keeps a minimum height and the window's minimum size accounts for the card.

## [1.4.0] — 2026-08-01

Recovery you can trust. The backup half of Cryoframe was well covered; this release does the same for getting your data back.

### Added
- **Restore timeline.** A library's versions now appear on a timeline instead of a flat list: pick a night, see its size and how it compares to the ones around it, and restore that point in time — beside your live library or in place. Live mirrors keep a single current copy, so they show that plainly rather than pretending to have history.
- **Version badges.** A version that passed a restore drill is marked *Restore-tested*; one that only had its checksums re-read is marked *Checksum verified*. They are different promises, so they read differently, and a version nothing has checked says nothing at all.
- **Recover to this Mac.** A guided four-step recovery for a new or wiped Mac: find the backups, unlock the encrypted ones with your recovery-key file, choose a moment, restore. Each library comes back as it was at that moment — never a version written after it, so you get the Mac you had rather than a mix of days. Reachable from ⇧⌘R, the File menu, or the empty state.
- **Coverage advisor.** The dashboard now names libraries on this Mac that no job covers, with their size and a button that opens the wizard already pointed at them. Dismissing one is permanent.
- **Battery-aware scheduling.** A scheduled run waits when the Mac is on battery and low on charge, records that it waited, and tries again at the next hourly check. Run now is never held back. Off or adjustable in Settings ▸ Running.

### Changed
- Health records now store the outcome for each archive version rather than a count and a list of failures, which is what lets a single version be badged honestly. Records written by earlier versions still load; they simply make no claim about which versions were checked.

### Fixed
- "Start from scratch" in the New Job wizard did nothing when clicked. It now clears the form to the defaults.
- The size sparkline was drawn to the edge of its frame, clipping the endpoint marker.
- VoiceOver labels for the chunk size, mirror size, and custom cloud-limit fields.

## [1.3.0] — 2026-07-14

A UX overhaul — the app now tells you whether you're protected, and setting up a backup takes a few clicks.

### Added
- **Protection dashboard.** The top of the window answers "am I backed up?" at a glance: a green shield when every job is healthy, or an amber warning that names the job needing attention. Below it, the last successful backup, the total size protected, the number of destinations, and free space on the tightest one.
- **Guided New Job wizard.** Four steps — what to back up, where, how often, review — with templates (Photos nightly, Music mirror) that set everything at once. The advanced options (format, encryption, verification, retention) stay editable on the review step, with sensible defaults. Editing an existing job still opens the full form.
- **Sizes and free space.** Each library shows its source size (measured in the background), and each destination shows its free space. At setup the total to back up is checked against the primary destination, so "won't fit" shows up before the first run, not during it.
- **Drag and drop.** Drop a folder or a `.photoslibrary` on the window to start a job pre-filled with it.
- **Light mode and a cohesive palette.** The app follows the system appearance and now has an intentional design system — an electric-cyan accent and consistent status colors — in both light and dark. Status reads through shape and text, not color alone.
- Onboarding ends by opening the wizard, so a new setup lands its first backup rather than an empty window.

- **Keyboard shortcuts and a real File menu.** New Job (⌘N), Restore (⌘R), Storage (⌘D), History (⌘Y), and Verify All Archives (⇧⌘V), all reachable without the mouse.

### Changed
- The main window is built around the dashboard; the job list sits beneath it.
- Job creation logic is unified behind a single source of truth shared by the wizard and the edit form.
- The Restore, Storage, History, and archive-browse windows now use the same design system as the rest of the app: shared headers, card rows, and consistent empty states. Job rows carry a status stripe matching the dashboard.
- The menu-bar icon and its status line are computed from the same verdict as the dashboard, so the two can no longer disagree.

### Fixed
- **An archive check could fail a perfectly good archive.** When `hdiutil` reported disk-image contention as "Resource temporarily unavailable" — which happens when a check runs alongside Time Machine or Spotlight — Cryoframe treated it as a hard failure instead of retrying, reporting a healthy archive as broken. Transient contention is now retried with backoff; genuine errors still fail immediately.
- The menu-bar icon no longer shows a checkmark while a job has a failed archive check or has never run.
- Icon-only controls (row action menus, the file browser's select and drill-in buttons, unit pickers) now carry VoiceOver labels.

## [1.2.0] — 2026-06-27

Cloud-sync backups that actually verify and restore — with the right per-provider behavior.

### Added
- **Cloud provider awareness.** When you add a cloud-sync destination, Cryoframe detects the provider (OneDrive, Dropbox, Google Drive, Box, iCloud — it looks under `~/Library/CloudStorage`) and asks which plan you're on, so sealed archives split under that plan's single-file limit. Those limits differ a lot: iCloud caps at 50 GB, Box at 5 GB on Free/Starter (50 GB Business, 150 GB Enterprise), the rest around 250 GB — or set a custom size. Detected cloud folders appear as one-click choices in the Add destination menu.
- **Offloaded-archive handling.** Cloud clients evict files to a placeholder to save space; reading one re-downloads it. A scheduled health check or restore drill now detects an offloaded cloud archive and skips it — reported as "not downloaded," neither pass nor failure — instead of silently pulling gigabytes back down. Turn on Settings ▸ General ▸ Archive health ▸ "Download cloud archives to check them" to verify them anyway. A restore always downloads what it needs.

### Fixed
- A job whose only copies are offloaded cloud placeholders no longer raises a false "no archives found — is the target connected?" alert; it correctly reports them as not downloaded.
- Cloud jobs created before this release also get the offloaded-archive handling (detection is by destination kind, not the new provider field).

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
