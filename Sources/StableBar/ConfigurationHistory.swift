import Foundation
import Observation

@MainActor @Observable
final class ConfigurationHistory {
    struct Step {
        let before: Data
        let after: Data
    }

    private unowned let store: BarStore
    private let saveDelay: Duration
    private(set) var undoSteps: [Step] = []
    private(set) var redoSteps: [Step] = []
    var error: String?
    private(set) var notice: String?
    private var lastFile: Data?
    private var pendingControl: Control?
    @ObservationIgnored private var pendingEdit: (() throws -> [ConfigurationEdit])?
    @ObservationIgnored private(set) var writeTask: Task<Void, Never>?

    private struct Control: Equatable {
        let action: ConfigurationEdit.Action
        let id: String?
        let paths: Set<String>
        let name: String?
    }

    init(store: BarStore, saveDelay: Duration = .milliseconds(500)) {
        self.store = store
        self.saveDelay = saveDelay
    }

    var hasPendingChanges: Bool { !store.customizationEdits.isEmpty }
    var canUndo: Bool { hasPendingChanges || !undoSteps.isEmpty }
    var canRedo: Bool { !hasPendingChanges && !redoSteps.isEmpty }

    func change(_ edit: ConfigurationEdit) throws {
        try change(control: control(for: edit)) { [edit] }
    }

    /// Related edits are validated and saved together, with one Undo step.
    func change(_ edits: [ConfigurationEdit]) throws {
        guard !edits.isEmpty else { return }
        try change(control: nil) { edits }
    }

    func setProfileCondition<Value: Equatable>(_ name: String, _ key: WritableKeyPath<ProfileConditions, Value?>,
                                               value: Value?, control: String) throws {
        let profiles = try store.customizationProfiles()
        guard let profile = profiles.first(where: { $0.name == name }) else {
            throw CommandFailure(message: "Save command-line changes before editing this profile.")
        }
        guard profile.when?[keyPath: key] != value else { return }
        try change(control: Control(action: .profiles, id: name, paths: [], name: control)) { [unowned store] in
            guard var profile = try store.customizationProfiles(includingPending: false).first(where: { $0.name == name }) else {
                throw CommandFailure(message: "This profile is no longer in the configuration file.")
            }
            let current = profile
            var conditions = profile.when ?? ProfileConditions()
            conditions[keyPath: key] = value
            profile.when = current.when == nil && conditions == ProfileConditions() ? nil : conditions
            let changes = try profileChanges(from: current, to: profile)
            return changes.isEmpty ? [] : [ConfigurationEdit(action: .profiles, profiles: [changes])]
        }
    }

    func pendingEdits() throws -> [ConfigurationEdit] {
        try pendingEdit.map { try $0() } ?? store.customizationEdits
    }

    private func change(control: Control?, edit: @escaping () throws -> [ConfigurationEdit]) throws {
        error = nil
        if hasPendingChanges && (control == nil || control != pendingControl) { store.flushCustomization() }
        checkForExternalChanges()
        try store.setCustomizationEdits(edit())
        pendingEdit = edit
        pendingControl = control
        redoSteps.removeAll()
        notice = nil
        if control == nil { try flush() }
        else {
            writeTask?.cancel()
            writeTask = Task { [weak self, saveDelay] in
                do { try await Task.sleep(for: saveDelay) }
                catch { return }
                guard let self else { return }
                do { try flush() }
                catch { self.error = errorMessage(error) }
            }
        }
    }

    func flush() throws {
        writeTask?.cancel()
        writeTask = nil
        guard hasPendingChanges else { return }
        do {
            checkForExternalChanges()
            let before = try Data(contentsOf: store.configurationURL)
            let after = try store.customizationData(pendingEdits(), editing: before)
            try store.writeCustomization(after, replacing: before)
            if before != after { undoSteps.append(Step(before: before, after: after)) }
            lastFile = after
            pendingControl = nil
            pendingEdit = nil
            notice = nil
        } catch {
            let message = "The pending Customize change could not be saved and was discarded. \(errorMessage(error))"
            discardPendingChange()
            self.error = message
            FileHandle.standardError.write(Data("\(message)\n".utf8))
            throw CommandFailure(message: message)
        }
    }

