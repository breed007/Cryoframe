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

A sealed transfer to a share or drive writes numbered parts and resumes from the last whole one. You do not need to clean anything up; the next run continues from where it stopped. A failed or cancelled run that left a half-written version folder is swept on the next run and does not count toward retention.

### I lost an encrypted archive's passphrase

If the passphrase is still in this Mac's Keychain, get it from the job's ⋯ menu with Copy passphrase, or from a recovery file. If it is gone from both, the archive cannot be opened. This is by design. See [Encryption and recovery keys](encryption-and-recovery-keys.md), and export a recovery file for the encrypted backups you still can open.

### A restore or browse left a mounted volume behind

If Cryoframe quit while browsing an archive, a mounted image can be left attached. Cryoframe clears these on its next launch. You can also eject it in Finder.

### Where to look when something goes wrong

The History button lists every run with its recorded error, which is the specific reason a run stopped. The activity log on the main window narrates runs as they happen. Between the two, most failures explain themselves.
