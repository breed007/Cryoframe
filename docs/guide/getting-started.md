# Getting started

[← Back to contents](README.md)

Three one-time steps stand between a fresh install and a working backup. The main window shows their status across the top, with a colored dot for each.

## 1. Enable the helper

Cryoframe takes snapshots through a small background service that runs with elevated rights. The app cannot take a snapshot itself, so this service has to be installed once.

Click the helper status at the top of the window and approve the prompt. macOS then asks you to allow the login item in System Settings ▸ General ▸ Login Items. Turn it on. The dot turns green when the helper is registered and answering.

If the dot stays gray after you approve it, quit and reopen Cryoframe. The helper registers on launch.

## 2. Grant Full Disk Access

Photos, Apple Music, Messages, and several other libraries live in protected locations. macOS hides them from apps until you grant Full Disk Access, and that includes Cryoframe.

Open System Settings ▸ Privacy & Security ▸ Full Disk Access, turn Cryoframe on, and relaunch the app. The Full Disk Access marker in the top right turns green once the app can read protected libraries. The background helper rides on the same grant, so you only do this once.

Without Full Disk Access, a job that targets a protected library fails with a read error. Folders you own outside the protected set still work.

## 3. Enable the schedule (optional)

If you want jobs to run on their own, turn on the schedule. This installs a launchd agent that wakes about once an hour and runs any job that is due. Jobs only run while you are logged in.

You can skip this and run every job by hand with Run now. Scheduling is only needed for unattended backups.

## Make your first job

Click New Job. In the sheet:

- Check one or more libraries. Built-in libraries like Photos and Apple Music are listed first, followed by templates for apps like Final Cut and Lightroom, and an option to add any folder.
- Pick a destination. A local folder is the simplest. You can also choose a network share, an external drive, or a cloud-sync folder. See [Formats and destinations](formats-and-destinations.md).
- Pick a format. Live mirror is the default and is a good first choice. See [Formats and destinations](formats-and-destinations.md) for when to pick a sealed format instead.
- Choose how often it runs, or leave it on Manual.

Save the job, then click Run now once to confirm it works end to end. The job row turns green when the archive is written and verified. You do not need to quit Photos or Music first.

## What to read next

- [Jobs](jobs.md) for running, pausing, and managing backups.
- [Encryption and recovery keys](encryption-and-recovery-keys.md) if any backup leaves your Mac, for example to a NAS or a cloud folder.
- [Restoring](restoring.md) for getting a library back.
