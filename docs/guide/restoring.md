# Restoring

[← Back to contents](README.md)

Restoring reads a library back out of an archive. Cryoframe gives you three ways to do it: copy the library out beside your live one, replace the live one in place, or browse inside the archive and pull out a few files. All three verify the archive's checksums first.

Open the Restore window with the Restore button at the top of the main window.

## Find the archives

Point Restore at the folder that holds your archives, or use a Quick pick for a destination you back up to. Cryoframe lists the libraries it finds, with their format, date, and size. A sealed job shows each dated version, so you can choose a point in time. A lock marks an encrypted archive.

If an archive is encrypted, enter its passphrase. If the passphrase is still in this Mac's Keychain it is filled in for you. If not, get it from your recovery file. See [Encryption and recovery keys](encryption-and-recovery-keys.md).

## Copy a library out (the safe default)

Pick what to restore and a destination folder, then click Restore. Cryoframe verifies the checksums, mounts or extracts the archive, joins any split parts, and copies the library out with its original folder name.

The copy lands next to anything already in the destination. It never writes over your live library. When it is done, move the restored library into place yourself, or double-click it to open in its app. This is the option to use when you are not certain, because it changes nothing you did not ask it to.

## Restore in place

Each archive's ⋯ menu offers Restore in place, which puts the library back exactly where the live one is. This is for the case where the live library is damaged or gone and you want the archived copy to take over.

It is built to be safe. Cryoframe restores and verifies the archive into a staging copy first, and only once that copy is good does it move your current library to the Trash and swap the restored copy into place. If anything goes wrong before the swap, your live library is untouched. After the swap, the previous library is in the Trash, so the change is reversible.

Quit the app that owns the library first. Cryoframe checks for this and tells you if, for example, Photos is still running.

## Browse and extract a few files

Sometimes you do not want the whole library back, just a handful of files from inside it. The ⋯ menu's Browse contents opens the archive in an in-app file browser. You drill into folders, select the items you want, and extract just those to a folder you choose. The archive is mounted read-only while you browse and is unmounted when you close the browser.

A library package, like a `.photoslibrary`, shows as a single item you extract whole rather than a folder you walk into, because the package is meant to be handled as a unit.

## Split archives

A sealed archive sent to a network share or external drive arrives as numbered parts. Restore reassembles them for you, so you never need to join parts by hand. If you want to use the parts outside Cryoframe, join them first with `cat Library.dmg.part.* > Library.dmg` and then mount the result.
