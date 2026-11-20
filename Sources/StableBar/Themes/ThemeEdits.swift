import Foundation

/// The parts of a configuration that make up a theme's look, besides `tokens` and the bar's `savedThemeBarProperties`.
/// Save as Theme moves them into a theme, and Settings saves edits to them as edits of the selected theme.
let themeLookKeys = ["defaults", "popupDefaults", "groupDefaults", "roles", "workspaceDefaults", "groups"]
/// What a widget's Style tab sets, also saved as an edit of the selected theme.
let widgetLookKeys: Set<String> = ["style", "background", "popupBackground", "tooltipBackground"]
/// The style properties a widget's Style tab shows.
let widgetStyleKeys = ["foreground", "background", "accent", "accentText", "shadowColor", "appIcons", "fontName", "fontWeight", "fontSize",
                       "paddingHorizontal", "paddingVertical", "paddingLeading", "paddingTrailing", "paddingTop", "paddingBottom",
                       "cornerRadius", "borderWidth", "borderColor"]

extension ProfileConditions {
    /// The theme a profile holds edits for: its only condition is the theme.
    var onlyTheme: String? {
        guard let theme else { return nil }
        var conditions = ProfileConditions()
        conditions.theme = theme
        return self == conditions ? theme : nil
    }
}

/// One value of the look: an edit of a theme, kept in the main file's profile for that theme, or a value of the main
/// file that applies under every theme.
struct ThemeEdit: Equatable, Identifiable {
    /// The path from the profile's configuration, or from the main file.
    let path: [String]
    let section: String
    let title: String
    let value: ConfigurationValue
    /// The theme's own value, when it sets one.
    var themeValue: ConfigurationValue?

    var id: [String] { path }

    /// The edit that sets this value in the main file, or in `profile` with the theme condition it's created with.
    func setting(profile: String? = nil, themeID: String? = nil) -> ConfigurationEdit {
        var edit = if path[0] == "widgetOverrides" {
            ConfigurationEdit(action: .set, id: path[1], properties: nested(Array(path.dropFirst(2)), value))
        } else {
            ConfigurationEdit(action: ConfigurationEdit.Action(rawValue: path[0])!, properties: nested(Array(path.dropFirst()), value))
        }
        edit.profile = profile
        edit.profileConditions = themeID.map { ["theme": .string($0)] }
        return edit
    }

    /// The edit that removes this value from the main file.
    var removal: ConfigurationEdit {
        ConfigurationEdit(action: .unset, properties: nested(path, .null))
    }
}

private func nested(_ path: [String], _ value: ConfigurationValue) -> [String: ConfigurationValue] {
    let inner = path.dropFirst().reversed().reduce(value) { .object([$1: $0]) }
    return [path[0]: inner]
}

/// The edits of one theme, and the look values of the main file that apply under every theme.
struct ThemeEdits {
    let themeID: String
    /// The main file's profile whose only condition is the theme.
    let profile: String?
    let changes: [ThemeEdit]
    let everyTheme: [ThemeEdit]
    /// How many style values each widget keeps under every theme, in its definition or the main file's overrides.
    let widgetStyles: [String: Int]
    private let configuration: [String: ConfigurationValue]
    private let profileNames: [String]

    static let none = ThemeEdits(main: [:], themeID: "")

    /// `theme` is the theme's own layer, for the values a change replaces; `names` names widgets.
    init(main: [String: ConfigurationValue], themeID: String, theme: [String: ConfigurationValue] = [:],
         names: [String: String] = [:]) {
        self.themeID = themeID
        let profile = Self.profile(for: themeID, in: main)
        self.profile = profile.flatMap { $0["name"].flatMap { try? $0.decoded(String.self) } }
        configuration = (try? profile?["configuration"]?.decoded([String: ConfigurationValue].self)) ?? [:]
        profileNames = ((try? main["profiles"]?.decoded([ConfigurationProfile].self)) ?? []).map(\.name)
        let themed = (try? theme["tokens"]?.decoded([String: ConfigurationValue].self)) ?? [:]
        changes = lookValues(in: configuration, tokens: { _ in true }, widgets: names, theme: theme)
        everyTheme = lookValues(in: main, tokens: { name in themed[name] != nil || themeTokens.contains { $0.name == name } },
                                widgets: nil, theme: theme)
        let definitions = (try? main["widgets"]?.decoded([[String: ConfigurationValue]].self)) ?? []
        let overrides = (try? main["widgetOverrides"]?.decoded([String: [String: ConfigurationValue]].self)) ?? [:]
        var own: [String: [String: ConfigurationValue]] = [:]
        for definition in definitions {
            if case let .string(id)? = definition["id"] { own[id] = definition }
        }
        for (id, override) in overrides { own[id, default: [:]].merge(override) { $1 } }
        widgetStyles = own.mapValues { widget in
            widget.filter { widgetLookKeys.contains($0.key) }.reduce(0) { $0 + lookLeaves($1.value, path: [$1.key]).count }
        }
    }

