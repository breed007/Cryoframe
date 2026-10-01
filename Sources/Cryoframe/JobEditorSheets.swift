//
//  JobEditorSheets.swift
//  Cryoframe (app)
//
//  The job editor's smaller sheets: renaming a library, "Is this one of your
//  drives?", Rename this drive, and what saving an edit does. Each asks the Kit
//  (DrivePairing, DriveRename, JobEditImpact) and only shows what it says.
//

import SwiftUI
import AppKit
import CryoframeKit

// MARK: - renaming a library

struct LibraryRenameSheet: View {
    let library: ContentType
    @Binding var isPresented: Bool
    let onRename: (String) -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename “\(library.displayName)”").font(.headline)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).frame(width: 320)
            Text("The new name is this job's only. Its backup folders are renamed at the next backup that reaches each destination; one on a drive that's away keeps the old name until then, and is still found by it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Rename") { onRename(name); isPresented = false }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 380)
        .onAppear { name = library.displayName }
    }
}

// MARK: - is this one of your drives?

struct PairingSheet: View {
    @ObservedObject var model: AppModel
    let job: BackupJob
    let target: Target
    /// Rename this drive saves by itself, so only with nothing unsaved and nothing running
    let canRename: Bool
    @Binding var isPresented: Bool
    let onTakeTurns: (DrivePairing) -> Void
    let onRename: (VolumeIdentity) -> Void

    @State private var look: DrivePairing?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Is this one of your drives?").font(.title3.bold())
            Text("A drive named “\(target.volume?.name ?? target.displayName)” is connected, but it isn't the one \(target.displayName) was set up on. Before 1.6, two drives with one name was the only way to take turns. If this is the other drive, say how it should work from now on.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !loaded {
                HStack { ProgressView().controlSize(.small); Text("Looking at the drive…").font(.callout) }
            } else if let look {
                if let refusal = look.refusal {
                    Label(refusal, systemImage: "xmark.octagon.fill").foregroundStyle(.cryoCrit).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    DriveLookLibraries(look: look)
                }
            } else {
                Text("That drive isn't connected any more.").font(.callout)
            }
            Divider()
            HStack(alignment: .top) {
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Spacer()
                if let look, look.refusal == nil {
                    Button("Take turns under one name") { onTakeTurns(look); isPresented = false }
                        .help("Recorded when you save the job. Both drives keep the name, so a notice about one can only say which by the start of its ID.")
                    Button("Rename this drive…") { onRename(look.drive) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canRename)
                        .help(canRename ? "Recommended: each drive gets a name of its own, and they take turns. You see what the next backup does to it again before it's renamed." : "Save or cancel your changes first, and wait for anything running to finish.")
                }
            }
        }
        .padding(22).frame(width: 540)
        .task {
            look = await model.pairing(target, of: job)
            loaded = true
        }
    }
}

