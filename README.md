# Cryoframe

Back up live macOS media libraries into sealed, verifiable archives, on a schedule, without quitting the app that owns the library.

macOS 15+ · Apple Silicon · MIT licensed

---

## The problem it solves

The hard part of backing up a media library is not the copy. It is taking a consistent point-in-time copy of a library whose database is being written to while the backup runs. If you zip a `.photoslibrary` while Photos has its database open, you can seal a half-written, corrupt database into the archive. The backup looks fine until the day you need it.

Cryoframe avoids that with APFS snapshots. For each run it freezes the volume, mounts the snapshot read-only, archives the library from that frozen copy, then deletes the snapshot. The library stays open the whole time, and the archive is a consistent moment in time.

It also verifies. Every archive gets a checksum manifest, and the strong mode mounts the finished archive and runs a database integrity check, so you find out a backup is bad now instead of during a restore.

## Features

- Consistent snapshots of live libraries using APFS, created and torn down per run.
- Two output formats: a sealed DMG or zip (immutable, checksummed, split into volumes when the target caps file size), or an incremental sparsebundle mirror that only rewrites the bands that changed.
- Verification built in: a checksum manifest on every archive, plus an optional mount-and-open check that confirms the library's database opens clean. Cold archives can be re-verified later.
- Targets for local disks, network shares, and cloud-sync folders, each with its own size cap and an availability preflight so a run never starts against an unmounted drive.
- Scheduling through a launchd agent, with per-job control over what happens if the owning app is open.
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
| Mail | `~/Library/Mail` | Mail |
| Microsoft Outlook | default Outlook profile | Outlook |

Templates (you point at the library, since these live anywhere — often on external drives):

- Final Cut Pro libraries
- Lightroom Classic catalogs
- Capture One catalogs
- Logic Pro projects

Anything else: point at any folder with "Add library", and it is treated as static content.

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

Set `DEVELOPMENT_TEAM` in `project.yml` to your own Team ID first — the privileged helper will not register without a Developer ID. The `.xcodeproj` is generated and gitignored; edit `project.yml`, never the project file. To build, sign, and install in one step:

```
./scripts/build-and-install.sh
```

## First run

Three one-time steps, shown at the top of the window:

1. Enable the helper. This installs the background service that takes snapshots. Approve it in System Settings ▸ Login Items when asked, and authenticate (installing a root service needs admin).
2. Grant Full Disk Access to Cryoframe, then relaunch. The dot turns green once it can read protected libraries. Full Disk Access is required because a snapshot of Photos content is still Photos content as far as macOS privacy controls are concerned.
3. Enable the schedule if you want jobs to run in the background.

## Using it

Press New Job and pick a library, a destination, a format, and how often to run. Every field has a tooltip.

Formats:

- Sealed DMG or zip. One immutable, checksummed file for cold storage. Larger than the target's cap splits into volumes, so it fits cloud single-file limits.
- Live mirror. A sparsebundle with about 8 MB bands. The first run copies everything; later runs only write the bands that changed.

Verification:

- Checksum hashes every archive after writing. Always on. A manifest (`cryoframe-manifest.json`) is written next to the archive.
- Mount and open also mounts the finished archive and runs a SQLite integrity check on the library's database. This is the strong check for live-database libraries.

Schedule and run policy:

- Daily at a set time, every N hours, once, or manual.
- "If app is open" controls what happens when the owning app is running. The default is proceed, because the snapshot is already consistent. Choose warn or defer if you would rather skip a run while the library is in use.

The Help button in the app has worked examples for Apple Photos and Apple Music.

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
- `docs/` — design notes
- `scripts/` — build, install, icon, notarize, and DMG scripts

## Building and testing

```
xcodegen generate
xcodebuild test -scheme Cryoframe-Core -destination 'platform=macOS'
```

The engine is fully unit-tested without root. The archive and strong-verify tests shell out to `hdiutil`, `ditto`, and `sqlite3` against tiny fixtures, so the suite takes about half a minute.

## Releasing

Maintainer steps to cut a notarized release:

```
xcrun notarytool store-credentials cryoframe-notary \
    --apple-id <your-apple-id> --team-id <your-team-id> --password <app-specific-password>   # once
./scripts/notarize.sh        # signed Release build, notarize, staple the app
./scripts/make-dmg.sh        # wrap in a DMG, notarize and staple the DMG
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
- A built-in cloud uploader. Write to a cloud-sync folder instead.
- A guided restore UI. Archives are openable artifacts, and the mount-and-open check confirms they reopen.

## License

MIT. See [LICENSE](LICENSE).
