import AppKit
import Observation

@MainActor @Observable
final class ConfigurationEditor {
    let store: BarStore
    var history: ConfigurationHistory { store.customizationHistory }
    var undoSteps: [ConfigurationHistory.Step] { history.undoSteps }
    var redoSteps: [ConfigurationHistory.Step] { history.redoSteps }
    var selectedID: String?
    var error: String? {
        get { history.error }
        set { history.error = newValue }
    }

    init(store: BarStore) {
        self.store = store
        selectedID = store.configuration?.widgets.first?.id
    }

    var selected: [String: ConfigurationValue] {
        guard let selectedID, case let .array(widgets) = store.effectiveDocument["widgets"] else { return [:] }
        for case let .object(widget) in widgets where widget["id"] == .string(selectedID) { return widget }
        return [:]
    }

    var selectedStyle: [String: ConfigurationValue] {
        guard let configuration = store.configuration,
              let widget = configuration.widgets.first(where: { $0.id == selectedID }) else { return [:] }
        let style = resolveStyle([configuration.defaults, configuration.roleStyle(widget.role), widget.style])
        if case let .object(properties) = style.configurationValue { return properties }
        return [:]
    }

    func change(_ edit: ConfigurationEdit, control: String? = nil) {
        do { try history.change(edit, control: control) }
        catch { self.error = errorMessage(error) }
        keepSelection()
    }

    func set(_ properties: [String: ConfigurationValue]) {
        guard let selectedID else { return }
        var current = selected
        current["style"] = .object(selectedStyle)
        let previous = ConfigurationValue.object(current)
        if ConfigurationValue.object(properties).overriding(previous) == previous {
            error = nil
            return
        }
        change(ConfigurationEdit(action: .set, id: selectedID, properties: properties))
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
        do {
            try history.flush()
            let profiles = try store.customizationProfiles() + [ConfigurationProfile(name: name, when: nil, configuration: [:])]
            change(ConfigurationEdit(action: .profiles, profiles: profiles))
        } catch { self.error = errorMessage(error) }
    }

    func setProfileConfiguration(name: String, configuration: [String: ConfigurationValue]) {
        do {
            try history.flush()
            var profiles = try store.customizationProfiles()
            guard let index = profiles.firstIndex(where: { $0.name == name }) else {
                throw CommandFailure(message: "Save command-line changes before editing this profile.")
            }
            profiles[index].configuration = configuration
            change(ConfigurationEdit(action: .profiles, profiles: profiles))
        } catch { self.error = errorMessage(error) }
    }

    func undo() {
        do { try history.undo() }
        catch { self.error = errorMessage(error) }
        keepSelection()
    }

    func redo() {
        do { try history.redo() }
        catch { self.error = errorMessage(error) }
        keepSelection()
    }

    func saveCommandLineChanges() {
        do { try history.saveCommandLineChanges() }
        catch { self.error = errorMessage(error) }
    }

    func discardCommandLineChanges() {
        do { try history.discardCommandLineChanges() }
        catch { self.error = errorMessage(error) }
        keepSelection()
    }

    private func keepSelection() {
        if store.configuration?.widgets.contains(where: { $0.id == selectedID }) != true {
            selectedID = store.configuration?.widgets.first?.id
        }
    }
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
