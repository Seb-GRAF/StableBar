import Foundation
import Observation

@MainActor @Observable
final class ConfigurationHistory {
    struct Step {
        let before: Data
        let after: Data
        let profile: String?
        var otherBars: [(url: URL, before: Data, after: Data)] = []
    }

    private unowned let store: BarStore
    private let saveDelay: Duration
    private(set) var undoSteps: [Step] = []
    private(set) var redoSteps: [Step] = []
    var error: String?
    var editingProfile: String?
    private(set) var notice: String?
    private var lastFile: Data?
    private var pendingControl: Control?
    private var pendingEveryBar = false
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
    var canUndo: Bool {
        hasPendingChanges || (!undoSteps.isEmpty && (editingProfile == nil || undoSteps.last?.profile == editingProfile))
    }
    var canRedo: Bool {
        !hasPendingChanges && !redoSteps.isEmpty && (editingProfile == nil || redoSteps.last?.profile == editingProfile)
    }

    func change(_ edit: ConfigurationEdit, everyBar: Bool = false) throws {
        let edit = try inEditingProfile(edit)
        try change(control: control(for: edit), everyBar: everyBar) { [edit] }
    }

    func changePackageSettings(_ edit: ConfigurationEdit) throws {
        if editingProfile != nil {
            throw CommandFailure(message: "Package settings apply to your whole bar. Click Done to change them.")
        }
        let properties = edit.properties!
        let id = try properties["id"]!.decoded(String.self)
        let settings = try properties["settings"]!.decoded([String: ConfigurationValue].self)
        try change(control: Control(action: edit.action, id: id, paths: propertyPaths(settings), name: "settings")) { [edit] }
    }

    /// Related edits are validated and saved together, with one Undo step.
    func change(_ edits: [ConfigurationEdit], everyBar: Bool = false) throws {
        guard !edits.isEmpty else { return }
        let edits = try edits.map(inEditingProfile)
        try change(control: nil, everyBar: everyBar) { edits }
    }

