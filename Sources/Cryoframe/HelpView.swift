//
//  HelpView.swift
//  Cryoframe (app)
//
//  In-app help with two worked examples.
//

import SwiftUI

struct HelpView: View {
    @Binding var isPresented: Bool

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
                        bullet("Grant Full Disk Access to Cryoframe, then relaunch. The dot turns green once it can read protected libraries.")
                        bullet("Enable the schedule if you want jobs to run in the background.")
                    }

                    section("Making a job") {
                        para("Press New Job, then check one or more libraries, pick a destination, a format, and how often to run. Every library you check is frozen in a single snapshot and archived together, each into its own folder at the destination, so they're a consistent point-in-time set.")
                    }

                    section("Managing jobs") {
                        bullet("Run now starts a job. While it runs you can Pause it — the in-flight tool is suspended in place and the snapshot held — then Resume to pick up where it left off. Pause is offered for sealed-zip and live-mirror archives and for transfers; sealed-DMG imaging can't be safely paused (macOS's disk-image tool crashes if frozen), so a DMG job shows only Stop while it's building.")
                        bullet("Stop cancels a running or queued job and tears the snapshot down. A sealed archive can't resume mid-build, so a stopped job starts over; an interrupted transfer to a network or external drive does resume from its last whole part on reconnect.")
                        bullet("The ⋯ menu has Edit, Disable/Enable schedule, and Delete. A disabled job won't run automatically (no next-run time) but still runs from Run now.")
                        bullet("Several jobs can run at once, up to the limit in Settings ▸ General (default 2).")
                        bullet("Each job shows a green check or red ✗ for whether its libraries are found, with a Fix in Settings link for built-ins.")
                        bullet("Each job shows its last run — result, duration, size, and when. The History button (top right) lists every past run, including scheduled ones run while the app was closed, with per-library detail and any error. Run records persist across launches.")
                    }

                    section("Updates") {
                        bullet("Cryoframe updates itself. Choose Cryoframe ▸ Check for Updates… (or the menu-bar item), or let it check automatically. Updates are cryptographically signed and verified before they install.")
                    }

                    section("Notifications & the menu bar") {
                        bullet("Cryoframe shows a status item in the menu bar — a glance at each job's last run, with a red triangle if anything failed. It also keeps the app resident, so it can notify you of scheduled runs even with the window closed. Quit it from the menu bar's Quit item.")
                        bullet("Choose when to be notified in Settings ▸ General ▸ Notifications: never, on failure (default), or on every run.")
                    }

                    section("Sleep & scheduled wake") {
                        bullet("Locking the screen doesn't interrupt a backup — it keeps running.")
                        bullet("\"Keep the Mac awake while a backup runs\" (Settings ▸ General, on by default) holds an assertion for the duration of a run so the Mac doesn't idle-sleep partway through and sever a network copy. It prevents idle sleep only — it never forces the display on, and closing a laptop lid still sleeps the Mac.")
                        bullet("\"Wake the Mac for scheduled backups\" (off by default) asks the helper to set a system wake a couple of minutes before the next due job, so an idle Mac runs its nightly backup near the intended time. It changes the system power schedule (and only ever its own wake), can't wake a Mac that's shut down, and can't beat a closed lid.")
                    }

                    section("Formats") {
                        bullet("Live mirror (default): a sparsebundle that updates in place. Only the parts that changed get rewritten — fast for a frequent working backup, and it can be paused mid-run.")
                        bullet("Sealed zip or DMG: one immutable, checksummed file for cold storage. Splits into volumes when the target caps file size, so it fits cloud limits. (DMG imaging can't be paused mid-build.)")
                    }

                    section("Storage & space") {
                        bullet("The Storage button (top right) shows how much space each job's archives use and how full each target volume is — handy when versioning is set to keep many copies.")
                        bullet("Before a run, Cryoframe checks the target has room and stops with a clear message if it doesn't, rather than failing partway through.")
                    }

                    section("Archive health") {
                        bullet("Cold archives can rot — a flipped bit, a file a drive quietly dropped. Cryoframe can re-check existing archives against the checksums recorded when they were made, so corruption is caught long before a restore needs them.")
                        bullet("Verify one job's archives any time from its ⋯ menu, or every job at once with Verify all archives in the menu-bar item. Set a schedule in Settings ▸ General ▸ Archive health (weekly or monthly), and a scope: latest version per library, or all versions. Each job shows its last check; a failure turns the menu-bar item red and notifies you.")
                        bullet("Sealed archives are verified byte-for-byte against their checksums. A live mirror is verified structurally — its files and sizes — which catches dropped or truncated pieces but not an in-place bit flip (full-hashing a mirror every check would defeat its incremental nature).")
                    }

                    section("Versions & retention") {
                        bullet("Each run of a sealed-DMG or sealed-zip job is saved as its own dated version, so you can restore the library as it was at a point in time. (Live mirror keeps a single, continuously-updated copy instead.)")
                        bullet("Set how many to keep when you make the job: all versions, the last N, or a daily/weekly/monthly scheme. Older versions are pruned automatically after a run.")
                        bullet("Restore lists each version with its date — pick the one you want.")
                    }

                    section("Encryption") {
                        bullet("Turn on \"Encrypt with AES-256\" when making a job to encrypt the archive — good for copies kept on an external drive, a NAS, or a cloud-sync folder. It applies to sealed-DMG and live-mirror formats (sealed zip can't be strongly encrypted).")
                        bullet("The passphrase is stored in your Keychain so scheduled runs encrypt without prompting; it's never written into the job. Restoring or verifying an encrypted archive asks for it. You can read a saved passphrase any time with Copy passphrase in the job's ⋯ menu.")
                        bullet("There is no recovery if you lose the passphrase: the backup is unreadable without it. Keep it somewhere safe.")
                        bullet("Recovery keys (Settings ▸ Security) export every saved passphrase into one file, encrypted with a master password you choose, so encrypted backups are recoverable on a new Mac. The Keychain copy only protects the Mac that made the backup; keep a recovery file somewhere separate for the case where that Mac is gone.")
                    }

                    section("Restoring a library") {
                        bullet("Click Restore (top right), point it at the folder holding your archives (or use a Quick pick for a destination you back up to), and it lists the libraries it finds.")
                        bullet("Pick what to restore and a destination folder. Cryoframe verifies the checksums, then mounts or extracts the archive and copies the library out with its original folder name.")
                        bullet("It restores next to anything already there — never over your live library. Once it's done, move the restored library into place, or double-click it to open in its app.")
                        bullet("Each archive's ⋯ menu also offers Restore in place (replaces your live library: the current one moves to the Trash, so it's reversible; quit the owning app first) and Browse contents (opens the archive in an in-app file browser so you can drill in and extract just the files you need).")
                    bullet("The ⋯ menu also lets you delete a single archive version you no longer need.")
                    }

                    section("Verification") {
                        bullet("Checksum hashes every archive after writing. Always on.")
                        bullet("Mount & open also mounts the finished archive and confirms the library's database opens clean, so you aren't holding a backup that only looks fine.")
                    }

                    section("Example: back up Apple Photos weekly") {
                        bullet("Library: Photos")
                        bullet("Target: an external drive, or a folder")
                        bullet("Format: Sealed DMG")
                        bullet("Run: Daily at a quiet hour like 2:00, or set it to Manual and run by hand")
                        bullet("Verify: Mount & open")
                        para("Press Run now once to confirm it works. The job row turns green when the archive verifies. You don't need to quit Photos first.")
                    }

                    section("Example: mirror Apple Music nightly") {
                        bullet("Library: Apple Music")
                        bullet("Target: a local folder or a NAS share")
                        bullet("Format: Live mirror")
                        bullet("Run: Daily, late")
                        bullet("Verify: Checksum")
                        para("The first run copies the whole library. Later runs only write what changed, so they finish fast.")
                    }

                    section("Resumable transfers to network or external drives") {
                        para("When a destination is a network share or an external drive, a long sealed-archive copy can be cut off by a dropped connection or an unplugged drive. Pick \"Network or external drive\" when you add the destination, and Cryoframe ships the archive so it can resume.")
                        bullet("The archive is built locally first, then sent to the drive in parts (2 GB by default, set in Settings ▸ Transfers).")
                        bullet("If the link drops, the next run — or the next time the drive reconnects — picks up from the last completed part instead of starting over. No re-snapshot, no re-archive.")
                        bullet("Building locally first needs scratch space of about one archive. The scratch location is in Settings ▸ Transfers; the default is your system cache.")
                        bullet("The archive lands as numbered parts (Library.dmg.part.000, .001, …). Reassemble with `cat Library.dmg.part.* > Library.dmg` before mounting.")
                        para("Local destinations write a single file directly. Cloud-sync folders are left to the sync client, which resumes uploads on its own. Live mirrors resume by re-running the sync.")
                    }

                    section("Good to know") {
                        bullet("You don't need to quit Photos or Music. \"If app is open\" only matters if you'd rather defer a run while it's in use.")
                        bullet("Cloud-sync targets split sealed archives under 250GB to fit OneDrive's single-file limit.")
                        bullet("Snapshots are created and deleted per run. Cryoframe never touches Time Machine's snapshots.")
                    }

                    section("Full guide") {
                        para("This covers the essentials. The full guide goes deeper on every feature, with worked examples and troubleshooting.")
                        Link("Open the Cryoframe user guide", destination: URL(string: "https://github.com/breed007/Cryoframe/blob/main/docs/guide/README.md")!)
                            .font(.callout)
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