    func undo() throws {
        error = nil
        let changedOutside = checkForExternalChanges()
        if hasPendingChanges {
            let step: Step?
            if !changedOutside, let before = try? Data(contentsOf: store.configurationURL),
               let after = try? store.customizationData(pendingEdits(), editing: before), before != after {
                step = Step(before: before, after: after)
            } else { step = nil }
            discardPendingChange()
            if let step { redoSteps.append(step) }
            error = nil
            if !changedOutside { notice = nil }
            return
        }
        if changedOutside { return }
        guard let step = undoSteps.last else { return }
        guard try restore(step.before) else { return }
        undoSteps.removeLast()
        redoSteps.append(step)
    }

    func redo() throws {
        error = nil
        if checkForExternalChanges() { return }
        try flush()
        guard let step = redoSteps.last else { return }
        guard try restore(step.after) else { return }
        redoSteps.removeLast()
        undoSteps.append(step)
    }

    func saveCommandLineChanges() throws {
        store.flushCustomization()
        try store.applyEdits([], persist: true)
        let current = try Data(contentsOf: store.configurationURL)
        if current != lastFile {
            undoSteps.removeAll()
            redoSteps.removeAll()
        }
        lastFile = current
        error = nil
        notice = nil
    }

    func discardCommandLineChanges() throws {
        store.flushCustomization()
        try store.setSessionEdits([])
        error = nil
    }

    @discardableResult
    func checkForExternalChanges() -> Bool {
        let current = try? Data(contentsOf: store.configurationURL)
        defer { lastFile = current }
        guard let lastFile, current != lastFile else { return false }
        let hadHistory = canUndo || !redoSteps.isEmpty
        undoSteps.removeAll()
        redoSteps.removeAll()
        if hadHistory { notice = "Undo history was cleared because the configuration file changed outside Customize." }
        return hadHistory
    }

    func clearNotice() { notice = nil }
    func showNotice(_ message: String) { notice = message }

    private func discardPendingChange() {
        writeTask?.cancel()
        writeTask = nil
        pendingControl = nil
        pendingEdit = nil
        store.discardCustomizationEdits()
    }

    func dropUnavailableHistory() {
        let states = undoSteps.flatMap { [$0.before, $0.after] } + redoSteps.flatMap { [$0.before, $0.after] }
        if states.contains(where: { (try? store.validateCustomization($0)) == nil }) {
            undoSteps.removeAll()
            redoSteps.removeAll()
            notice = "Undo history was cleared because an uninstalled package is no longer available."
        }
    }

    private func restore(_ data: Data) throws -> Bool {
        let current = try Data(contentsOf: store.configurationURL)
        guard current == lastFile else { checkForExternalChanges(); return false }
        try store.writeCustomization(data, replacing: current)
        lastFile = data
        error = nil
        notice = nil
        return true
    }

    private func control(for edit: ConfigurationEdit) -> Control? {
        guard [.set, .bar, .defaults, .popupDefaults, .roles, .workspaceDefaults, .tokens, .modeAliases].contains(edit.action),
              let properties = edit.properties else { return nil }
        return Control(action: edit.action, id: edit.id, paths: propertyPaths(properties), name: nil)
    }
}

private func propertyPaths(_ properties: [String: ConfigurationValue], prefix: String = "") -> Set<String> {
    properties.reduce(into: []) { paths, property in
        if case let .object(object) = property.value, !object.isEmpty {
            paths.formUnion(propertyPaths(object, prefix: prefix + property.key + "."))
        } else { paths.insert(prefix + property.key) }
    }
}
