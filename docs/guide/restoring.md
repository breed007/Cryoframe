# Restoring

[← Back to contents](README.md)

Restoring reads a library back out of an archive. There are two doors, depending on what happened.

**Restore** (⌘R, or the Restore button) is for getting one library back: copy it out beside your live one, replace the live one in place, find which version holds a file, or pull a few files out of a version. **Recover to this Mac** (⇧⌘R) is for a new or wiped Mac, where you want everything back at once. It is covered at the end of this page.

If you don't have Cryoframe at hand, every destination has a note at its top, "READ ME - How to restore without Cryoframe.txt", that explains how to open each backup with tools built into macOS.

Everything here verifies an archive's checksums before writing anything, checks there is room first, and never overwrites what is already on the Mac unless you switch the restore to In place, which moves your current library to the Trash first. An archive in a cloud folder that the provider has offloaded is downloaded before it is opened.

## Find the archives

Point Restore at the folder that holds your archives, or use a Quick pick for a destination you back up to. Cryoframe lists the libraries it finds down the left side, each with how many versions it has and when the newest one was made. A lock marks an encrypted library; enter its passphrase once and it applies to every version.

## The timeline

Choose a library and its versions appear as a timeline, newest first, grouped into this week and earlier. Each version shows the day, the exact date and time, its size, and a bar comparing it with the other versions, so a night where a library suddenly grew or shrank is easy to spot.

Some versions carry a badge:

