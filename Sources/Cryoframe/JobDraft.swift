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
    func removeTarget(_ id: String) {
        guard model.canRemoveTarget(id) else { return }
        state.selectedTargetIDs.removeAll { $0 == id }
        model.removeTarget(id)
        state.targets = model.targets
    }

    /// persist the job (Keychain + store). Returns false if the draft isn't valid.
    @discardableResult
    func commit() -> Bool {
        guard isValid else { return false }
        let id = state.editingID ?? UUID().uuidString
        if state.storesNewPassphrase { KeychainArchiveKey.save(state.passphrase, jobID: id) }
        model.addJob(state.makeJob(id: id))
        return true
    }
}