    /// The main file's profile whose only condition is `themeID`.
    static func profile(for themeID: String, in main: [String: ConfigurationValue]) -> [String: ConfigurationValue]? {
        let profiles = (try? main["profiles"]?.decoded([[String: ConfigurationValue]].self)) ?? []
        return profiles.first { profile in
            (try? profile["when"]?.decoded(ProfileConditions.self))?.onlyTheme == themeID
        }
    }

    /// The IDs of the themes the main file keeps edits for.
    static func editedThemes(in main: [String: ConfigurationValue]) -> Set<String> {
        let profiles = (try? main["profiles"]?.decoded([[String: ConfigurationValue]].self)) ?? []
        return Set(profiles.compactMap { profile in
            guard let theme = (try? profile["when"]?.decoded(ProfileConditions.self))?.onlyTheme,
                  case let .object(configuration)? = profile["configuration"],
                  !lookValues(in: configuration, tokens: { _ in true }, widgets: [:], theme: [:]).isEmpty else { return nil }
            return theme
        })
    }

    /// The theme's changes to one widget's style.
    func widgetChanges(_ id: String) -> [ThemeEdit] {
        changes.filter { $0.path.starts(with: ["widgetOverrides", id]) && widgetLookKeys.contains($0.path[2]) }
    }

    /// Removes `changes` from the theme's profile, and the profile itself once nothing else is left in it.
    func removal(of changes: [ThemeEdit]) -> ConfigurationEdit? {
        guard let profile, !changes.isEmpty else { return nil }
        func paths(_ value: ConfigurationValue, _ path: [String]) -> [[String]] {
            guard case let .object(object) = value, !object.isEmpty else { return [path] }
            return object.flatMap { paths($0.value, path + [$0.key]) }
        }
        let removed = changes.map(\.path)
        let remaining = configuration.flatMap { paths($0.value, [$0.key]) }.filter { leaf in !removed.contains { leaf.starts(with: $0) } }
        if remaining.isEmpty {
            return ConfigurationEdit(action: .unset, properties: ["profiles": .object([profile: .null])])
        }
        var mask: [String: ConfigurationValue] = [:]
        for change in changes {
            let removal = nested(change.path, .null)
            mask[change.path[0]] = removal[change.path[0]]!.overriding(mask[change.path[0]] ?? .object([:]))
        }
        var edit = ConfigurationEdit(action: .unset, properties: mask)
        edit.profile = profile
        return edit
    }

    var revertEdit: ConfigurationEdit? { removal(of: changes) }

    /// Moves `change` out of the theme's profile into the main file, so it applies under every theme. A group a widget
    /// joins gets an empty entry there too, so that every theme has it.
    func applyingToEveryTheme(_ change: ThemeEdit) -> [ConfigurationEdit] {
        var edits = [removal(of: [change]), change.setting()].compactMap { $0 }
        if change.path.first == "widgetOverrides", change.path.last == "group", case let .string(group) = change.value {
            edits.append(ConfigurationEdit(action: .groups, properties: [group: .object([:])]))
        }
        return edits
    }

    /// The profile that keeps the edits: the existing one, else "<theme> edits", numbered past the main file's other
    /// profiles.
    func profileName(theme: String) -> String {
        if let profile { return profile }
        var name = "\(theme) edits"
        var number = 2
        while profileNames.contains(name) {
            name = "\(theme) edits \(number)"
            number += 1
        }
        return name
    }

