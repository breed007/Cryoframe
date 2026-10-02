# Cryoframe

Back up live macOS media libraries into sealed, verifiable archives, on a schedule, without quitting the app that owns the library.

macOS 15 or later, including macOS 27 · Apple Silicon · MIT licensed

📖 **[User guide](docs/guide/README.md)**: install, jobs, formats, encryption, restoring, and troubleshooting.

<p align="center">
  <img src="docs/screenshots/main-window.png" alt="The main window: the protection dashboard says You're protected, above the job list" width="560">
</p>

---

## The problem it solves

The hard part of backing up a media library is not the copy. It is taking a consistent point-in-time copy of a library whose database is being written to while the backup runs. If you zip a `.photoslibrary` while Photos has its database open, you can seal a half-written, corrupt database into the archive. The backup looks fine until the day you need it.

Cryoframe avoids that with APFS snapshots. For each run it freezes the volume, mounts the snapshot read-only, archives the library from that frozen copy, then deletes the snapshot. The library stays open the whole time, and the archive is a consistent moment in time.

It also verifies. Every archive gets a checksum manifest, and the strong mode mounts the finished archive and runs a database integrity check, so you find out a backup is bad now instead of during a restore.

## Features

- A protection dashboard at the top of the window: whether everything is backed up, the last successful run, total size protected, and free space on the destination. The job list comes below it. It also names any library on this Mac that no job covers, so a gap you forgot about does not stay invisible.
- One editor for making and changing jobs, in plain words: what to back up, where copies go, when, and whether each backup keeps one up-to-date copy or dated versions. Quick-start presets cover the common cases, and you can drag a folder onto the window to start a job. Each library shows its size, and the editor says when a backup may not fit on its main destination. Before you save a change, it says what the change does to the backups you already have.
- Drives that take turns: two or more external drives can share one place in a job, and each backup goes to whichever is connected. Destinations are known by the drive they're on, so a renamed drive is still found and a different drive with the same name isn't used by mistake.
- Consistent snapshots of live libraries using APFS, created and torn down per run.
- Libraries on any disk. A Photos or Music library kept on an external SSD is backed up from a snapshot of the drive it actually lives on, and a job spanning two drives still captures a single moment. Drives that can't be snapshotted (exFAT, HFS+) are read directly instead, and the run won't start while that library's app is open, since a closed app is what makes reading it live safe.
- Several libraries per job, archived from one snapshot into their own subfolders, so a job captures a consistent set in a single pass.
- Several destinations per job (the 3-2-1 rule): a local drive plus a NAS plus a cloud-sync folder, all from the same snapshot. Sealed archives are compressed once and copied to each. The primary must be reached; a downed secondary finishes the run as a partial backup instead of failing it.
- Four output formats: an incremental sparsebundle mirror that only rewrites the bands that changed (the default); plain files, one copy as ordinary files and folders that any computer can open; or a sealed zip or DMG: immutable, checksummed, split into volumes when the target caps file size.
- Resumable transfers to network shares and external drives: the archive ships in part files and picks up from the last whole part after a dropped connection or unplugged drive.
- Restore built in: find an archive, verify it, and copy the library back out with its original folder name, beside the live one or in place over it (staged and verified first, with the old copy moved to the Trash). If something already has that name, restore alongside it under a new one. Browse inside an archive and extract just the files you need, or export a version's photos and videos into month folders.
- Find a File: type a name or part of a path, and see which saved versions hold it. Each sealed version carries a list of its files, encrypted when the job is, so the search doesn't have to open every archive.
- A recovery note in every destination saying what is there and how to open it with tools built into macOS, and a printable recovery kit that lists every job, where its backups are, and each drive's name and volume UUID. The kit holds no passphrases; those print on a separate page, only if you ask, after a warning.
- A restore timeline for versioned libraries: browse a library's nights, see how its size moved, and bring back the one you want. Versions that passed a restore drill are marked as restore-tested, and ones only checked by checksum say so instead. A version nothing has checked makes no claim at all.
- Guided recovery for a new Mac: point it at your backups, unlock the encrypted ones with your recovery-key file, pick a moment, and every library comes back as it was then. It never restores a version written after the moment you chose, so you get the Mac you had rather than a mix of days.
- Optional AES-256 encryption for sealed-DMG and live-mirror archives, with the passphrase kept in the Keychain so scheduled runs encrypt without prompting.
- Versioned sealed archives with a retention policy: the last N (seven by default), a daily/weekly/monthly scheme, or keep everything if you'd rather. Bounded by default, so a job can't quietly grow until the destination is full.
- Verification built in: a content checksum manifest on every sealed archive, plus an optional mount-and-open check that confirms the library's database opens clean. A live mirror is checked structurally instead, against its file list and sizes, since re-hashing a mirror every run would undo the reason it is fast.
- Archive health monitoring: re-hash existing sealed archives against their manifests on demand or on a weekly/monthly schedule, to catch bit rot before a restore needs them. Works on encrypted archives with no passphrase.
- Restore drills: a deeper check that reassembles, mounts or extracts, and reopens each archive (a database integrity check), proving the restore path itself works, which matching bytes alone cannot.
- Recovery rehearsals: monthly, Cryoframe looks at a destination the way a recovery would, scanning what is actually there rather than the paths a job computes, and reports what would come back. A library a job claims to protect but that a restore would not find is named, which no per-archive check can tell you.
- Remote alerts over ntfy or a webhook (Slack/Discord/custom), sent by the scheduled runner itself, so an unattended Mac whose backups are failing reaches your phone whether or not the app is open. A destination running out of room is sent the same way, before the run that would fail.
- Recovery-key escrow: export every archive passphrase into one master-password-encrypted file (PBKDF2 + AES-GCM), so encrypted backups survive a lost Mac.
- Storage overview: per-job, per-version sizes against the free space on each destination volume, a trend of each destination's recent runs, and, for a cloud folder, whether its versions have been uploaded. Upload status is shown as uploaded only when the provider has proven it holds the file; until then it reads "not known" in gray, which is normal.
- Report a Problem (Help menu) builds a plain-text report for a GitHub issue, with your names, paths, and file names left out. You read it before you save it.
- In-app updates over an Ed25519-signed appcast, and a first-run walkthrough for the helper and Full Disk Access.
- Destinations on local disks, external drives, network shares, and cloud-sync folders. Cryoframe works out which kind a folder is when you add it, and checks it is there before a run starts. There's no default destination to accept without thinking, and choosing one that shares a disk with what you're backing up says so.
- Cloud-sync aware: detects OneDrive/Dropbox/Google Drive/Box/iCloud folders, splits sealed archives under the plan's single-file limit, and skips offloaded (placeholder) archives during scheduled checks instead of silently re-downloading them.
- Run jobs concurrently up to a configurable limit, with live progress (speed, time elapsed, and time remaining) for every step of a run, and pause, resume, or stop a run in flight. Stop also ends an archive check, drill, or rehearsal; a stopped check never counts as passed. Quitting during a backup asks first and stops it cleanly, and a logout or restart stops it without asking.
- Durable run history: every run, manual or scheduled, is recorded with its outcome, per-library detail, duration, size, and any error, and survives quitting the app.
- Scheduling through a launchd agent, with per-job control over what happens if the owning app is open. A run missed while the Mac was asleep or off happens at the next check rather than waiting a whole cycle, and an unattended run holds off while the Mac is on battery and low on charge.
- Keeps the Mac awake while a backup runs, and can optionally wake it for a scheduled run, so unattended backups actually finish.
- A menu-bar status item and notifications, so you know at a glance whether the last run succeeded, scheduled ones included.
- Owns its snapshots end to end. It never touches Time Machine's snapshots.

