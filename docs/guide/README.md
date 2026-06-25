# Cryoframe user guide

Cryoframe backs up a live media library by freezing it with an APFS snapshot and archiving the frozen copy. Because the snapshot is a point-in-time picture of the disk, you can back up Photos or Apple Music while they are open without sealing a half-written database into the archive.

This guide covers everything the app does. If you just want to get a backup running, read [Getting started](getting-started.md) and stop there. The rest is here when you need it.

## Contents

1. [Getting started](getting-started.md): install the helper, grant Full Disk Access, make your first job.
2. [Jobs](jobs.md): create, run, pause, stop, edit, and schedule backups.
3. [Formats and destinations](formats-and-destinations.md): live mirror vs sealed zip or DMG, and where the archives go.
4. [Encryption and recovery keys](encryption-and-recovery-keys.md): AES-256 archives and the master-password escrow file.
5. [Versions, retention, and storage](versions-retention-storage.md): keep a history of a library, and watch disk use.
6. [Health and verification](health-and-verification.md): prove an archive is still good before you need it.
7. [Restoring](restoring.md): copy a library back, replace it in place, or pull out a few files.
8. [Scheduling, sleep, and notifications](scheduling-sleep-notifications.md): run unattended and find out how it went.
9. [Updating and troubleshooting](updating-troubleshooting.md): in-app updates and fixes for common problems.

## Requirements

Cryoframe runs on macOS 15 (Sequoia) or later, on Apple silicon. It needs Full Disk Access to read protected libraries like Photos, and it installs a small background helper that takes the snapshots. Both are one-time steps covered in [Getting started](getting-started.md).

## How a backup works, in one paragraph

You make a job that names one or more libraries, a destination, and a format. When the job runs, the helper takes a single APFS snapshot that captures every selected library at the same instant. Cryoframe reads the libraries out of that snapshot, writes each one to its own folder at the destination, records a checksum manifest, and then deletes the snapshot. Nothing about your live libraries changes. The snapshot is gone within seconds of the run finishing.
