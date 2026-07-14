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

Click New Job to open the guided wizard. You can also drag a folder onto the window to start one pre-filled.

![The guided wizard](../wizard-flow.svg)

The wizard walks four steps:

1. **What to back up.** Pick a template (Photos nightly, Music mirror) to set everything at once, or choose libraries yourself. Each library shows its size once measured.
2. **Where.** Choose one or more destinations. Each shows its free space, and the total to back up is checked against it — so you know it fits before you create the job. The first destination is the primary; the rest are extra copies.
3. **How often.** Every night, every few hours, or manual.
4. **Review.** Confirm what you're about to create. Advanced options — format, encryption, verification, and how many versions to keep — sit in an expandable section and are all editable; the defaults are set for a trustworthy backup.

Create the job, then click Run now once to confirm it works end to end. The job row turns green when the archive is written and verified. You do not need to quit Photos or Music first.

## The dashboard

Once you have a job, the top of the window is a status panel that answers "am I backed up?" at a glance: a green shield when everything is healthy, or an amber warning naming the job that needs attention. Below it are four figures — the last successful backup, the total size protected, the number of destinations, and free space on the tightest one — so you can see your headroom without opening anything.

## What to read next

- [Jobs](jobs.md) for running, pausing, and managing backups.
- [Encryption and recovery keys](encryption-and-recovery-keys.md) if any backup leaves your Mac, for example to a NAS or a cloud folder.
- [Restoring](restoring.md) for getting a library back.