## Supported libraries

Built in (fixed locations, detected automatically):

| Library | Location | Owning app |
|---|---|---|
| Photos | `~/Pictures/Photos Library.photoslibrary` | Photos |
| Apple Music | `~/Music/Music/Music Library.musiclibrary` | Music |
| iMovie | `~/Movies/iMovie Library.imovielibrary` | iMovie |
| GarageBand | `~/Music/GarageBand` | GarageBand |
| Messages | `~/Library/Messages` | Messages |
| Messages attachments | `~/Library/Messages/Attachments` | none (Messages can stay open) |
| Mail | `~/Library/Mail` | Mail |
| Microsoft Outlook | default Outlook profile | Outlook |

**Messages attachments** backs up the photos, videos and files sent and received in Messages, without the conversations, in any format. What you delete in Messages stays in the backup: a live mirror or plain files keep it in a Removed items folder, and dated versions save it in an archive of its own before old versions are deleted. Restore lists those archives as "Messages attachments, removed items". A live mirror and plain files leave out link previews and Messages' own settings files. Dated versions keep them, because a disk image or zip file can't skip anything without copying the whole folder first on every run.

Templates (you point at the library, since these live anywhere, often on external drives), under **A library from another app…** in the job editor:

- Final Cut Pro libraries
- Lightroom Classic catalogs
- Capture One catalogs
- Logic Pro projects