    /// Moves `values` that apply under every theme into the theme's profile.
    func keepingWithTheme(_ values: [ThemeEdit], theme: String) -> [ConfigurationEdit] {
        values.map(\.removal) + values.map { $0.setting(profile: profileName(theme: theme), themeID: themeID) }
    }
}

/// The look values in `document`, one per property: a light/dark pair or a gradient counts as one value. `widgets` names
/// the widgets whose styles and groups count, from `widgetOverrides`; nil leaves them out.
private func lookValues(in document: [String: ConfigurationValue], tokens: (String) -> Bool, widgets names: [String: String]?,
                        theme: [String: ConfigurationValue]) -> [ThemeEdit] {
    var found: [ThemeEdit] = []
    func add(_ path: [String], _ value: ConfigurationValue, section: String, title: String) {
        found.append(ThemeEdit(path: path, section: section, title: title, value: value, themeValue: lookValue(at: path, in: theme)))
    }
    if case let .object(values) = document["tokens"] {
        for (name, value) in values where tokens(name) {
            add(["tokens", name], value, section: "Colors", title: themeTokens.first { $0.name == name }?.title ?? friendly(name))
        }
    }
    for key in themeLookKeys {
        guard case let .object(values) = document[key] else { continue }
        for (name, value) in values {
            for (path, leaf) in lookLeaves(value, path: [key, name]) {
                switch key {
                case "defaults": add(path, leaf, section: "Widgets", title: styleTitle(Array(path.dropFirst())))
                case "popupDefaults": add(path, leaf, section: "Popups", title: styleTitle(Array(path.dropFirst())))
                case "groupDefaults": add(path, leaf, section: "Groups", title: "Every group: \(detailTitle(spacing(Array(path.dropFirst()))))")
                case "groups":
                    add(path, leaf, section: "Groups", title: "\(friendly(name)) group: \(detailTitle(spacing(path.dropFirst(2).filter { $0 != "style" })))")
                case "roles": add(path, leaf, section: "Roles", title: "\(friendly(name)): \(detailTitle(Array(path.dropFirst(2))))")
                default: add(path, leaf, section: "Workspaces", title: styleTitle(Array(path.dropFirst())))
                }
            }
        }
    }
    if case let .object(bar) = document["bar"] {
        for (name, value) in bar where savedThemeBarProperties.contains(name) {
            for (path, leaf) in lookLeaves(value, path: ["bar", name]) {
                if name == "glass" {
                    add(path, leaf, section: "Liquid Glass", title: path.count > 2 ? styleTitle(Array(path.dropFirst(2))) : "Liquid Glass")
                } else if name == "popupOffset" {
                    add(path, leaf, section: "Popups", title: "Gap below the bar")
                } else {
                    add(path, leaf, section: "Bar", title: styleTitle(spacing(path.dropFirst().filter { $0 != "style" })))
                }
            }
        }
    }
    if let names, case let .object(widgets) = document["widgetOverrides"] {
        for case let (id, .object(widget)) in widgets {
            for (key, value) in widget where widgetLookKeys.contains(key) || key == "group" {
                for (path, leaf) in lookLeaves(value, path: ["widgetOverrides", id, key]) {
                    add(path, leaf, section: names[id] ?? friendly(id), title: styleTitle(path.dropFirst(2).filter { $0 != "style" }))
                }
            }
        }
    }
    return found.sorted { $0.path.lexicographicallyPrecedes($1.path) }
}

/// The bar's and a group's `spacing` is the space between their widgets, as Settings names it.
private func spacing(_ path: [String]) -> [String] {
    path == ["spacing"] ? ["spaceBetweenWidgets"] : path
}

/// Each property under `value`, keeping a light/dark pair, a gradient and a null whole. Empty objects hold nothing.
private func lookLeaves(_ value: ConfigurationValue, path: [String]) -> [([String], ConfigurationValue)] {
    guard case let .object(object) = value, !value.isGradient, Set(object.keys) != ["light", "dark"] else { return [(path, value)] }
    return object.keys.sorted().flatMap { lookLeaves(object[$0]!, path: path + [$0]) }
}

