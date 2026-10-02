//
//  HelpView.swift
//  Cryoframe (app)
//
//  In-app help with two worked examples.
//

import SwiftUI

struct HelpView: View {
    @Binding var isPresented: Bool
    var onReportProblem: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("How to use Cryoframe").font(.title2.bold())
                Spacer()
                Button("Done") { isPresented = false }.keyboardShortcut(.defaultAction)
            }
            .padding(20)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("What it does") {
                        para("Cryoframe freezes a live media library with an APFS snapshot, then archives the frozen copy. The snapshot is point-in-time consistent, so you can back up Photos or Apple Music while they're still open without sealing a half-written database into the archive.")
                    }

                    section("First-time setup") {
                        para("Three one-time steps, shown at the top of the main window:")
                        bullet("Enable the helper. This installs the background service that takes snapshots. Approve it in System Settings ▸ Login Items when asked.")
                        bullet("Grant Full Disk Access to Cryoframe, then relaunch. The dot turns green once it can read protected libraries. On a macOS where Cryoframe can't confirm it, a gray question mark shows instead, and a backup that can't read a library says so.")
                        bullet("Enable the schedule if you want jobs to run in the background.")
                    }

                    section("Making a job") {
                        para("Press New Job. The job editor starts with quick-start presets; pick one, or start from scratch, and change anything below it. New Job and Edit… open the same editor.")
                        bullet("Back up: the libraries and folders in the job. Everything chosen is frozen in one snapshot and backed up together, each into its own folder at every destination, so they're a consistent point-in-time set. Add a folder with Back up another folder….")
                        bullet("Copies go to: the destinations. Add destination… takes a folder on this Mac, an external drive, a network share or a cloud folder, and Cryoframe works out which it is. The main destination is the one every backup has to reach.")
                        bullet("When: how often the job runs: every day, every few hours, once, or only when you say.")
                        bullet("Keep: whether each backup keeps one up-to-date copy (as a disk image or plain files) or dated versions (as disk images or zip files), and how many versions to keep. Plain files can only be chosen for a new job.")
                        bullet("Details: encryption, how each backup is checked, and what to do if the library's app is open.")
                        bullet("Before you save, a summary says what the change does to the backups already at each destination.")
                    }

                    section("Drives that take turns") {
                        bullet("To rotate two drives, add both as destinations, then choose Takes turns with from one drive's menu. Each backup goes to whichever drive is connected, and the one that's away isn't a fault.")
                        bullet("Destinations are known by the drive they're on, so a renamed drive is still found and another drive with the same name isn't used by mistake.")
                        bullet("Two drives that share a name from Cryoframe 1.5: when the other one is connected, the editor asks \"Is this one of your drives?\" Choose Take turns under one name, or Rename this drive… to give it a name of its own.")
                    }

                    section("Managing jobs") {
                        bullet("Run now starts a job. While it runs you can Pause it (the tool at work is suspended in place and the snapshot held), then Resume to pick up where it left off. Pause is offered for sealed-zip and live-mirror archives and for transfers; sealed-DMG imaging can't be safely paused (macOS's disk-image tool crashes if frozen), so a DMG job shows only Stop while it's building.")
                        bullet("Stop cancels a running or queued job and tears the snapshot down. A sealed archive can't resume mid-build, so a stopped job starts over; an interrupted transfer to a network or external drive does resume from its last whole part when the same drive reconnects. Stop never interrupts a disk image while macOS is attaching it.")
                        bullet("After a live mirror's copy, the row names each step that follows (Finishing the copy, Reading the copy back and the rest) with how far it has got, and Stop works in each. On a first run, reading the copy back reads the whole library off the drive, which can take many minutes on an SD card or another slow drive.")
                        bullet("A tool that makes no progress for 15 minutes is stopped, and the run says so.")
                        bullet("Quitting while a backup, a check, an export or a restore is running asks first. Stop and Quit stops it the way Stop does, then quits; a restore can't be stopped, so Cryoframe waits for it. A logout or restart doesn't ask: everything is stopped, and it goes ahead within 15 seconds.")
                        bullet("Clear, above the Activity list, empties the list. History keeps every run, and your backups aren't touched.")
                        bullet("The ⋯ menu has Edit…, the archive checks, Copy passphrase for an encrypted job, Disable/Enable schedule, and Delete…. A disabled job won't run automatically (no next-run time) but still runs from Run now.")
                        bullet("Deleting a job keeps its backups and its passphrase. Restore still finds them both.")
                        bullet("Several jobs can run at once, up to the limit in Settings ▸ General (default 2).")
                        bullet("Each job shows a green check or red ✗ for whether its libraries are found, with a Fix in Settings link for built-ins.")
                        bullet("Each job shows its last run: result, duration, size, and when. The History button (top right) lists every past run, including scheduled ones run while the app was closed, with per-library detail and any error. Run records persist across launches.")
                    }

                    section("Updates") {
                        bullet("Cryoframe updates itself. Choose Cryoframe ▸ Check for Updates… (or the menu-bar item), or let it check automatically. Updates are cryptographically signed and verified before they install.")
                    }

                    section("Notifications & the menu bar") {
                        bullet("Cryoframe shows a status item in the menu bar: a glance at each job's last run, with a red triangle if anything failed. It also keeps the app resident, so it can notify you of scheduled runs even with the window closed. Quit it from the menu bar's Quit item.")
                        bullet("Choose when to be notified in Settings ▸ General ▸ Notifications: never, on failure (default), or on every run.")
                        bullet("Remote alerts (Settings ▸ General ▸ Remote alerts) push a failed, partial, or overdue backup to your phone or a chat channel via ntfy or a webhook (Slack/Discord/custom), for when you're away from the Mac. Use Send test alert to confirm it reaches you.")
                    }

                    section("Sleep & scheduled wake") {
                        bullet("Locking the screen doesn't interrupt a backup. It keeps running.")
                        bullet("\"Keep the Mac awake while a backup runs\" (Settings ▸ General, on by default) holds an assertion for the duration of a run so the Mac doesn't idle-sleep partway through and sever a network copy. It prevents idle sleep only. It never forces the display on, and closing a laptop lid still sleeps the Mac.")
                        bullet("\"Wake the Mac for scheduled backups\" (off by default) asks the helper to set a system wake a couple of minutes before the next due job, so an idle Mac runs its nightly backup near the intended time. It changes the system power schedule (and only ever its own wake), can't wake a Mac that's shut down, and can't beat a closed lid.")
                    }

                    section("Formats") {
                        bullet("One up-to-date copy (a live mirror, the default): a sparsebundle that updates in place. Only the parts that changed get rewritten, so it's fast for a frequent working backup, and it can be paused mid-run. It sizes itself and grows as needed, up to what its drive can hold, and each run's copy is read back before it replaces the last one.")
                        bullet("Dated versions, as disk images or zip files (sealed DMG or zip): one immutable, checksummed file per run for cold storage. Splits into volumes when the destination caps file size, so it fits cloud limits. (A disk image can't be paused while it's being built.)")
                        bullet("One up-to-date copy as plain files: ordinary files and folders any computer can open. A changed file replaces the old one; a deleted one moves to Removed items beside the copy, which you empty in Storage. Plain files can't be encrypted. On exFAT, FAT32 and network drives they lose permissions, Finder tags and creation dates, FAT32 can't take a file of 4 GB or more, and macOS may add a hidden \"._\" file beside each file. An app's library, such as Photos, can only be kept as plain files on an APFS drive connected to this Mac.")
                        bullet("Messages attachments, a library of its own, backs up the photos and files sent in Messages in any format. What you delete in Messages stays in the backup: in Removed items for a mirror or plain files, and in a removed-items archive before old dated versions are deleted. Mirrors and plain files leave out link previews; dated versions keep them.")
                        bullet("Named pipes and sockets are left out of a mirror. A sealed archive of a folder holding them is built from a copy without them; so is a disk image of a folder with append-only items or, on macOS 15, locked files. That copy needs room in the scratch location.")
                    }

                    section("Storage & space") {
                        bullet("The Storage button (top right) shows how much space each job's backups use and how full each destination's drive is, which helps when a job keeps many versions.")
                        bullet("Each destination also shows its recent runs as bars (red for a failed one), and a gray note when the latest run took over twice as long as usual.")
                        bullet("A cloud folder shows whether its versions have been uploaded. Cryoframe says Uploaded only when the provider has proven it holds the file, so \"Upload not known\" in gray is the usual answer, and it's normal. The provider's own menu-bar app has the details.")
                        bullet("A plain-files copy shows its Removed items as a row of their own. Its Delete… menu removes the ones older than 30 days, 90 days or a year, or all of them. Nothing else deletes them.")
                        bullet("Before a run, Cryoframe checks the target has room and stops with a clear message if it doesn't, rather than failing partway through.")
                    }

                    section("Archive health") {
                        bullet("Cold archives can rot: a flipped bit, a file a drive quietly dropped. Cryoframe can re-check existing archives against the checksums recorded when they were made, so corruption is caught long before a restore needs them.")
                        bullet("Verify one job's archives any time from its ⋯ menu, or every job at once with Verify all archives in the menu-bar item. Set a schedule in Settings ▸ General ▸ Archive health (weekly or monthly), and a scope: latest version per library, or all versions. Each job shows its last check; a failure turns the menu-bar item red and notifies you.")
                        bullet("Sealed archives are verified byte-for-byte against their checksums. A live mirror is verified structurally, by its files and sizes, which catches dropped or truncated pieces but not an in-place bit flip (full-hashing a mirror every check would defeat its incremental nature).")
                        bullet("Restore drill (a Depth option in Settings ▸ General ▸ Archive health, and a Run restore drill item in a job's ⋯ menu) goes further than a checksum: it reassembles, mounts or extracts, and reopens each archive, which proves the restore path itself works.")
                        bullet("Stop ends a check, drill, or rehearsal. A stopped one doesn't count as passed: what it found is listed, and the last finished check still stands.")
                    }

                    section("Versions & retention") {
                        bullet("Each run of a job that keeps dated versions is saved as its own version, so you can restore the library as it was at a point in time. (One up-to-date copy keeps a single copy instead.)")
                        bullet("Keep sets how many: every version, the last few, or daily, weekly and monthly. Older versions are pruned automatically after a run.")
                        bullet("Backups made by an earlier version of Cryoframe, or moved into a job's folder, are never deleted until you click Let Keep apply on the card the main window shows for them.")
                        bullet("A version marked Kept is from before its job changed how it keeps backups. Nothing deletes it.")
                        bullet("Restore lists each version with its date. Pick the one you want.")
                    }

                    section("Encryption") {
                        bullet("Turn on \"Encrypt with a passphrase\" under Details to encrypt the backups with AES-256, which is worth doing for copies kept on an external drive, a NAS, or a cloud-sync folder. It applies to one up-to-date copy and to disk images (a zip file can't be strongly encrypted). Encryption and the passphrase can't be changed once the job exists; make a new job instead.")
                        bullet("The passphrase is stored in your Keychain so scheduled runs encrypt without prompting; it's never written into the job. Restoring or verifying an encrypted archive asks for it. You can read a saved passphrase any time with Copy passphrase in the job's ⋯ menu.")
                        bullet("There is no recovery if you lose the passphrase: the backup is unreadable without it. Keep it somewhere safe.")
                        bullet("Recovery keys (Settings ▸ Security) export every saved passphrase into one file, encrypted with a master password you choose, so encrypted backups are recoverable on a new Mac. The Keychain copy only protects the Mac that made the backup; keep a recovery file somewhere separate for the case where that Mac is gone.")
                        bullet("Print Recovery Kit… (Settings ▸ Security) prints where every job keeps its backups, each drive's name and volume UUID, and how to open each backup without Cryoframe. It holds no passphrases. They can go on a separate page, after a warning, and only if you tick the box each time.")
                        bullet("Every destination also has a note, \"READ ME - How to restore without Cryoframe.txt\", saying what's there and how to open it with tools built into macOS.")
                    }

                    section("Restoring a library") {
                        bullet("Click Restore (top right), point it at the folder holding your archives (or use a Quick pick for a destination you back up to), and it lists the libraries it finds.")
                        bullet("Pick what to restore and a destination folder. Cryoframe verifies the checksums, then mounts or extracts the archive and copies the library out with its original folder name.")
                        bullet("The restore bar's Beside / In place switch chooses where the library goes. Beside, the default, copies it into the folder you picked and never over your live library. If something there has the same name, Restore Alongside brings it back beside it under a new name. Once it's done, move the restored library into place, or double-click it to open in its app.")
                        bullet("Find a File… (top of the Restore window) searches each version's list of files for a name or a path, newest first. Show opens the version at the match. Versions made before 1.6, and live mirrors, have no list; use Look inside… for those.")
                        bullet("In place replaces your live library with the version you picked. The current one moves to the Trash, so it's reversible; quit the owning app first.")
                        bullet("Browse… opens the picked version in an in-app file browser so you can drill in and extract just the files you need.")
                        bullet("Export Media… copies a version's photos, videos or other files into a folder for each month, by the date each file was last changed, with a filter by type and month. Exporting again copies only what isn't there yet, and a file that can't be read is skipped and named. The exported files aren't encrypted. It's offered for folders and Messages, not for app libraries such as Photos, Music, iMovie, Mail or GarageBand.")
                    }

                    section("Verification") {
                        bullet("Quick check hashes every archive after writing. Always on.")
                        bullet("Full check (opens it) also mounts the finished archive and confirms the library's database opens clean, so you aren't holding a backup that only looks fine.")
                    }

                    section("Example: back up Apple Photos nightly") {
                        bullet("Library: Photos")
                        bullet("Copies go to: an external drive, or a folder")
                        bullet("Each backup keeps: Dated versions, as disk images")
                        bullet("When: Every day, at a quiet hour like 2:00")
                        bullet("Check each backup: Full check (opens it)")
                        para("Press Run now once to confirm it works. The job row turns green when the archive verifies. You don't need to quit Photos first.")
                    }

                    section("Example: mirror Apple Music nightly") {
                        bullet("Library: Apple Music")
                        bullet("Copies go to: a local folder or a NAS share")
                        bullet("Each backup keeps: One up-to-date copy")
                        bullet("Back up: Every day, late")
                        bullet("Check each backup: Quick check")
                        para("The first run copies the whole library. Later runs only write what changed, so they finish fast.")
                    }

                    section("Resumable transfers to network or external drives") {
                        para("When a destination is a network share or an external drive, a long sealed-archive copy can be cut off by a dropped connection or an unplugged drive. Cryoframe sees what kind of place the destination is and ships the archive so it can resume.")
                        bullet("The archive is built locally first, then sent to the drive in parts (2 GB by default, set in Settings ▸ Transfers).")
                        bullet("If the link drops, the next run (or the next time the same drive reconnects) picks up from the last completed part instead of starting over. No new snapshot, no rebuild.")
                        bullet("Building locally first needs scratch space of about one archive. A folder holding named pipes or sockets (or, for a disk image, append-only items, and on macOS 15 any locked items) is copied first, which needs room for the copy as well; an encrypted job's copy is always made in the system cache on the startup disk. The scratch location is in Settings ▸ Transfers; the default is your system cache. In a location you choose, Cryoframe works in a folder of its own named Cryoframe Scratch.")
                        bullet("The archive lands as numbered parts (Library.dmg.part.000, .001, …). Reassemble with `cat Library.dmg.part.* > Library.dmg` before mounting.")
                        para("Local destinations write a single file directly. Cloud-sync folders are left to the sync client, which resumes uploads on its own. Live mirrors resume by re-running the sync.")
                    }

                    section("Good to know") {
                        bullet("You don't need to quit Photos or Music. \"If the app is open\" only matters if you'd rather wait to back up until it's closed.")
                        bullet("Cloud-sync destinations (OneDrive, Dropbox, Google Drive, Box, iCloud) are detected by provider and split sealed archives under that provider's single-file limit: iCloud caps at 50 GB, Box at 5 GB on lower plans. If the client offloads a file to save space, a scheduled health check skips it rather than downloading it again (changeable in Settings ▸ General ▸ Archive health).")
                        bullet("A scheduled job that has gone twice its interval without a good run is overdue. The dashboard shows it, and Cryoframe sends a notification and, if you've set them up, a remote alert.")
                        bullet("Snapshots are created and deleted per run. Cryoframe never touches Time Machine's snapshots.")
                    }

                    section("Full guide") {
                        para("This covers the essentials. The full guide goes deeper on every feature, with worked examples and troubleshooting.")
                        Link("Open the Cryoframe user guide", destination: URL(string: "https://github.com/breed007/Cryoframe/blob/main/docs/guide/README.md")!)
                            .font(.callout)
                    }

                    if let onReportProblem {
                        section("Something wrong?") {
                            para("Report a Problem builds a report to attach to a GitHub issue: versions, how your jobs are set up, and what recent backups said, with your names, paths and files left out. You read it before you save it.")
                            Button("Report a Problem…") { onReportProblem() }
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 560, height: 620)
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }
    private func para(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
