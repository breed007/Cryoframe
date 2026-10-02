# Formats and destinations

[← Back to contents](README.md)

The format decides what a backup looks like on disk. The destination decides where it goes and how Cryoframe copies it there. The two interact, so they are covered together.

## Formats

In the job editor, "Each backup keeps" offers two choices: one up-to-date copy, or dated versions. Dated versions come as disk images or zip files.

### One up-to-date copy (live mirror)

A live mirror is a sparsebundle disk image that updates in place. The first run copies the whole library. Every run after that rewrites only the bands that changed, so a nightly mirror of a large library finishes quickly. A mirror keeps one copy, not a history of versions.

Pick it for a frequent working backup of something that changes often, such as an Apple Music library or an active photo library.

A mirror doesn't ask for a size. It sizes itself to the library, grows as the library does, and never grows past what its drive can hold. A run that won't fit beside the drive's reserve is refused before it starts, with a message saying so.

Each run updates a copy of the mirror and swaps it in only when the copy is complete and has been read back against the library. If a run is stopped, fails, or the drive fills partway through, the mirror you had before is still there, whole. Reading the copy back costs some time: in testing, about 17% on a run that changed 2 GB.

A mirror can be paused mid-run. Named pipes, sockets, and device files in a library are left out of the mirror, because they only mean something while a program is running.

### Dated versions (sealed DMG and sealed zip)