- **Restore-tested** means a restore drill reassembled that version, opened it, and reopened the library inside. The restore path itself is proven.
- **Checksum verified** means its checksums were re-read and matched. That confirms the bytes are intact, which is a weaker promise than proving it opens.
- **No badge** means nothing has checked that version yet. It is not a sign of trouble; it just means Cryoframe will not claim more than it knows. See [Health and verification](health-and-verification.md) to check them.
- **Kept** means the version is from before its job changed how it keeps backups. Nothing deletes it; see [Versions, retention, and storage](versions-retention-storage.md#kept-versions).

A live mirror has no timeline. It keeps one copy, updated in place, so there is a single state to restore: the current one. Cryoframe says so rather than showing a history that does not exist. If you want a history for that library, keep dated versions with a Keep rule; see [Versions, retention, and storage](versions-retention-storage.md).

Select a version and the bar at the bottom names exactly what will happen when you restore it.

<!-- SHOT: restore-timeline.png — the restore timeline with badges, including a Kept version, and the Find a File button -->
![The restore timeline: versions by night with sizes, and badges for restore-tested and checksum-verified](../screenshots/restore-timeline.png)

If an archive is encrypted, enter its passphrase. If the passphrase is still in this Mac's Keychain it is filled in for you. If not, get it from your recovery file. See [Encryption and recovery keys](encryption-and-recovery-keys.md).

## Copy a library out (the safe default)

Pick what to restore and a destination folder, then click Restore. Cryoframe verifies the checksums, mounts or extracts the archive, joins any split parts, and copies the library out with its original folder name.

The copy lands next to anything already in the destination. It never writes over your live library. If something there already has the library's name, the restore stops and says so, and Restore Alongside keeps what's there and brings the library back beside it under a new name, such as "Photos Library (2)". When it is done, move the restored library into place yourself, or double-click it to open in its app. This is the option to use when you are not certain, because it changes nothing you did not ask it to.

## Restore in place

Switch the restore bar from Beside to In place, and the version you picked goes back exactly where the live library is. This is for the case where the live library is damaged or gone and you want the archived copy to take over.

It is built to be safe. Cryoframe restores and verifies the archive into a staging copy first, and only once that copy is good does it move your current library to the Trash and swap the restored copy into place. If anything goes wrong before the swap, your live library is untouched. After the swap, the previous library is in the Trash, so the change is reversible.

Quit the app that owns the library first. Cryoframe checks for this and tells you if, for example, Photos is still running.

## Browse and extract a few files

Sometimes you do not want the whole library back, just a handful of files from inside it. Browse, on the restore bar, opens the selected version in an in-app file browser. You drill into folders, select the items you want, and extract just those to a folder you choose. The archive is mounted read-only while you browse and is unmounted when you close the browser.

A library package, like a `.photoslibrary`, shows as a single item you extract whole rather than a folder you walk into, because the package is meant to be handled as a unit.

## Find a File

When you know the file you want but not which night still had it, click Find a File… at the top of the Restore window. Type a name, such as "Taxes 2024.pdf", or part of a path, such as "Documents/Taxes". You can also paste a whole path: one copied from Finder, dragged into Terminal, or in quotes. Upper and lower case don't matter, and an accented name matches however it was written.

Cryoframe searches the list of files saved with each version, newest first, and shows what matched in each, with Stop if you've seen enough. Show opens that version in the file browser at the match, so you can extract it. Encrypted versions use the passphrase you type, and the one saved on this Mac for that job is tried too.

<!-- SHOT: find-a-file.png — Find a File with a query, matches in two versions, and one older version with no list -->

Not every version can answer:

- A version made before 1.6 has no file list, and neither does a live mirror. The search says so and offers Look inside…, which opens the version so you can browse it yourself.
- A list that's missing, damaged, or locked with a passphrase that doesn't open it is treated the same way: no list, rather than "not found".
- A list that was cut short (a very large library, or one read while it was changing) shows what it has, but never says a file isn't there.

Only a complete list that checks out says "Not in this version", so a miss there means the file really wasn't in that backup.

## Recovering a whole Mac

If the Mac is new, or you have wiped this one, you are not looking for one library. You want everything back the way it was. **Recover to this Mac** (⇧⌘R, the File menu, or the link on the empty main window) walks four steps.

**1. Find backups.** Point it at the drive, NAS, or cloud folder your archives were written to. It reports what it found: how many libraries, how many points in time, and how many are encrypted.

**2. Unlock.** Encrypted libraries need their passphrases, and on a new Mac they are not in the Keychain yet. Open the recovery file you exported and enter its master password, and every passphrase comes back at once. Without it you can still restore whatever is not encrypted; the locked libraries are named and skipped rather than failing the whole run. See [Encryption and recovery keys](encryption-and-recovery-keys.md).

**3. Point in time.** One slider chooses the moment to rebuild to, and each library shows the version it will contribute.

<!-- SHOT: recovery-point-in-time.png — Recover to this Mac: the point-in-time slider with each library's version -->
![Choosing a moment: one slider, and each library shows the version it had then](../screenshots/recovery-point-in-time.png)

This is the part worth understanding. Libraries rarely run on the same nights: Photos might back up nightly while a project folder runs weekly. When you choose a moment, each library contributes the newest version it had **at or before** that moment, never a later one. Pick Wednesday and a library whose last run was Monday gives you its Monday version, because that is what existed on Wednesday. Its Friday version holds changes that had not happened yet, so using it would rebuild a Mac that never existed. If a library is newer than the moment you chose and has nothing that old, it gives you its earliest version and says so.

<!-- SHOT: recovery-review.png — Recover to this Mac: the review step, with a Restore alongside choice for a clash -->
![The review step: what will be restored, from when, to where, and how much space it needs](../screenshots/recovery-review.png)

**4. Review.** Check what is about to happen. By default each library goes back to where its app looks for it, so Photos and Messages simply open what came back; use Change to put everything in one folder instead. Nothing already on this Mac is overwritten, each archive is verified before it is written, and a library that cannot be opened is skipped and reported while the rest still restore. If something is already where a library would go, you can restore that library, or all of them, alongside it.

## Split archives

A sealed archive sent to a network share or external drive arrives as numbered parts. Restore reassembles them for you, so you never need to join parts by hand. If you want to use the parts outside Cryoframe, join them first with `cat Library.dmg.part.* > Library.dmg` and then mount the result.
