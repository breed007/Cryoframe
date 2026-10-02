# Updating and troubleshooting

[← Back to contents](README.md)

## Updates

Cryoframe updates itself. Choose Check for Updates from the menu-bar item, or let it check on its own. When a new version is available it downloads and installs it for you.

Updates are signed with an Ed25519 key and the signature is verified before anything installs, so a tampered or corrupt download is refused. The update feed is public and the binaries come from the project's GitHub releases.

## Troubleshooting

### The helper dot is gray

The helper has not registered. Quit and reopen Cryoframe; it registers on launch. If it stays gray, check System Settings ▸ General ▸ Login Items and make sure Cryoframe's background item is allowed.

### A job fails to read a library

This is almost always Full Disk Access. Open System Settings ▸ Privacy & Security ▸ Full Disk Access, confirm Cryoframe is on, and relaunch. See [Getting started](getting-started.md).

A job can also fail to read a library that has moved. The job row shows a red mark when a library is missing, with a link to fix a built-in library's location in Settings.

### A backup to a NAS or external drive stops with "not enough space"

If the destination genuinely has room, this should not happen on the current version. Earlier behavior could misread free space on network and non-APFS volumes, which report space differently than a local disk. If you see it, update to the latest version. A reported free space of zero is now treated as "unknown, let the run proceed" rather than "full."

### A run was interrupted and left parts behind

A sealed transfer to a share or drive writes numbered parts and resumes from the last whole one. You do not need to clean anything up; the next run continues from where it stopped. A failed or canceled run that left a half-written version folder is swept on the next run and does not count toward retention.

### I lost an encrypted archive's passphrase

If the passphrase is still in this Mac's Keychain, get it from the job's ⋯ menu with Copy passphrase, or from a recovery file. Deleting a job doesn't remove its passphrase, so Restore can still offer it for that job's backups. If it is gone from both, the archive cannot be opened. This is by design. See [Encryption and recovery keys](encryption-and-recovery-keys.md), and export a recovery file for the encrypted backups you still can open.

### A restore or browse left a mounted volume behind

If Cryoframe quit while browsing an archive, a mounted image can be left attached. Cryoframe clears these on its next launch. You can also eject it in Finder.

### A live mirror sat at "archiving 99%" in 1.6.0

The run was working. In 1.6.0 a live mirror's progress came only from its disk image growing on the drive, and nothing after the copy makes it grow: finishing the copy, writing it out to the drive, and reading everything back to check it. Those steps showed as "archiving 99%" at "Zero KB/s" for as long as they took, which on a first run to an SD card was up to an hour. From 1.7 the row names each of those steps and shows how far it has got, and Stop works in each.

### A live mirror failed every run with "Permission denied"

In 1.6.0, once a file was deleted from a read-only folder in the library (permissions 0555, as in Go's module cache), or such a folder was deleted, every later run of that job's live mirror failed with "unlinkat: Permission denied". Nothing was lost: the mirror from before stayed whole. 1.7 fixes it, and the next run brings the mirror up to date.

### A plain-files run says some items weren't copied

A drive that isn't a Mac's can't hold everything a Mac library can: a file of 4 GB or more on FAT32, two names that differ only in capitals or accents, a name a network drive refuses. The run copies the rest and names each item it left out, with the reason. See [the limits of exFAT, FAT32, and network drives](formats-and-destinations.md#limits-of-exfat-fat32-and-network-drives).

### The editor won't keep Photos as plain files on a drive

An app's library can only be kept as plain files on an APFS drive connected to this Mac. On any other drive the editor says why and won't save the job. Keep that library as a disk image on that drive instead. See [App libraries](formats-and-destinations.md#app-libraries).

### A run stopped with "made no progress"

A tool that makes no progress for 15 minutes is stopped so the run doesn't hold its snapshot forever. A drive or share that stopped answering is the usual cause. Check the destination is connected and responding, then run the job again.

### I set a custom scratch location before 1.6

Versions before 1.6 deleted any `<folder>/build/<item>` inside the scratch location at every launch. The default location was safe, but a custom one that held other things lost them. Check Settings ▸ Transfers: if the scratch location is a folder you use for anything else, look for missing build folders there. 1.6 works only inside its own Cryoframe Scratch folder and lists any leftovers from 1.5 instead of deleting them.

### Going back to 1.5.6

1.5.6 still runs your jobs and reads your backups. Two things don't survive the round trip: any go-ahead you gave for deleting backups from an earlier version (you're asked again, and nothing is deleted meanwhile), and a renamed library's former names, so a drive that was away during the rename may get a second folder beside the old one.

### Going back to 1.6.0

1.6.0 still runs your other jobs and reads your backups, with these exceptions:

- Plain-files jobs are kept in a file of their own, `jobs-files.json`, which 1.6.0 doesn't read and leaves alone. They don't appear or run in 1.6.0, and they're back when you return to 1.7. Their copies stay on the drives as ordinary files.
- Opening Storage in 1.6.0 erases the run trend of plain-files jobs, so their bars start again.
- 1.6.0 backs up Messages attachments as an ordinary folder. It copies link previews, and it keeps nothing you delete in Messages: a live mirror drops those files, and pruning deletes old versions without saving them first. Removed items and removed-items archives made by 1.7 are left as they are.

### Reporting a problem

Choose Help ▸ Report a Problem… (or the button at the bottom of the Help window). Cryoframe builds a plain-text report for a GitHub issue: the versions of Cryoframe and macOS, how your jobs are set up, and what recent runs and checks said. Your names, paths, file names, and passphrases are left out; jobs, folders, and destinations are numbered instead. You read the report before you save it, and nothing is sent anywhere until you attach it to an issue yourself.

### Where to look when something goes wrong

The History button lists every run with its recorded error, which is the specific reason a run stopped. The Activity list on the main window narrates runs as they happen; Clear empties it without touching History. Between the two, most failures explain themselves.