A sealed archive is one immutable file written once and never changed: a read-only `.dmg` or a `.zip`. Each run produces a new dated version, so a sealed job builds a history you can restore from. When the destination caps file size, a sealed archive splits into numbered volumes so it still fits. Each version made by 1.6 or later also carries a list of its files, which is what lets [Find a File](restoring.md#find-a-file) search it.

Pick dated versions for cold storage, for a backup you want to keep unchanged, or any time you want to keep more than one point in time. See [Versions, retention, and storage](versions-retention-storage.md).

A sealed DMG cannot be paused while it is being built. A sealed zip can.

Some folders can't go straight into a sealed archive. A folder holding named pipes or sockets is first copied without them, then sealed from the copy. For a disk image, the same applies to append-only items and, on macOS 15, to locked files. The copy needs room in the scratch location (see below) on top of the archive itself, and an encrypted job's copy is always made on the startup disk, so an unencrypted copy of an encrypted job never lands on another drive. Before building a DMG, Cryoframe names anything in the library that would stop the image from being built.

### Choosing between them

Use one up-to-date copy when you want fast repeat runs of something that changes often. Use dated versions when you want a fixed, verifiable file or a history. A job keeps backups one way, but you can make two jobs for the same library if you want both.

Changing an existing job from one to the other doesn't throw away what it made. Versions already in its folder are shown as "Kept" and nothing deletes them; a mirror left behind by a job that now keeps dated versions is kept the same way.

## Destinations

Click Add destination… in the job editor and choose a folder. Cryoframe works out what kind of place it is from the drive it's on, so you don't have to say:

- a folder on this Mac's startup disk,
- a folder on an external drive,
- a folder on a network share,
- or a cloud-sync folder, which can also be picked from the Cloud folders menu.

<!-- SHOT: add-destination.png — the Copies go to section after Add destination…, with the main badge and the Cloud folders menu -->

A destination is known by its drive's volume UUID as well as its path. A drive that's been renamed, or mounts as "T7 1" because another drive took its name, is still found. A different drive that happens to have the same name isn't used by mistake.

Every destination gets a plain-text note at its top, "READ ME - How to restore without Cryoframe.txt", saying what's in that folder and how to open each backup with tools built into macOS. It is rewritten after each run from what the folder actually holds, and has no passphrases or paths outside the folder in it.

### This Mac

The backup is written straight to the destination. This is the simplest case and the fastest.

### Network share or external drive

A long copy to a share or a bus-powered drive can be cut off by a dropped connection or an unplugged cable, so Cryoframe makes these transfers resumable. This matters most for sealed archives, which are large single files.

How it works:

- The archive is built locally first, in a scratch location, then shipped to the destination in numbered parts. The default part size is 2 GB, set in Settings ▸ Transfers.
- If the link drops, the next run (or the next time the drive reconnects) continues from the last whole part instead of starting over. There is no new snapshot and no rebuild. An interrupted transfer only resumes on the drive it started on, and a transfer counts as complete only once every part has been checked.
- Building locally needs scratch space of about one archive. The scratch location is in Settings ▸ Transfers and defaults to your system cache.
- A sealed archive lands as parts named `Library.dmg.part.000`, `.001`, and so on. To use it by hand, join the parts first: `cat Library.dmg.part.* > Library.dmg`. The Restore window does this for you.

A live mirror to a share resumes differently: there are no parts, so an interrupted mirror just continues on the next run.

### The scratch location

If you choose your own scratch location, Cryoframe works only inside a folder of its own there, named Cryoframe Scratch, and removes only what it marked as its own.

Before 1.6, Cryoframe deleted any `<folder>/build/<item>` in the scratch location each time it launched. In the default location that was harmless, but a scratch location that held other things, such as `~/Developer`, lost other projects' build output. If you ever changed the scratch location, check that folder. Leftovers from 1.5 in a custom location are listed in Settings ▸ Transfers rather than deleted.

### Cloud-sync folder

The backup is written into a folder managed by a sync client (OneDrive, Dropbox, Google Drive, Box, or iCloud Drive), and the client uploads it on its own schedule. Cryoframe does not manage the upload, so a dropped connection is the sync client's job to resume.

When you add a cloud-sync destination, Cryoframe detects which provider the folder belongs to (it looks under `~/Library/CloudStorage`) and asks which plan you're on, so it can split sealed archives under that plan's single-file limit. Those limits differ a lot: **iCloud Drive caps at 50 GB**, **Box at 5 GB** on Free/Starter (50 GB on Business, 150 GB on Enterprise), and the rest around 250 GB. Pick the plan that matches your account (too high and the provider rejects an oversized part) or enter a custom size.

These clients offload files to save local space (Dropbox Smart Sync, OneDrive Files On-Demand, Google Drive streaming). After your archive uploads, its local copy may be replaced with a placeholder. Reading it then downloads it again. So:

- A scheduled health check skips an offloaded cloud archive rather than silently pulling it back down, and notes it as "not downloaded." Turn on Settings ▸ General ▸ Archive health ▸ "Download cloud archives to check them" to verify them anyway.
- A restore from a cloud folder downloads whatever it needs before opening it, which is expected: you are getting the data back.

Storage shows, for each cloud destination, whether its versions have been uploaded. See [Versions, retention, and storage](versions-retention-storage.md#cloud-upload-status). Until a provider proves it, the answer is "Upload not known", in gray, and that is normal.

A cloud-sync folder is a fine *second* copy for off-site reach. For the main destination, a local or network destination that keeps a full local copy is faster to verify and restore.

## Drives that take turns

Rotating backup drives (one at home, one away, swapped every so often) is a good way to keep a copy off-site. In the job editor, add each drive as a destination, then open one drive's menu and choose Takes turns with and the other drive. The pair counts as one destination: each backup goes to whichever drive is connected, and the one that's away is shown as "away" rather than as a problem. Stop taking turns splits them again.

<!-- SHOT: takes-turns.png — a destination's menu with Takes turns with, and a pair showing the takes turns badge and one drive away -->

### Two drives with the same name, from 1.5

Before 1.6, the only way to take turns was to give two drives the same name. 1.6 knows drives by their identity, so it sees two different drives. When the other one is connected, the job editor shows Is this one of your drives?… on that destination, and you can choose:

- Take turns under one name: both drives keep the name, and the job uses whichever is connected.
- Rename this drive…: the connected drive gets a name of its own, and a new destination on it takes turns with the original. Renaming changes only the drive's name, not what's on it. Before you rename, the editor shows what the next backup to that drive will do there. Apps or scripts that find the drive by its path may lose it, since the path changes with the name.

## A note on free space

Before a run, Cryoframe checks that the destination has room and stops with a clear message if it does not, rather than failing partway through. On a network share or a non-APFS volume, macOS sometimes does not report free space at all. In that case Cryoframe lets the run proceed rather than block a backup it cannot measure, so the copy itself reports a full disk if one ever occurs.
