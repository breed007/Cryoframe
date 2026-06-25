# Encryption and recovery keys

[← Back to contents](README.md)

Encryption protects an archive that leaves your Mac: a copy on an external drive, a NAS, or a cloud-sync folder that someone else could read. This page covers turning it on, where the passphrase lives, and how to make sure you can still open the archive after the Mac that made it is gone.

## Turning on encryption

When you make a job, turn on "Encrypt with AES-256." It applies to the sealed-DMG and live-mirror formats. A sealed zip cannot be strongly encrypted, so the option is off for that format.

You set a passphrase when you enable it. The archive is encrypted with that passphrase, and the archive is unreadable without it. There is no back door and no reset.

## Where the passphrase lives

Cryoframe stores the passphrase in your login Keychain, keyed to the job. It is never written into the job file or the archive. Two things follow from that:

- Scheduled runs encrypt without prompting, because the app and the background agent are the same signed program and share the Keychain item.
- Verifying or restoring an encrypted archive asks for the passphrase, unless it is still in this Mac's Keychain.

You can see a job's saved passphrase with Copy passphrase in its ⋯ menu, or reveal it while editing the job. Keep a copy somewhere safe.

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

### What to do today

If you keep any encrypted backup, export a recovery file now and store it away from the backups. That one file is the difference between a recoverable archive and a locked one after hardware loss.
