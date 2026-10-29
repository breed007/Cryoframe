# Health and verification

[← Back to contents](README.md)

A backup you cannot read is not a backup. Cryoframe checks archives at two points: right after writing one, and again later while it sits in cold storage. This page covers both.

## Verification at write time

Every archive gets a checksum manifest when it is written, listing each file and its hash. This is always on. It is how Cryoframe knows later whether an archive still matches what was written.

"Check each backup", under Details in the job editor, sets how far the check after writing goes:

- Quick check hashes the archive after writing and compares it to the manifest. This is the default.
- Full check (opens it) does that, then also mounts the finished archive and confirms the library's database opens clean. It is slower, and it catches the case where the bytes are intact but the library itself is damaged.

Set it when you make the job, or set a default in Settings ▸ General.

A live mirror also reads back what each run copied before it puts the new copy in place, comparing contents, attributes, and access lists. A difference fails the run and leaves the previous mirror as it was. A plain-files copy is read back the same way, as far as its drive keeps those details.

## Archive health (re-checking cold archives)

Stored archives can rot. A bit flips, a drive drops a file, a NAS quietly loses a block. The data looked fine the day it was written and is broken the day you need it. Archive health re-reads existing archives against the checksums recorded when they were made, so you find the damage early.

### Running a health check

Check a single job any time from its ⋯ menu with Verify archives. Check every job at once with Verify all archives in the menu-bar item. Verify all runs the jobs one after another so it does not saturate the disk.

To run health checks on their own, set a schedule in Settings ▸ General ▸ Archive health: off, weekly, or monthly.

### Scope

The Scope setting next to the schedule controls how much each check covers:

- Latest version only checks the newest archive per library. This keeps the work down on a job that keeps many versions.
- All versions re-checks every version. It is thorough and slower.

For a job with a long retention history, Latest version only is usually the right balance. Use All versions when you want to audit the whole archive set.

### Results

Each job shows its last health check. A failure turns the menu-bar item red and sends a notification, so a silent corruption does not stay silent. The check reports which library and which version failed and why.

### Restore drills

A checksum check proves the bytes haven't rotted. It does not prove the archive will actually restore: that the split parts reassemble, the image mounts, and the library reopens. A restore drill does exactly that: for each archive it reassembles the parts, mounts or extracts it, and reopens the library (a database integrity check on Photos, Music, and other database libraries). If anything in the restore path is broken, the drill fails even when the checksums pass.

Set the depth in Settings ▸ General ▸ Archive health: Checksum (fast, the default) or Restore drill. The depth applies to the scheduled check and respects the same scope. You can also run a drill on demand from a job's ⋯ menu (Run restore drill), alongside the checksum-only Verify archives. An encrypted job's drill reads its passphrase from the Keychain, so it runs without prompting.

A drill is heavier than a checksum check, since it opens every archive in scope, so "Latest version only" is usually the right scope for a scheduled drill on a job with many versions.

### Recovery rehearsals

A drill proves an archive opens. It cannot prove a *recovery* works, because it looks for each archive at the path the job says it should be. If a destination is reorganized, a library folder renamed, or a job quietly stops writing one library, the drill keeps checking the paths it computed and keeps passing, while someone restoring on a new Mac would find nothing there.

A rehearsal starts where a recovery starts. It scans the destination, works out the newest moment it could restore to, and for each library verifies the checksums, opens the archive, and confirms there is something readable inside. It stops before copying anything back: moving the bytes is the slow part, and finding the archives, matching the keys, choosing the versions and opening them is the part that goes wrong.

What it adds is the question no per-archive check can answer: **is everything you think you're protecting actually here?** A library your jobs claim to back up that a restore would not find is named in the result. An empty destination fails loudly rather than reporting that nothing went wrong.

Rehearsals run monthly, and you can run one at any time from a job's ⋯ menu (Rehearse recovery…). Only the newest version of each library is opened, so the work depends on how much you protect rather than how long you have kept it. Turn the schedule off in Settings ▸ General ▸ Running.

### Stopping a check

While a job's archives are being checked, its row shows Stop. A check, drill, or rehearsal you stop doesn't count: it isn't recorded as a pass, no version gets a badge from it, and the last check that finished still stands. Anything it had already found wrong is still listed, with how many archives it got through. Stop never interrupts a disk image while macOS is attaching it; the attach finishes and is then detached.

### What a check tells the restore timeline

Every check records its result per version, and the [restore timeline](restoring.md) shows it: a version a drill opened is marked **Restore-tested**, one whose checksums were re-read is marked **Checksum verified**, and one nothing has looked at yet carries no badge at all.

That last case is the point of keeping them separate. Scheduled checks default to the latest version only, so on a job with a long history most versions have never been read, and a badge on those would be a claim Cryoframe cannot support. If you want the whole history badged, set the scope to all versions, knowing it costs proportionally more I/O.

