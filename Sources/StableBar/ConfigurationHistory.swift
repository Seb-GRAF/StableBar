import Foundation
import Observation

@MainActor @Observable
final class ConfigurationHistory {
    struct Step {
        let before: Data
        let after: Data
    }

    private unowned let store: BarStore
    private(set) var undoSteps: [Step] = []
    private(set) var redoSteps: [Step] = []
    var error: String?
    private(set) var notice: String?
    private var lastFile: Data?
    private var pendingControl: Control?
    @ObservationIgnored private var pendingEdit: (() throws -> ConfigurationEdit)?
    @ObservationIgnored private var writeTask: Task<Void, Never>?

    private struct Control: Equatable {
        let action: ConfigurationEdit.Action
        let id: String?
        let paths: Set<String>
        let name: String?
    }

    init(store: BarStore) { self.store = store }

    var hasPendingChanges: Bool { !store.customizationEdits.isEmpty }
    var canUndo: Bool { hasPendingChanges || !undoSteps.isEmpty }
    var canRedo: Bool { !hasPendingChanges && !redoSteps.isEmpty }

    func change(_ edit: ConfigurationEdit, control name: String? = nil) throws {
        try change(control: control(for: edit, name: name)) { edit }
    }

    func setProfileCondition<Value: Equatable>(_ name: String, _ key: WritableKeyPath<ProfileConditions, Value?>,
                                               value: Value?, control: String) throws {
        let profiles = try store.customizationProfiles()
        guard let profile = profiles.first(where: { $0.name == name }) else {
            throw CommandFailure(message: "Save command-line changes before editing this profile.")
        }
        guard profile.when?[keyPath: key] != value else { return }
        try change(control: Control(action: .profiles, id: name, paths: [], name: control)) { [unowned store] in
            var profiles = try store.customizationProfiles(includingPending: false)
            guard let index = profiles.firstIndex(where: { $0.name == name }) else {
                throw CommandFailure(message: "This profile is no longer in the configuration file.")
            }
            var conditions = profiles[index].when ?? ProfileConditions()
            conditions[keyPath: key] = value
            profiles[index].when = conditions
            return ConfigurationEdit(action: .profiles, profiles: profiles)
        }
    }

    func pendingEdits() throws -> [ConfigurationEdit] {
        try pendingEdit.map { [try $0()] } ?? store.customizationEdits
    }

    private func change(control: Control?, edit: @escaping () throws -> ConfigurationEdit) throws {
        if hasPendingChanges && (control == nil || control != pendingControl) { try flush() }
        checkForExternalChanges()
        try store.setCustomizationEdits([edit()])
        pendingEdit = edit
        pendingControl = control
        redoSteps.removeAll()
        error = nil
        if control == nil { try flush() }
        else {
            writeTask?.cancel()
            writeTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(500)) }
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
        checkForExternalChanges()
        let before = try Data(contentsOf: store.configurationURL)
        let after = try store.customizationData(pendingEdits(), editing: before)
        try store.writeCustomization(after, replacing: before)
        if before != after { undoSteps.append(Step(before: before, after: after)) }
        lastFile = after
        pendingControl = nil
        pendingEdit = nil
        error = nil
    }

    func undo() throws {
        // Check before flushing too: an outside edit must never make Undo save a stale preview.
        if checkForExternalChanges() {
            writeTask?.cancel()
            try store.setCustomizationEdits([])
            pendingControl = nil
            pendingEdit = nil
            return
        }
        try flush()
        guard let step = undoSteps.last else { return }
        guard try restore(step.before) else { return }
        undoSteps.removeLast()
        redoSteps.append(step)
    }

    func redo() throws {
        if checkForExternalChanges() { return }
        try flush()
        guard let step = redoSteps.last else { return }
        guard try restore(step.after) else { return }
        redoSteps.removeLast()
        undoSteps.append(step)
    }

    func saveCommandLineChanges() throws {
        try flush()
        try store.applyEdits([], persist: true)
        checkForExternalChanges()
        error = nil
    }

    func discardCommandLineChanges() throws {
        try flush()
        try store.setSessionEdits([])
        error = nil
    }

    @discardableResult
    func checkForExternalChanges() -> Bool {
        guard let current = try? Data(contentsOf: store.configurationURL) else { return false }
        defer { lastFile = current }
        guard let lastFile, current != lastFile else { return false }
        let hadHistory = canUndo || !redoSteps.isEmpty
        undoSteps.removeAll()
        redoSteps.removeAll()
        if hadHistory { notice = "Undo history was cleared because the configuration file changed outside Customize." }
        return hadHistory
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
        return true
    }

    private func control(for edit: ConfigurationEdit, name: String?) -> Control? {
        if let name { return Control(action: edit.action, id: edit.id, paths: [], name: name) }
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
