# Formats and destinations

[← Back to contents](README.md)

The format decides what the archive looks like on disk. The destination decides where it goes and how Cryoframe copies it there. The two interact, so they are covered together.

## Formats

### Live mirror (default)

A live mirror is a sparsebundle that updates in place. The first run copies the whole library. Every run after that rewrites only the bands that changed, so a nightly mirror of a large library finishes quickly. A mirror keeps one continuously-updated copy, not a history of versions.

Pick a live mirror for a frequent working backup of something that changes often, such as an Apple Music library or an active photo library.

A mirror can be paused mid-run.

### Sealed zip and sealed DMG

A sealed archive is one immutable file written once and never changed: a `.zip` or a read-only `.dmg`. Each run produces a new dated version, so a sealed job builds a history you can restore from. When the destination caps file size, a sealed archive splits into numbered volumes so it still fits.

Pick a sealed format for cold storage, for an archive you want to keep unchanged, or any time you want to keep multiple points in time. See [Versions, retention, and storage](versions-retention-storage.md).

A sealed DMG cannot be paused while it is being built. A sealed zip can.

### Choosing between them

Use a live mirror when you want one current copy and fast repeat runs. Use a sealed format when you want a fixed, verifiable file or a history of versions. A job can only have one format, but you can make two jobs for the same library if you want both.

## Destinations

When you add a destination you tell Cryoframe what kind of place it is. The kind changes how the copy is made.

### Local folder or volume

The archive is written straight to the destination. This is the simplest case and the fastest.

### Network share or external drive

A long copy to a share or a bus-powered drive can be cut off by a dropped connection or an unplugged cable. Choose "Network or external drive" when you add the destination, and Cryoframe makes the transfer resumable. This matters most for sealed archives, which are large single files.

How it works:

- The archive is built locally first, in a scratch location, then shipped to the destination in numbered parts. The default part size is 2 GB, set in Settings ▸ Transfers.
- If the link drops, the next run (or the next time the drive reconnects) continues from the last whole part instead of starting over. There is no re-snapshot and no rebuild.
- Building locally needs scratch space of about one archive. The scratch location is in Settings ▸ Transfers and defaults to your system cache.
- A sealed archive lands as parts named `Library.dmg.part.000`, `.001`, and so on. To use it by hand, join the parts first: `cat Library.dmg.part.* > Library.dmg`. The Restore window does this for you automatically.

A live mirror to a share resumes differently: there are no parts, so an interrupted mirror just continues on the next run.

### Cloud-sync folder

The archive is written into a folder managed by a sync client — OneDrive, Dropbox, Google Drive, Box, or iCloud Drive — and the client uploads it on its own schedule. Cryoframe does not manage the upload, so a dropped connection is the sync client's job to resume.

When you add a cloud-sync destination, Cryoframe detects which provider the folder belongs to (it looks under `~/Library/CloudStorage`) and asks which plan you're on, so it can split sealed archives under that plan's single-file limit. Those limits differ a lot: **iCloud Drive caps at 50 GB**, **Box at 5 GB** on Free/Starter (50 GB on Business, 150 GB on Enterprise), and the rest around 250 GB. Pick the plan that matches your account — too high and the provider rejects an oversized part — or enter a custom size. Detected cloud folders appear as one-click choices in the Add destination menu.

A thing to know about cloud-sync as a backup target: these clients offload files to save local space (Dropbox Smart Sync, OneDrive Files On-Demand, Google Drive streaming). After your archive uploads, its local copy may be replaced with a placeholder. Reading it then re-downloads it. So:

- A scheduled health check skips an offloaded cloud archive rather than silently pulling it back down, and notes it as "not downloaded." Turn on Settings ▸ General ▸ Archive health ▸ "Download cloud archives to check them" to verify them anyway.
- A restore from a cloud folder downloads whatever it needs, which is expected — you are getting the data back.

A cloud-sync folder is a fine *second* copy for off-site reach. For the primary, a local or network destination that keeps a full local copy is faster to verify and restore.

## A note on free space

Before a run, Cryoframe checks that the destination has room and stops with a clear message if it does not, rather than failing partway through. On a network share or a non-APFS volume, macOS sometimes does not report free space at all. In that case Cryoframe lets the run proceed rather than block a backup it cannot measure, so the copy itself reports a full disk if one ever occurs.