private func lookValue(at path: [String], in theme: [String: ConfigurationValue]) -> ConfigurationValue? {
    guard path.first != "widgetOverrides" else { return nil }
    var current = ConfigurationValue.object(theme)
    for key in path {
        guard case let .object(object) = current, let next = object[key] else { return nil }
        current = next
    }
    return current
}

private func detailTitle(_ path: [String]) -> String {
    let title = styleTitle(path)
    return title.prefix(1).lowercased() + title.dropFirst()
}

func styleTitle(_ path: [String]) -> String {
    let appearance = ["light", "dark"].contains(path.last ?? "") ? path.last : nil
    let title = path.filter { $0 != "states" && $0 != appearance }.map { key in
        ["foreground": "Text color", "background": "Background", "borderColor": "Border color",
         "shadowColor": "Shadow color", "hoverBackground": "Hover background", "hoverForeground": "Hover text color",
         "fontName": "Font", "fontSize": "Text size", "fontWeight": "Weight", "inset": "Side inset",
         "paddingHorizontal": "Horizontal padding", "paddingVertical": "Vertical padding",
         "paddingLeading": "Leading padding", "paddingTrailing": "Trailing padding", "paddingTop": "Top padding",
         "paddingBottom": "Bottom padding", "offsetX": "Horizontal offset", "offsetY": "Vertical offset",
         "minWidth": "Minimum width", "maxWidth": "Maximum width", "cornerRadius": "Corner radius",
         "offset": "Offset from top", "popupOffset": "Popup gap below the bar", "surface": "Surface", "surfaceRaised": "Raised surface", "text": "Text",
         "textMuted": "Muted text", "hairline": "Hairline", "accentText": "Accent text color"][key] ?? friendly(key)
    }.joined(separator: ": ")
    return appearanceTitle(title, appearance: appearance)
}

private func appearanceTitle(_ title: String, appearance: String?) -> String {
    guard let appearance, ["light", "dark"].contains(appearance) else { return title }
    return "\(title) in \(appearance) mode"
}

func friendly(_ value: String) -> String {
    let spaced = value.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        .replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        .lowercased()
    return spaced.prefix(1).uppercased() + spaced.dropFirst()
}

extension ThemeChoice {
    /// Raw theme values keep token references intact, for the values a change replaces.
    func overrideLayer(settings: [String: ConfigurationValue] = [:], activeProfiles: [String]) throws -> ConfigurationLayer {
        var loader = ConfigurationLoader()
        var layer = try loader.readPackage(at: directory, manifest: manifest, settings: settings)
        for profile in try layer.values["profiles"]?.decoded([ConfigurationProfile].self) ?? [] where activeProfiles.contains(profile.name) {
            try layer.merge(ConfigurationLayer(values: profile.configuration, origins: [:]))
        }
        layer.values["profiles"] = nil
        return layer
    }
}

extension ConfigurationEditor {
    /// The selected theme's ID, and the name its profile of edits gets.
    var selectedTheme: (id: String, name: String) {
        let key = store.configurationStore.selectedThemeKey
        let id = String(key.prefix { $0 != "/" })
        return (id, gallery.choices.first { $0.key == key }?.manifest.name ?? (id == "built-in" ? "Built-in" : friendly(id)))
    }

    /// The selected theme's edits and the look values that apply under every theme, from the main file.
    func themeEdits() -> ThemeEdits {
        let main = (try? store.configurationStore.editedMainDocument(replaying: store.configurationStore.customizationEdits)) ?? [:]
        return ThemeEdits(main: main, themeID: selectedTheme.id)
    }

    /// Saves the look in `edit` as an edit of the selected theme, in the main file's profile whose only condition is
    /// that theme, created on the first edit. While a profile is being edited, `edit` goes to that profile as before;
    /// the rest of `edit`, and edits of one screen, stay in the main file. An unset removes the look from both.
    func changeLook(_ edit: ConfigurationEdit, everyBar: Bool = false) {
        let (look, rest) = lookPart(of: edit)
        guard var look else { return change(edit, everyBar: everyBar) }
        let theme = selectedTheme
        let edits = themeEdits()
        let profile = edits.profile
        if edit.action == .unset {
            guard let profile else { return change(edit, everyBar: everyBar) }
            look.profile = profile
            do { change(try store.removingEmptyThemeEdits([edit, look], profile: profile), everyBar: everyBar) }
            catch { self.error = errorMessage(error) }
            return
        }
        look.profile = edits.profileName(theme: theme.name)
        look.profileConditions = ["theme": .string(theme.id)]
        if let rest { change([rest, look], everyBar: everyBar) } else { change(look, everyBar: everyBar) }
    }

