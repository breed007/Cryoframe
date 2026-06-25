# Jobs

[← Back to contents](README.md)

A job is one backup definition: which libraries to capture, where to put them, in what format, and how often. The main window lists your jobs, each with its last result and next run time.

## Making a job

Click New Job. Every library you check is frozen in a single snapshot and archived together, each into its own folder at the destination, so the set is consistent to the same instant. A job can hold one library or a dozen.

The sheet also sets the format, the schedule, the verification level, and (optionally) encryption and a retention policy. Defaults for new jobs live in Settings ▸ General, so if you always want the same format or verify level, set it once there.

## Running a job

Run now starts a job immediately, whether or not it has a schedule. While it runs, the row shows live progress: the current library, bytes written, speed, time elapsed, and an estimate of time remaining.

You can run several jobs at once. The limit is in Settings ▸ General and defaults to 2. Snapshot creation is serialized inside the helper, so even with jobs running in parallel each one captures a clean point-in-time set.

## Pause, resume, and stop

Pause suspends the running tool in place and holds the snapshot, then Resume picks up where it left off. Pause is offered for live-mirror and sealed-zip archives and for transfers to a drive or share. It is not offered while a sealed DMG is being built, because the macOS disk-image tool crashes if it is frozen mid-write, so a DMG job shows only Stop during that stage.

Stop cancels a running or queued job and tears the snapshot down. A sealed archive cannot resume mid-build, so a stopped sealed job starts over next time. An interrupted transfer to a network share or external drive is the exception: it resumes from its last whole part when the drive reconnects. See [Formats and destinations](formats-and-destinations.md).

## The ⋯ menu

Each job's ⋯ menu holds:

- Edit, to change any setting.
- Disable schedule or Enable schedule. A disabled job has no next-run time and never runs on its own, but Run now still works.
- Verify archives, which re-checks the job's existing archives against their checksums. See [Health and verification](health-and-verification.md).
- Copy passphrase, shown only for an encrypted job that has a saved passphrase. See [Encryption and recovery keys](encryption-and-recovery-keys.md).
- Delete, which removes the job. It does not delete archives already written to the destination.

## Library status

Each job shows a green check when its libraries are found, or a red mark when one is missing, with a link to fix a built-in library's location in Settings. A library can go missing if you move it, rename it, or unplug the drive it lives on.

## Run history

Every run is recorded with its outcome, per-library detail, duration, size, and any error, and the record survives quitting the app. Each job row shows its last run at a glance. The History button at the top of the window lists every past run, including scheduled ones that happened while the app was closed.

If a job failed, History is the first place to look. The recorded error is the real reason the run stopped, which is usually more specific than the one-line summary on the job row.
