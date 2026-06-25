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

                    section("Sleep & scheduled wake") {
                        bullet("Locking the screen doesn't interrupt a backup — it keeps running.")
                        bullet("\"Keep the Mac awake while a backup runs\" (Settings ▸ General, on by default) holds an assertion for the duration of a run so the Mac doesn't idle-sleep partway through and sever a network copy. It prevents idle sleep only — it never forces the display on, and closing a laptop lid still sleeps the Mac.")
                        bullet("\"Wake the Mac for scheduled backups\" (off by default) asks the helper to set a system wake a couple of minutes before the next due job, so an idle Mac runs its nightly backup near the intended time. It changes the system power schedule (and only ever its own wake), can't wake a Mac that's shut down, and can't beat a closed lid.")
                    }

                    section("Formats") {
                        bullet("Live mirror (default): a sparsebundle that updates in place. Only the parts that changed get rewritten — fast for a frequent working backup, and it can be paused mid-run.")
                        bullet("Sealed zip or DMG: one immutable, checksummed file for cold storage. Splits into volumes when the target caps file size, so it fits cloud limits. (DMG imaging can't be paused mid-build.)")
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
