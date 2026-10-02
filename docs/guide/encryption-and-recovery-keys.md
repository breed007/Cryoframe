# Encryption and recovery keys

[← Back to contents](README.md)

Encryption protects an archive that leaves your Mac: a copy on an external drive, a NAS, or a cloud-sync folder that someone else could read. This page covers turning it on, where the passphrase lives, and how to make sure you can still open the archive after the Mac that made it is gone.

## Turning on encryption

When you make a job, turn on "Encrypt with a passphrase" under Details. Backups are encrypted with AES-256. It applies to one up-to-date copy and to dated versions kept as disk images. A zip file cannot be strongly encrypted, so the option is off for that format.

You set a passphrase when you turn it on. The backup is encrypted with that passphrase, and it is unreadable without it. There is no back door and no reset.

Encryption and the passphrase stay as they are once a job exists. To change either, make a new job. (The 1.5.6 release notes said passphrase rotation was planned for 1.6. It was dropped, and isn't in this release.)

## Where the passphrase lives

Cryoframe stores the passphrase in your login Keychain, keyed to the job. It is never written into the job file or the archive. Two things follow from that:

- Scheduled runs encrypt without prompting, because the app and the background agent are the same signed program and share the Keychain item.
- Verifying or restoring an encrypted archive asks for the passphrase, unless it is still in this Mac's Keychain.

You can see a job's saved passphrase with Copy passphrase in its ⋯ menu, or with Show the saved passphrase… while editing the job. Keep a copy somewhere safe.

Deleting a job doesn't delete its passphrase. It stays in the Keychain, and Restore offers it for that job's backups.

## The risk you are managing

If you lose the passphrase, the backup is gone. The encryption is real, so a forgotten passphrase is the same as a destroyed archive. This is the cost of encryption that no service can recover for you.

The Keychain copy covers everyday use on the Mac that made the backup. It does not cover the case that matters most: the Mac dies, and you set up a new one. The new Mac's Keychain does not have the passphrase, so without another copy the encrypted archives are unreadable. That is what the recovery key is for.

## Recovery keys (Settings ▸ Security)

The recovery key feature exports every saved archive passphrase into one file, encrypted with a master password you choose. You keep that file somewhere separate from the backups, such as a password manager or a second drive. With it, you can recover your passphrases on any Mac.

### Export

Open Settings ▸ Security. The page shows how many encrypted jobs have a saved passphrase. Click Export passphrases, choose a master password, and pick where to save the file. It is written with a `.cryoframekeys` extension.

The file is protected with PBKDF2 and AES-GCM, so it is only as readable as the master password is strong. If an encrypted job has no saved passphrase, the page warns you and that job is left out of the export, because there is nothing to export for it.

### Restore from a recovery file

On the new Mac, open Settings ▸ Security and click "Restore from a recovery file." Choose the file and enter its master password. Cryoframe shows the saved passphrases so you can read or copy them.

You then type the passphrase into the restore prompt for the matching archive. Recovery does not put the passphrases back into the new Mac's Keychain automatically, because a freshly created job has a different identity than the old one. The recovered passphrase is what you paste when you restore.

### The printed recovery kit

A recovery file holds passphrases. It doesn't say where your backups are, and someone helping you after a lost Mac may not know. The recovery kit is a printed page that does.

Click Print Recovery Kit… in Settings ▸ Security. The kit lists your jobs, where each keeps its backups (with each drive's name and volume UUID), how to open each kind of backup without Cryoframe, and when you last exported a recovery file, with blank lines to write where you keep the kit and the recovery file. It holds no passphrases.

<!-- SHOT: recovery-kit.png — the Print a recovery kit dialog, with the passphrase box unticked -->

If you want the passphrases on paper too, tick "Also print the passphrases, on a separate page". Cryoframe then warns you before printing that page, because anyone holding it can open your encrypted backups. The page goes through the print queue like any other, and macOS keeps a copy of each print job's file for about a day afterward. The PDF menu in the print panel (Save as PDF, Save to iCloud Drive, Mail, Preview) writes or sends a copy, so choose a printer, not PDF. The choice is never remembered; the box starts unticked every time.

When your jobs change after you printed the kit, the main window and Settings ▸ Security say the kit is out of date. Print a new one and replace the old.

### What to do today

If you keep any encrypted backup, export a recovery file now and store it away from the backups. Without it, an encrypted backup can't be opened after the Mac that made it is lost. Then print a recovery kit and keep it with your important papers.
