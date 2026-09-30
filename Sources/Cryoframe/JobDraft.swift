//
//  JobDraft.swift
//  Cryoframe (app)
//
//  The single source of truth for building a backup job — shared by the guided wizard
//  (new jobs) and the full sheet (editing). The rules live in CryoframeKit's
//  JobDraftState, where they are tested; this wrapper makes them observable, supplies
//  what only the app knows (saved jobs, preferences), and owns the commit path
//  (Keychain + save). Neither view reimplements any of it; they only render it.
//

import SwiftUI
import AppKit
import CryoframeKit

@MainActor
@dynamicMemberLookup
final class JobDraft: ObservableObject {
    let model: AppModel
    @Published var state: JobDraftState

    typealias FreqKind = JobDraftState.FreqKind

    init(model: AppModel, editing: BackupJob? = nil) {
        self.model = model
        let d = UserDefaults.standard
        let defaults = JobDraftState.Defaults(formatKind: d.string(forKey: Prefs.format),
                                              verification: d.string(forKey: Prefs.verify),
                                              runPolicy: d.string(forKey: Prefs.runPolicy))
        state = JobDraftState(editing: editing, libraries: model.registry.types, targets: model.targets,
                              defaults: defaults)
    }

    /// every field and rule of the draft reads (and, where it is a field, writes)
    /// straight through to the Kit state, so `draft.encrypt` and `$draft.encrypt`
    /// work as they always did.
    subscript<T>(dynamicMember keyPath: WritableKeyPath<JobDraftState, T>) -> T {
        get { state[keyPath: keyPath] }
        set { state[keyPath: keyPath] = newValue }
    }
    subscript<T>(dynamicMember keyPath: KeyPath<JobDraftState, T>) -> T { state[keyPath: keyPath] }

    // MARK: rules that need the saved jobs

    /// another job already writing one of these libraries to one of these folders.
    var destinationConflicts: [String] { state.destinationConflicts(existing: model.jobs) }
    var isValid: Bool { state.isValid(existing: model.jobs) }

    // MARK: mutators

    func toggleLibrary(_ id: String) { state.toggleLibrary(id) }
    func toggleTarget(_ id: String) { state.toggleTarget(id) }

    func addLibrary(_ ct: ContentType, at url: URL) {
        state.addLibrary(ct)
        model.libraryValid[ct.id] = FileManager.default.fileExists(atPath: url.path)
    }
    /// re-read the built-in library list (after a location edit) while keeping added ones.
    func refreshBuiltInLibraries() {
        state.replaceBuiltInLibraries(model.registry.types)
        model.revalidate()
    }

    func addTarget(_ t: Target) {
        state.addTarget(t)
        model.addTarget(t)
    }

    /// Add a place just chosen as a destination, if every rule for one allows it
    /// (see JobDraftState.addDestination); what's wrong or worth knowing, either way.
    func addDestination(_ t: Target) -> [PlaceIssue] {
        let issues = state.addDestination(t)
        if !issues.contains(where: { $0.severity == .refusal }) { model.addTarget(t) }
        return issues
    }

    /// Add a folder just chosen to back up, if every rule allows it (see
    /// JobDraftState.addSource).
    func addSource(_ ct: ContentType, at url: URL) -> [PlaceIssue] {
        let issues = state.addSource(ct, at: url)
        if !issues.contains(where: { $0.severity == .refusal }) {
            model.libraryValid[ct.id] = FileManager.default.fileExists(atPath: url.path)
        }
        return issues
    }

    /// each chosen library against each chosen destination (see JobDraftState.pathIssues)
    var pathIssues: [String] { state.pathIssues() }

    /// whether the draft differs from the job it was opened on (a new job: always)
    var hasUnsavedEdits: Bool {
        guard let base = state.base else { return true }
        // the list on offer may order libraries otherwise than the job did
        var made = state.makeJob(now: base.createdAt), was = base
        made.libraries.sort { $0.id < $1.id }; was.libraries.sort { $0.id < $1.id }
        return made != was
    }

    /// start over from `job` as it is saved now (after something saved it for us)
    func reload(editing job: BackupJob) {
        let d = UserDefaults.standard
        state = JobDraftState(editing: job, libraries: model.registry.types, targets: model.targets,
                              defaults: JobDraftState.Defaults(formatKind: d.string(forKey: Prefs.format),
                                                               verification: d.string(forKey: Prefs.verify),
                                                               runPolicy: d.string(forKey: Prefs.runPolicy)))
    }

    func renameLibrary(_ id: String, to name: String) -> Bool { state.renameLibrary(id, to: name) }
    func makeMain(_ id: String) { state.makeMain(id) }
    func takeTurns(_ id: String, with other: String) { state.takeTurns(id, with: other) }
    func stopTakingTurns(_ id: String) { state.stopTakingTurns(id) }
    func takesTurns(_ id: String) -> [Target] { state.takesTurns(id) }
    func pair(_ id: String, with drive: VolumeIdentity) -> Bool { state.pair(id, with: drive) }
    func unpair(_ id: String, uuid: String) { state.unpair(id, uuid: uuid) }

    /// take a library out of the job; one added in this editor leaves the list too
    func removeLibrary(_ id: String) {
        state.selectedLibraryIDs.remove(id)
        if model.registry.type(id: id) == nil, state.base?.libraries.contains(where: { $0.id == id }) != true {
            state.libraries.removeAll { $0.id == id }
        }
    }
    func removeTarget(_ id: String) {
        guard model.canRemoveTarget(id) else { return }
        state.removeFromOffer(id)
        model.removeTarget(id)
    }

    /// persist the job (Keychain + store, see JobDraftState.commit). Returns false if
    /// nothing was saved.
    @discardableResult
    func commit() -> Bool { model.save(state) }
}