    private func lookPart(of edit: ConfigurationEdit) -> (look: ConfigurationEdit?, rest: ConfigurationEdit?) {
        guard editingProfile == nil, edit.profile == nil, let properties = edit.properties else { return (nil, edit) }
        func split(_ isLook: (String, ConfigurationValue) -> ConfigurationValue?) -> (ConfigurationEdit?, ConfigurationEdit?) {
            var look = edit, rest = edit
            look.properties = [:]
            rest.properties = [:]
            for (key, value) in properties {
                if let part = isLook(key, value) {
                    look.properties![key] = part
                    if case let .object(all) = value, case let .object(lookPart) = part, all.count > lookPart.count {
                        rest.properties![key] = .object(all.filter { lookPart[$0.key] == nil })
                    }
                } else {
                    rest.properties![key] = value
                }
            }
            return (look.properties!.isEmpty ? nil : look, rest.properties!.isEmpty ? nil : rest)
        }
        func isThemeColor(_ name: String) -> Bool { themeTokens.contains { $0.name == name } }
        switch edit.action {
        case .defaults, .popupDefaults, .groupDefaults, .roles, .workspaceDefaults, .groups: return (edit, nil)
        case .tokens: return split { name, value in isThemeColor(name) ? value : nil }
        case .bar: return split { name, value in savedThemeBarProperties.contains(name) ? value : nil }
        case .set: return split { name, value in widgetLookKeys.contains(name) ? value : nil }
        case .unset where edit.id != nil: return split { name, value in widgetLookKeys.contains(name) ? value : nil }
        case .unset:
            return split { key, value in
                if themeLookKeys.contains(key) { return value }
                guard ["bar", "tokens"].contains(key), case let .object(values) = value else { return nil }
                let look = values.filter { key == "bar" ? savedThemeBarProperties.contains($0.key) : isThemeColor($0.key) }
                return look.isEmpty ? nil : .object(look)
            }
        default: return (nil, edit)
        }
    }

    /// The widget's own style values: those it keeps under every theme, and its edits of the selected theme.
    func ownStyle(of widget: WidgetConfiguration) -> (everyTheme: Int, onTheme: Int) {
        (gallery.edits.widgetStyles[widget.id] ?? 0, gallery.edits.widgetChanges(widget.id).count)
    }

    /// Removes the widget's own style, under every theme and as an edit of the selected theme, in one change.
    func resetStyle(of widget: WidgetConfiguration) {
        let style = ConfigurationValue.object(Dictionary(uniqueKeysWithValues: widgetStyleKeys.map { ($0, ConfigurationValue.null) })
            .merging(HoverBackgroundRow.reset) { $1 })
        let edits = themeEdits()
        change([ConfigurationEdit(action: .unset, id: widget.id, properties: [
            "style": style, "background": .null, "popupBackground": .null, "tooltipBackground": .null
        ])] + [edits.removal(of: edits.widgetChanges(widget.id))].compactMap { $0 })
    }
}

extension BarStore {
    /// `edits`, followed by the removal of the theme's profile of edits `profile` when they leave it empty.
    func removingEmptyThemeEdits(_ edits: [ConfigurationEdit], profile: String) throws -> [ConfigurationEdit] {
        var main = try configurationStore.editedMainDocument(replaying: configurationStore.customizationEdits)
        var ids: [String] = []
        for edit in edits { main = try edit.applying(to: main, widgetIDs: &ids) }
        let remaining = try main["profiles"]?.decoded([[String: ConfigurationValue]].self).first { $0["name"] == .string(profile) }
        guard remaining?["configuration"] == .object([:]) else { return edits }
        return edits + [ConfigurationEdit(action: .unset, properties: ["profiles": .object([profile: .null])])]
    }
}
