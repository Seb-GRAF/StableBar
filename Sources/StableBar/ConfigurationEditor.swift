import AppKit
import Observation

@MainActor @Observable
final class ConfigurationEditor {
    let store: BarStore
    var history: ConfigurationHistory { store.customizationHistory }
    var undoSteps: [ConfigurationHistory.Step] { history.undoSteps }
    var redoSteps: [ConfigurationHistory.Step] { history.redoSteps }
    private var selection: String?
    var selectedID: String? {
        get { selection }
        set {
            guard newValue != selection else { return }
            finishEditing()
            selection = newValue
        }
    }
    var section: CustomizationSection? = .appearance
    @ObservationIgnored private let endEditing: () -> Void
    @ObservationIgnored private var endingEditing = false
    var error: String? {
        get { history.error }
        set { history.error = newValue }
    }

    init(store: BarStore, endEditing: @escaping () -> Void = { NSApp?.keyWindow?.endEditing(for: nil) }) {
        self.store = store
        self.endEditing = endEditing
        selection = store.configuration?.widgets.first?.id
    }

    /// Commit field-editor text before changing its widget or replacing the document it edits.
    func finishEditing() {
        guard !endingEditing else { return }
        endingEditing = true
        endEditing()
        endingEditing = false
    }

    func showWidget(_ id: String) {
        guard store.configuration?.widgets.contains(where: { $0.id == id }) == true else { return }
        selectedID = id
        section = .widgets
    }

    var selected: [String: ConfigurationValue] {
        selectedID.map { properties(for: $0) } ?? [:]
    }

    var selectedStyle: [String: ConfigurationValue] {
        selectedID.map { style(for: $0) } ?? [:]
    }

    func properties(for id: String) -> [String: ConfigurationValue] {
        guard case let .array(widgets) = store.effectiveDocument["widgets"] else { return [:] }
        for case let .object(widget) in widgets where widget["id"] == .string(id) { return widget }
        return [:]
    }

    func style(for id: String) -> [String: ConfigurationValue] {
        guard let configuration = store.configuration,
              let widget = configuration.widgets.first(where: { $0.id == id }) else { return [:] }
        let style = resolveStyle([configuration.defaults, configuration.roleStyle(widget.role), widget.style])
        if case let .object(properties) = style.configurationValue { return properties }
        return [:]
    }

    func change(_ edit: ConfigurationEdit) {
        if edit.action == .remove { finishEditing() }
        do { try history.change(edit) }
        catch { self.error = errorMessage(error) }
        keepSelection()
    }

    func set(_ properties: [String: ConfigurationValue]) {
        guard let selectedID else { return }
        set(properties, for: selectedID)
    }

    func set(_ properties: [String: ConfigurationValue], for id: String) {
        var current = self.properties(for: id)
        current["style"] = .object(style(for: id))
        let previous = ConfigurationValue.object(current)
        if ConfigurationValue.object(properties).overriding(previous) == previous {
            error = nil
            return
        }
        change(ConfigurationEdit(action: .set, id: id, properties: properties))
    }

    func replaceProperties(_ properties: [String: ConfigurationValue]) {
        var current = selected
        current["id"] = nil
        set(changedProperties(from: current, to: properties))
    }

    func setProfileCondition<Value: Equatable>(_ name: String, _ key: WritableKeyPath<ProfileConditions, Value?>,
                                               value: Value?, control: String) {
        do { try history.setProfileCondition(name, key, value: value, control: control) }
        catch { self.error = errorMessage(error) }
        keepSelection()
    }

    func addProfile(name: String) {
        setProfile(ConfigurationProfile(name: name, when: nil, configuration: [:]))
    }

    func setProfile(_ profile: ConfigurationProfile) {
        do {
            let current = store.profiles.first { $0.name == profile.name }
            if current != nil, try !store.customizationProfiles().contains(where: { $0.name == profile.name }) {
                throw CommandFailure(message: "Save command-line changes before editing this profile.")
            }
            let changes = try profileChanges(from: current, to: profile)
            if changes.isEmpty { error = nil; return }
            change(ConfigurationEdit(action: .profiles, profiles: [changes]))
        } catch { self.error = errorMessage(error) }
    }

    func setProfileConfiguration(name: String, configuration: [String: ConfigurationValue]) {
        do {
            error = nil
            store.flushCustomization()
            guard try store.customizationProfiles().contains(where: { $0.name == name }),
                  var profile = store.profiles.first(where: { $0.name == name }) else {
                throw CommandFailure(message: "Save command-line changes before editing this profile.")
            }
            let current = profile
            profile.configuration = configuration
            let changes = try profileChanges(from: current, to: profile)
            if changes.isEmpty { return }
            change(ConfigurationEdit(action: .profiles, profiles: [changes]))
        } catch { self.error = errorMessage(error) }
    }

    func undo() {
        finishEditing()
        do { try history.undo() }
        catch { self.error = errorMessage(error) }
        keepSelection()
    }

    func redo() {
        finishEditing()
        do { try history.redo() }
        catch { self.error = errorMessage(error) }
        keepSelection()
    }

    func saveCommandLineChanges() {
        do { try history.saveCommandLineChanges() }
        catch { self.error = errorMessage(error) }
    }

    func discardCommandLineChanges() {
        finishEditing()
        do { try history.discardCommandLineChanges() }
        catch { self.error = errorMessage(error) }
        keepSelection()
    }

    func keepSelection() {
        if store.configuration?.widgets.contains(where: { $0.id == selectedID }) != true {
            selectedID = store.configuration?.widgets.first?.id
        }
    }
}

func profileChanges(from current: ConfigurationProfile?, to edited: ConfigurationProfile) throws -> [String: ConfigurationValue] {
    let values = try JSONDecoder().decode([String: ConfigurationValue].self, from: JSONEncoder().encode(edited))
    let previous = try current.map {
        try JSONDecoder().decode([String: ConfigurationValue].self, from: JSONEncoder().encode($0))
    } ?? [:]
    var changes = changedProperties(from: previous, to: values)
    if !changes.isEmpty { changes["name"] = .string(edited.name) }
    return changes
}

private func changedProperties(from current: [String: ConfigurationValue], to edited: [String: ConfigurationValue]) -> [String: ConfigurationValue] {
    var changes: [String: ConfigurationValue] = [:]
    for (key, value) in edited where current[key] != value {
        if case let .object(old) = current[key], case let .object(new) = value {
            changes[key] = .object(changedProperties(from: old, to: new))
        } else {
            changes[key] = value
        }
    }
    for key in current.keys where edited[key] == nil { changes[key] = .null }
    return changes
}
