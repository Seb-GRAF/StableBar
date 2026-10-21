import AppKit
import Observation

@MainActor @Observable
final class ConfigurationEditor {
    let store: BarStore
    let gallery: ThemeGallery
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
            searchTarget = nil
        }
    }
    var section: CustomizationSection? = .general {
        didSet { if ![.widgets, .appearance].contains(section) { endProfileEditing() } }
    }
    var showsValueSources = false
    var editingProfile: String? {
        get { history.editingProfile }
        set { history.editingProfile = newValue }
    }
    var barItem = BarItem.widget
    var barTab = BarTab.size
    var widgetTab = WidgetTab.style
    var barScreen = ScreenKind.laptop
    var themeChangesEveryBar = true
    var selectedPackageID: String?
    var diagnosticWidgetID: String?
    var selectedProfileName: String?
    var search = ""
    var searchTarget: String?
    @ObservationIgnored private let endEditing: () -> Void
    @ObservationIgnored private var endingEditing = false
    var error: String? {
        get { history.error }
        set { history.error = newValue }
    }

    init(store: BarStore, endEditing: @escaping () -> Void = { NSApp?.keyWindow?.endEditing(for: nil) }) {
        self.store = store
        gallery = ThemeGallery(store: store)
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
        if selectedID == id { finishEditing() }
        searchTarget = nil
        selectedID = id
        barItem = .widget
        section = .widgets
    }

    func showPackage(_ id: String) {
        finishEditing()
        searchTarget = nil
        selectedPackageID = id
        section = .packages
    }

    func reset(_ widget: WidgetConfiguration) {
        let keys = definedInMainFile(widget)
            ? ["style", "role", "rules", "transition", "animation", "tooltip", "onClick", "open", "actions", "expandOnHover", "format", "workspace"]
            : WidgetConfiguration.CodingKeys.allCases.map(\.stringValue).filter { !["id", "position", "display", "enabled", "group"].contains($0) }
        change(ConfigurationEdit(action: .unset, id: widget.id, properties: Dictionary(uniqueKeysWithValues: keys.map { ($0, .null) })))
    }

    func definedInMainFile(_ widget: WidgetConfiguration) -> Bool {
        store.origins["widgets.\(widget.id).id"]?.file == store.configurationURL.standardizedFileURL.path
    }

    func troubleshoot(_ id: String) {
        finishEditing()
        searchTarget = nil
        diagnosticWidgetID = id
        section = .diagnostics
    }

    func showProfile(_ name: String) {
        finishEditing()
        searchTarget = nil
        selectedProfileName = name
        section = .profiles
    }

    func editBar(for profile: String) {
        finishEditing()
        do {
            try history.flush()
            guard try store.customizationProfiles().contains(where: { $0.name == profile }) else {
                throw CommandFailure(message: "Save command-line changes before editing this profile.")
            }
            editingProfile = profile
            store.previewProfile(profile)
            if section != .appearance { section = .widgets }
            keepSelection()
        } catch { self.error = errorMessage(error) }
    }

    func endProfileEditing() {
        guard editingProfile != nil else { return }
        finishEditing()
        store.flushCustomization()
        editingProfile = nil
        store.previewProfile(nil)
        keepSelection()
    }

    func showSetting(_ result: SettingsSearchResult) {
        finishEditing()
        search = ""
        searchTarget = result.id
        section = result.section
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

    func change(_ edit: ConfigurationEdit, everyBar: Bool = false) {
        if edit.action == .remove { finishEditing() }
        do { try history.change(edit, everyBar: everyBar) }
        catch { self.error = errorMessage(error) }
        keepSelection()
    }

    func set(_ properties: [String: ConfigurationValue]) {
        guard let selectedID else { return }
        set(properties, for: selectedID)
    }

    func set(_ properties: [String: ConfigurationValue], for id: String) {
        var current = self.properties(for: id)
        var style = style(for: id)
        if case let .object(changes) = properties["style"] {
            for key in changes.keys {
                let property = store.propertySources(path: "widgets.\(id).style", key: key, defaultsPath: "defaults",
                                                     widgetID: id, values: style)
                if let saved = property.saved { style[key] = saved.resolvedValue ?? saved.value }
            }
        }
        current["style"] = .object(style)
        if case let .object(changes) = properties["workspace"] {
            var workspace = (try? store.configuration?.workspaceDefaults.mergedProperties(current["workspace"])) ?? [:]
            for (key, change) in changes {
                if case let .object(nested) = change {
                    var values = (try? workspace[key]?.decoded([String: ConfigurationValue].self)) ?? [:]
                    for name in nested.keys {
                        let property = store.propertySources(path: "widgets.\(id).workspace.\(key)", key: name,
                            defaultsPath: "workspaceDefaults.\(key)", widgetID: id, values: values)
                        if let saved = property.saved { values[name] = saved.resolvedValue ?? saved.value }
                    }
                    workspace[key] = .object(values)
                } else {
                    let property = store.propertySources(path: "widgets.\(id).workspace", key: key,
                        defaultsPath: "workspaceDefaults", widgetID: id, values: workspace)
                    if let saved = property.saved { workspace[key] = saved.resolvedValue ?? saved.value }
                }
            }
            current["workspace"] = .object(workspace)
        }
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