A version is only marked when every copy checked in that run passed. If a job writes to two destinations and one copy has rotted, the version stays unbadged rather than vouching for a copy that might be the one you restore from.

### Cloud archives that have been offloaded

A cloud-sync client may replace a local archive with a placeholder to save space. Reading it re-downloads it. So a scheduled health check or drill **skips** an offloaded cloud archive rather than silently pulling gigabytes back down, and reports it as "not downloaded". That is neither a pass nor a failure, just "couldn't check it without downloading." Turn on "Download cloud archives to check them" (Settings ▸ General ▸ Archive health) to download and verify them anyway. Either way, an on-demand check from the ⋯ menu honors the same setting.

### What gets verified, exactly

A sealed archive is verified byte for byte against its checksums, so a single flipped bit is caught.

A live mirror is verified structurally: its files and their sizes are compared to the manifest. This catches dropped or truncated files, which are the common mirror failures. A change inside an otherwise intact file is left to the mirror's own check for decay, below, because hashing the whole mirror at every check would mean reading the entire drive each time.

### Live mirrors: the check for decay

A drive can change data it was given without anyone writing to it. That is decay, sometimes called bit rot, and it usually means the drive is failing. Nothing reports it until the damaged file is opened, and on an encrypted mirror the changed data reads as garbage without any error.

So every run of a live mirror also checks part of the mirror for decay. A mirror's disk image is stored on the drive as many small pieces called bands. After each run, Cryoframe reads the bands that run wrote and records a fingerprint of each. It also reads some of the bands no run has written since, and compares them with their fingerprints, oldest checked first. A band that hasn't been read yet, such as one in a mirror checked for the first time, gets its fingerprint when its turn comes. Each run reads its share of the mirror, so that the whole mirror is read about once every 30 days, and never less than 512 MB. A job that runs often reads more than that: an hourly job reads at least 512 MB each run, about 12 GB a day. The check of each mirror spends at most 10 minutes a run. The limit is per mirror and per drive, so a job that backs up three libraries to two drives can spend up to an hour on it. You can change the limit in Settings ▸ General ▸ Archive health. A run that is cut short or missed loses nothing, since the next one carries on where it stopped. A drive that takes turns in a rotation keeps its own record, and picks up where it left off when it comes back.

The check reads the bands as they are on the drive, so an encrypted mirror is checked without its passphrase, and nothing is attached. A mirror in a cloud folder is checked only when "Download cloud archives to check them" is on, since reading it would download it.

The run's summary in History says how much it checked, for example "checked 3% of the mirror for decay; all of it within the last 29 days". The Storage window shows how much of each drive's mirror has been checked: "Whole mirror checked for decay within the last 29 days", or, during the first month, "61% of the mirror checked for decay so far".

<!-- SHOT: storage-mirror-history.png — Storage with a live-mirror job expanded: the mirror's row, the "· Mirror history" row with its count, about size and Delete… menu, and under the run trend the line "Whole mirror checked for decay within the last 29 days" (the same image as in versions-retention-storage.md) -->

If a band no longer matches, the run fails and says which bands changed, you are alerted as you are for any failed backup, and the dashboard turns red. The mirror is marked damaged: health checks fail it, Restore warns before using it, and its job's runs are refused, because updating a damaged image would hide the problem rather than fix it. To recover, open Storage and choose **Start This Mirror Over** for that mirror. The next run makes a new mirror from the library. The damaged image is kept, hidden in the mirror's folder, until the new one is complete, and is then deleted. That needs room on the drive for both. If there isn't enough, Storage says how much the new mirror needs and offers to remove the damaged mirror first, which leaves the drive with no backup of that library until the new mirror is complete. The run checks the room again before it starts over, and if there still isn't enough it fails and says so, without changing anything. If a new mirror runs out of room before it is complete, Storage offers **Remove Damaged Mirror**, and the new mirror then carries on where it stopped. If the drive is failing, move the job to another drive instead.

A band that can't be read at all isn't decay. That happens when a drive is unplugged during the check, a network share times out, or a file in a cloud folder can't be downloaded. The check skips that band and goes on, and the next check tries it again first. Nothing is marked damaged, and the run isn't failed for it. A band that still hasn't read after three checks in a row may be on a part of the drive that is failing: the run's summary names it, and the dashboard shows the job with a warning. If three bands in a row that read before can't be read now, the drive has most likely gone away, so the check ends there and the run's summary says the mirror couldn't be checked and why. What it read before that still counts.

A band whose date changed since it was recorded was written since then, for example by an older version of Cryoframe after a downgrade. It is recorded again, not reported. The check can't say which files a damaged band belonged to without opening the image.

A plain-files copy has no checksums to compare: it was read back against the library when it was last updated. A health check confirms the copy is there and that its last update finished. A copy whose last update was stopped part way is skipped rather than counted either way, and the next backup finishes it.
