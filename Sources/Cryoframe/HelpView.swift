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
                        para("Press New Job and pick a library, a destination, a format, and how often to run. Each field has a tooltip on hover.")
                    }

                    section("Formats") {
                        bullet("Sealed DMG or zip: one immutable, checksummed file for cold storage. Splits into volumes when the target caps file size, so it fits cloud limits.")
                        bullet("Live mirror: a sparsebundle that updates in place. Only the parts that changed get rewritten. Good for a frequent working backup.")
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