    private func inEditingProfile(_ edit: ConfigurationEdit) throws -> ConfigurationEdit {
        // Sources apply to every profile, so they stay in the main configuration.
        guard let editingProfile, ![.profile, .profiles, .packageSource].contains(edit.action) else { return edit }
        switch edit.action {
        case .reorder: throw CommandFailure(message: "A profile keeps your bar’s order. Click Done to reorder widgets.")
        case .theme: throw CommandFailure(message: "A profile can’t change the theme. Click Done to choose a theme for your bar.")
        case .package: throw CommandFailure(message: "Packages belong to your bar, not a profile. Click Done to add one.")
        default: break
        }
        var edit = edit
        if edit.action == .unset, edit.id == nil, var properties = edit.properties,
           case let .object(profiles) = properties.removeValue(forKey: "profiles"),
           case let .object(profile) = profiles[editingProfile],
           case let .object(configuration) = profile["configuration"] {
            properties.merge(configuration) { $1.overriding($0) }
            edit.properties = properties
        }
        edit.profile = editingProfile
        return edit
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

    private func change(control: Control?, everyBar: Bool = false, edit: @escaping () throws -> [ConfigurationEdit]) throws {
        error = nil
        let everyBar = everyBar && editingProfile == nil
        if hasPendingChanges && (control == nil || control != pendingControl || everyBar != pendingEveryBar) { store.flushCustomization() }
        checkForExternalChanges()
        if control == nil {
            try save(edit(), everyBar: everyBar)
        } else {
            try store.setCustomizationEdits(edit())
            pendingEdit = edit
            pendingControl = control
            pendingEveryBar = everyBar
            writeTask?.cancel()
            writeTask = Task { [weak self, saveDelay] in
                do { try await Task.sleep(for: saveDelay) }
                catch { return }
                guard let self else { return }
                do { try flush() }
                catch { self.error = errorMessage(error) }
            }
        }
        redoSteps.removeAll()
        notice = nil
    }

    func flush() throws {
        writeTask?.cancel()
        writeTask = nil
        guard hasPendingChanges else { return }
        do {
            checkForExternalChanges()
            try save(pendingEdits(), everyBar: pendingEveryBar)
        } catch {
            let message = "The pending change in Settings could not be saved and was discarded. \(errorMessage(error))"
            discardPendingChange()
            self.error = message
            FileHandle.standardError.write(Data("\(message)\n".utf8))
            throw CommandFailure(message: message)
        }
    }

    private func save(_ edits: [ConfigurationEdit], everyBar: Bool) throws {
        let before = try Data(contentsOf: store.configurationURL)
        let after = try store.customizationData(edits, editing: before)
        let otherBars = everyBar ? try store.otherBars(applying: edits) : []
        try store.writeCustomization(after, replacing: before)
        for bar in otherBars { try writeConfiguration(bar.after, to: bar.url) }
        if before != after || !otherBars.isEmpty {
            undoSteps.append(Step(before: before, after: after, profile: editingProfile, otherBars: otherBars))
        }
        lastFile = after
        pendingControl = nil
        pendingEdit = nil
        notice = nil
    }

    func undo() throws {
        error = nil
        let changedOutside = checkForExternalChanges()
        if hasPendingChanges {
            let step: Step?
            if !changedOutside, let before = try? Data(contentsOf: store.configurationURL),
               let after = try? store.customizationData(pendingEdits(), editing: before),
               let otherBars = try? pendingEveryBar ? store.otherBars(applying: pendingEdits()) : [],
               before != after || !otherBars.isEmpty {
                step = Step(before: before, after: after, profile: editingProfile, otherBars: otherBars)
            } else { step = nil }
            discardPendingChange()
            if let step { redoSteps.append(step) }
            error = nil
            if !changedOutside { notice = nil }
            return
        }
        if changedOutside { return }
        guard canUndo, let step = undoSteps.last else { return }
        guard try restore(step.before, otherBars: step.otherBars.map { ($0.url, $0.after, $0.before) }) else { return }
        undoSteps.removeLast()
        redoSteps.append(step)
    }

    func redo() throws {
        error = nil
        if checkForExternalChanges() { return }
        try flush()
        guard canRedo, let step = redoSteps.last else { return }
        guard try restore(step.after, otherBars: step.otherBars.map { ($0.url, $0.before, $0.after) }) else { return }
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
        let hadHistory = hasPendingChanges || !undoSteps.isEmpty || !redoSteps.isEmpty
        undoSteps.removeAll()
        redoSteps.removeAll()
        if hadHistory { notice = "Undo history was cleared because the configuration file changed outside Settings." }
        return hadHistory
    }

    func clearNotice() { notice = nil }
    func showNotice(_ message: String) { notice = message }

    /// Starts over when the bar switches to another file, after its pending change is saved.
    func reset() {
        editingProfile = nil
        undoSteps.removeAll()
        redoSteps.removeAll()
        lastFile = nil
        notice = nil
    }

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

    private func restore(_ data: Data, otherBars: [(url: URL, current: Data, restored: Data)]) throws -> Bool {
        let current = try Data(contentsOf: store.configurationURL)
        guard current == lastFile else { checkForExternalChanges(); return false }
        guard otherBars.allSatisfy({ (try? Data(contentsOf: $0.url)) == $0.current }) else {
            undoSteps.removeAll()
            redoSteps.removeAll()
            notice = "Undo history was cleared because another bar’s configuration file changed outside Settings."
            return false
        }
        try store.writeCustomization(data, replacing: current)
        for bar in otherBars { try writeConfiguration(bar.restored, to: bar.url) }
        lastFile = data
        error = nil
        notice = nil
        return true
    }

    private func control(for edit: ConfigurationEdit) -> Control? {
        guard [.set, .screens, .bar, .defaults, .popupDefaults, .roles, .workspaceDefaults, .tokens, .providers, .modeAliases].contains(edit.action),
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