Anything else: add any folder with **Back up another folder…**, and it is treated as static content.

A built-in library kept somewhere other than its default location, such as an external drive, can be pointed at where it really is. In the job editor, a library that isn't where the default says reads "not found there", and its menu has **Choose where it's kept…**. Repointing keeps the library's identity: Photos is still Photos, so it still knows the owning app to watch for and still gets its database integrity check. The same locations are editable later in Settings ▸ Libraries.

Libraries on other drives are backed up from a snapshot of the drive they live on, so an external APFS SSD works the same way the boot disk does. A drive formatted exFAT or HFS+ can't be snapshotted at all; those are read directly instead, and the run refuses to start while the library's app is open. With the app closed, reading it live is consistent.

## Install

### Download

Grab `Cryoframe-x.y.z.dmg` from [Releases](https://github.com/breed007/Cryoframe/releases). It is signed with a Developer ID and notarized, so it opens with no Gatekeeper warnings. Open the DMG and drag Cryoframe to Applications.

### Build from source

```
brew install xcodegen
git clone https://github.com/breed007/Cryoframe.git
cd Cryoframe
xcodegen generate
open Cryoframe.xcodeproj
```

Set `DEVELOPMENT_TEAM` in `project.yml` to your own Team ID first. The privileged helper will not register without a Developer ID. The `.xcodeproj` is generated and gitignored; edit `project.yml`, never the project file. To build, sign, and install in one step:

```
./scripts/build-and-install.sh
```

## First run

Three one-time steps, shown at the top of the window:

1. Enable the helper. This installs the background service that takes snapshots. Approve it in System Settings ▸ Login Items when asked, and authenticate (installing a root service needs admin).
2. Grant Full Disk Access to Cryoframe, then relaunch. The dot turns green once it can read protected libraries. Full Disk Access is required because a snapshot of Photos content is still Photos content as far as macOS privacy controls are concerned.
3. Enable the schedule if you want jobs to run in the background.

## Using it

Press New Job. The editor opens with quick-start presets ("Photos, nightly", "Music, kept up to date", "Photos and Music", or start from scratch), and everything a preset sets is shown below it to change:

- **Back up**: the libraries and folders in the job. Everything chosen is backed up from one moment in time, each in a folder of its own.
- **Copies go to**: the destinations. **Add destination…** takes a folder on this Mac, an external drive, a network share, or a cloud folder; Cryoframe works out which it is. The first is the main destination, which a backup has to reach. Drives can take turns, so each backup goes to whichever is connected.
- **When**: every day, every few hours, once, or only when you say.
- **Keep**: each backup keeps one up-to-date copy, as a disk image (a live mirror) or plain files, or dated versions, as disk images or zip files, with a rule for how many versions to keep.
- **Details**: encryption, how each backup is checked, and what to do if the library's app is open.

<p align="center">
  <img src="docs/screenshots/editor-create.png" alt="The new-job editor's quick-start presets: Photos nightly, Music kept up to date, Photos and Music, or start from scratch" width="620">
</p>

Before a new job's first backup, and before an edit is saved, a summary says what will happen to the backups already at each destination.

Formats:

- One up-to-date copy (live mirror). A sparsebundle with about 8 MB bands. The first run copies everything; later runs only write the bands that changed. It sizes itself to the library and grows as needed, up to what the drive can hold.
- One up-to-date copy as plain files. Ordinary files and folders that open on any computer, with no Cryoframe needed. What you delete from the library moves to a Removed items folder beside the copy, which you empty in Storage. Plain files can't be encrypted, and on exFAT, FAT32 and network drives they lose what those drives can't hold, such as permissions and creation dates. An app's library, such as Photos, can only be kept as plain files on an APFS drive connected to this Mac.
- Dated versions, as disk images (sealed DMG) or zip files (sealed zip). One immutable, checksummed file per run for cold storage. An archive larger than the destination's file-size cap splits into volumes, so it fits cloud single-file limits.

Checks:

- Quick check hashes every archive after writing. A manifest (`cryoframe-manifest.json`) is written next to the archive.
- Full check also opens the finished archive and runs a SQLite integrity check on the library's database. This is the strong check for live-database libraries.

"If the app is open" controls what happens when the owning app is running: back up anyway (the default, because the snapshot is already consistent), back up and say so, or wait until it's closed.

The Help button in the app has worked examples for Apple Photos and Apple Music.

## Getting your data back

Two doors, because there are two situations.

**Restore (⌘R)** is for "I need that library back." Pick a library, and its versions appear on a timeline, each night with its size and how it moved. Choose one and bring it back beside your live library (the default, which changes nothing you have now) or in place over it. You can also open a version and pull out a handful of files instead of the whole thing.

<p align="center">
  <img src="docs/screenshots/restore-timeline.png" alt="The restore window: a library's versions on a timeline, with the Find a File button" width="620">
</p>

A version a restore drill has opened is marked *Restore-tested*; one whose checksums were re-read is marked *Checksum verified*. A version nothing has checked yet carries no badge, because Cryoframe won't claim more than it knows.

Want the photos out of a backup rather than the library? **Export Media…** copies a version's photos, videos, or other files into a folder for each month, filtered by type and date. Exporting again copies only what isn't there yet. It's offered for folders and Messages, not for app libraries such as Photos.

Not sure which night still had the file? **Find a File…** in Restore searches each version's list of files for a name or a path, newest first, and opens the version at the match so you can extract it. Versions made before 1.6 have no list; open those with **Look inside…**.

<p align="center">
  <img src="docs/screenshots/find-a-file.png" alt="Find a File: a search that finds the same file in three saved versions" width="620">
</p>

**Recover to this Mac (⇧⌘R)** is for a new or wiped Mac. It walks four steps: find the drive or folder holding your backups, unlock the encrypted libraries with the recovery-key file you exported, choose the moment to rebuild to, and restore. Every library comes back as it was at that moment. A library that did not run that night contributes the last version it had before then, never a newer one. Otherwise you would get a Mac assembled out of different days.

<p align="center">
  <img src="docs/screenshots/recovery-point-in-time.png" alt="Recover to this Mac: choosing a moment, with the version each library had then" width="620">
</p>

In this example the moment is 2:00 AM on July 31. Photos, which runs nightly, contributes its July 31 version. Messages runs every few days at 3:00 AM, so its last version before that moment is the 28th; restoring its 31st would pull in changes that had not happened yet.

Both verify an archive before writing it. Recover to this Mac never overwrites anything already on the Mac, and neither does Restore unless you switch it to In place, which replaces the live library and moves the old one to the Trash. If something already has the name a library would come back under, you can restore alongside it under a new name.

Without Cryoframe, every destination has a plain-text note, "READ ME - How to restore without Cryoframe.txt", that says what is there and how to open it with tools built into macOS. For the day this Mac is gone, print a recovery kit from Settings ▸ Security: it lists every job and where its backups are, with each drive's name and volume UUID.

## How it works

```
  app (you, Full Disk Access)              helper (root LaunchDaemon)
  ───────────────────────────              ──────────────────────────
  create snapshot          ──── XPC ────▶  freeze the Data volume
  mount snapshot           ──── XPC ────▶  mount read-only
            ◀──── MountRef ────────────
  read the frozen library, archive it
  unmount + delete         ──── XPC ────▶  tear down
```

The privilege split is the core of the design. A root helper takes, mounts, and deletes the snapshot. The app reads the frozen library and writes the archive, running as you with Full Disk Access. Root does not bypass macOS privacy controls, so the reader needs Full Disk Access; the helper rides the app's grant for the snapshot mount.

Snapshot create runs through `tmutil localsnapshot`, which needs no special entitlement. The raw `fs_snapshot_create` syscall would need an Apple-granted entitlement that root alone does not satisfy, so Cryoframe uses the path that works for everyone. The snapshot is mounted immediately after creation, which pins it for the run regardless of how Time Machine thins its own snapshots.

## Project layout

- `CryoframeShared` — the XPC contract and shared types
- `CryoframeKit` — the engine: snapshot backends, content-type registry, archive engines, verification, targets, scheduling (covered by unit tests that run with fakes, so no root or snapshot is needed)
- `CryoframeHelper` — the root LaunchDaemon
- `Cryoframe` — the SwiftUI app
- `spike/` — the throwaway spikes that proved the snapshot and syscall approach
- `docs/guide/` — the user guide; `docs/` also holds design notes
- `scripts/` — build, install, icon, notarize, and DMG scripts

## Building and testing

```
xcodegen generate
xcodebuild test -scheme Cryoframe-Core -destination 'platform=macOS'
```

The engine is unit-tested without root. The archive and strong-verify tests shell out to `hdiutil`, `ditto`, `rsync`, and `sqlite3` against small fixtures; the full suite takes 15 to 20 minutes.

## Releasing

Maintainer steps to cut a notarized release:

```
xcrun notarytool store-credentials cryoframe-notary \
    --apple-id <your-apple-id> --team-id <your-team-id> --password <app-specific-password>   # once
./scripts/notarize.sh        # signed Release build, notarize, staple the app
./scripts/make-dmg.sh        # wrap in a DMG, sign, notarize and staple the DMG
```

The build number is stamped with the build time as `YYYYMMDD.HHMM` on every build. The marketing version is set by hand in `project.yml` (`MARKETING_VERSION`).

## Security notes

Cryoframe runs a root LaunchDaemon and reads protected libraries, so it asks for real trust. What it does and does not do:

- The helper runs as root only to create, mount, and delete APFS snapshots. It never reads library contents.
- The app and helper verify each other's code signature on every XPC connection, so only the signed app can talk to the helper.
- Cryoframe writes archives to wherever you point it. It does not upload anything. Cloud backup happens because you wrote the archive into a cloud-sync folder and the sync client uploads it.

## Not in scope

- Intel or universal builds. Apple Silicon only.
- The Mac App Store. The root helper, Full Disk Access, and snapshot mounts are incompatible with the App Sandbox.
- A built-in cloud uploader (direct S3, B2, or OAuth to a consumer cloud). That is deliberate. Cryoframe backs up to local drives, network shares, and cloud-sync folders. For an off-site copy, point a job at a sync folder (it detects the provider and splits sealed archives under that plan's single-file limit), or let two external drives take turns and keep one away from home.

## License

MIT. See [LICENSE](LICENSE).