/// what the next backup does to each library's backups on a drive (see DrivePairing):
/// the up-to-date copy's date and size, the dated versions, and the effect
struct DriveLookLibraries: View {
    let look: DrivePairing

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(look.libraries, id: \.name) { lib in libraryBlock(lib) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 260)
    }

    private func libraryBlock(_ lib: DrivePairing.Library) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(lib.name).font(.callout.weight(.semibold))
            if let c = lib.copy {
                Text("Up-to-date copy: \(c.date.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "date unknown"), \(human(c.bytes))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !lib.versions.isEmpty {
                let newest = lib.versions.first!, oldest = lib.versions.last!
                Text("\(lib.versions.count) dated version\(lib.versions.count == 1 ? "" : "s"), \(oldest.formatted(date: .abbreviated, time: .omitted)) to \(newest.formatted(date: .abbreviated, time: .omitted)), \(human(lib.versionBytes))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(lib.effects, id: \.self) { e in
                let costs = e.contains("deleted") || e.contains("replaces")
                Label(e, systemImage: costs ? "trash" : "arrow.right.circle")
                    .font(.caption).foregroundStyle(costs ? Color.cryoWarn : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func human(_ b: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file) }
}

// MARK: - rename this drive

struct RenameDriveSheet: View {
    @ObservedObject var model: AppModel
    let job: BackupJob
    let request: DriveToRename
    @Binding var isPresented: Bool
    let onRenamed: (BackupJob) -> Void

    @State private var name = ""
    @State private var fileSystem = ""
    @State private var look: DrivePairing?
    @State private var loaded = false
    @State private var working = false
    @State private var failure: String?

    private var problem: String? {
        if let p = DriveRename.nameProblem(name, fileSystem: fileSystem) { return p }
        if model.takenDriveNames(except: request.drive.uuid).contains(where: { LibraryNames.same($0, name) }) {
            return "A drive named “\(name)” is already connected or known to your backups."
        }
        return nil
    }

    /// the Rename button says what it agrees to
    private var renameTitle: String {
        guard let look, look.changesBackups else { return "Rename" }
        let versions = look.libraries.reduce(0) { $0 + $1.deletes }
        let unfinished = look.libraries.reduce(0) { $0 + $1.unfinished }
        let copies = look.libraries.filter(\.replacesCopy).count
        let later = look.libraries.reduce(0) { $0 + $1.later }
        var parts: [String] = []
        if versions > 0 { parts.append("delete \(versions) version\(versions == 1 ? "" : "s")") }
        if unfinished > 0 { parts.append("delete \(unfinished) unfinished folder\(unfinished == 1 ? "" : "s")") }
        if copies > 0 { parts.append("replace \(copies == 1 ? "a copy" : "\(copies) copies")") }
        if parts.isEmpty { return "Rename, and let Keep apply to \(later) older version\(later == 1 ? "" : "s")" }
        return "Rename, and " + parts.joined(separator: " and ") + " at the next backup"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename this drive").font(.title3.bold())
            Text("The drive connected now, “\(request.drive.name)”, gets a name of its own. \(request.target.displayName) keeps the other drive, and a new destination on this one takes turns with it. Renaming changes the drive's name only. The next backup to it takes over this job's folders there, and does what's listed below.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !loaded {
                HStack { ProgressView().controlSize(.small); Text("Looking at the drive…").font(.callout) }
            } else if let look {
                if let refusal = look.refusal {
                    Label(refusal, systemImage: "xmark.octagon.fill").foregroundStyle(.cryoCrit).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    DriveLookLibraries(look: look)
                }
            } else {
                Text("That drive isn't connected any more.").font(.callout)
            }
            if look?.refusal == nil, look != nil {
                TextField("New name", text: $name).textFieldStyle(.roundedBorder).frame(width: 260)
                if !name.isEmpty, let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.cryoWarn)
                }
                Label("Apps or scripts that find this drive by its path may lose it: the path changes with the name.",
                      systemImage: "info.circle").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let failure {
                Label(failure, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.cryoCrit)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if working { ProgressView().controlSize(.small); Text("Renaming…").font(.caption) }
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction).disabled(working)
                if let look, look.refusal == nil {
                    Button(renameTitle) { rename(confirming: look) }
                        .buttonStyle(.borderedProminent)
                        .disabled(working || problem != nil)
                }
            }
        }
        .padding(22).frame(width: 540)
        .onAppear {
            name = DriveRename.suggestedName(for: request.drive.name, taken: model.takenDriveNames(except: request.drive.uuid))
            fileSystem = DriveRename.drive(request.drive.uuid)?.fileSystem ?? ""
        }
        .task { await lookAgain() }
    }

    private func lookAgain() async {
        loaded = false
        look = await model.renameLook(request.drive.uuid, target: request.target, of: job)
        loaded = true
    }

    private func rename(confirming look: DrivePairing) {
        working = true; failure = nil
        Task {
            let result = await model.renameDrive(request.drive.uuid, to: name, targetID: request.target.id, job: job, confirmed: look)
            working = false
            switch result {
            case .success(let outcome): onRenamed(outcome.job); isPresented = false
            case .failure(let why):
                failure = why.localizedDescription
                // what it does may have changed: show what it says now
                if why == .effectNotConfirmed { await lookAgain() }
            }
        }
    }
}

// MARK: - what saving does

struct SaveSummarySheet: View {
    let impact: JobEditImpact
    var isNew = false
    @Binding var isPresented: Bool
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "Create this job?" : "Save these changes?").font(.title3.bold())
            Text(isNew ? "Creating the job changes nothing yet. Its first backup does this:"
                       : "Saving changes the job only. The next backup does this:").font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(impact.lines, id: \.self) { line in
                        Label(line.text, systemImage: symbol(line.kind))
                            .font(.callout)
                            .foregroundStyle(line.kind == .deletes ? Color.cryoWarn : Color.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)
            HStack {
                Spacer()
                Button("Keep editing") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button(saveTitle) { onSave() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(22).frame(width: 540)
    }

    /// the button says what it agrees to, as Rename does
    private var saveTitle: String {
        let verb = isNew ? "Create" : "Save"
        let n = impact.deletes, unfinished = impact.unfinished, later = impact.later
        var parts: [String] = []
        if n > 0 { parts.append("delete \(n) version\(n == 1 ? "" : "s")") }
        if unfinished > 0 { parts.append("delete \(unfinished) unfinished folder\(unfinished == 1 ? "" : "s")") }
        if parts.isEmpty {
            return later > 0 ? "\(verb), and let Keep apply to \(later) older version\(later == 1 ? "" : "s")" : verb
        }
        return "\(verb), and " + parts.joined(separator: " and ") + " at the next backup"
    }

    private func symbol(_ k: JobEditImpact.Line.Kind) -> String {
        switch k {
        case .creates: "folder.badge.plus"
        case .renames: "pencil"
        case .keeps: "checkmark.shield"
        case .deletes: "trash"
        case .changes: "arrow.triangle.2.circlepath"
        }
    }
}
