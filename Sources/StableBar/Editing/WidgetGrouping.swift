import Foundation

/// What Settings opens on when the bar asks for it.
enum CustomizationTarget: Equatable {
    case widget(String)
    case group(String)
}

/// Starting, joining, leaving and dissolving widget groups from the menus of Settings and the edit bar. The edits only
/// set widgets' `group` and groups' definitions, so a file made this way is one people could write by hand.
@MainActor
struct WidgetGrouping {
    /// A command for a widget outside any group: join the group beside it, or start one with the widget beside it.
    enum Choice: Hashable {
        case join(String)
        case groupWith(String)

        func title(names: [String: String]) -> String {
            switch self {
            case let .join(group): "Add to Group “\(friendly(group))”"
            case let .groupWith(id): "Group With “\(names[id] ?? id)”"
            }
        }
    }

    static let symbol = "rectangle.on.rectangle"

    /// The shared configuration's widgets, whose positions a group's members must share.
    let widgets: [WidgetConfiguration]
    let groups: [String: WidgetGroupConfiguration]
    /// Every profile, from any file. A new group ID avoids their group IDs, and a group they name keeps its definition.
    var profiles: [ConfigurationProfile] = []
    /// Every layer's values by path, which show the groups other files assign, even under a `null`.
    var contributions: [String: [ConfigurationContribution]] = [:]
    let defaults: WidgetStyle
    let groupDefaults: WidgetStyle
    let origins: [String: ConfigurationOrigin]
    /// The standardized path of the main configuration file.
    let mainFile: String
    /// The profile Settings is editing; its changes go there.
    let editingProfile: String?
    /// The selected theme's ID and name, and the groups it defines. Joining one of those groups, leaving it or emptying
    /// it is an edit of the theme, since another theme may not have the group.
    let theme: (id: String, name: String, groups: Set<String>)
    /// The main file with the unsaved Settings changes, read only to dissolve a group or edit the theme.
    let mainDocument: () throws -> [String: ConfigurationValue]

    /// A new group's definition, whose look Settings then offers to change: a faint backdrop that works in light and dark,
    /// with the corners and padding `groupDefaults` doesn't set, or no style when it gives every group a background.
    static func newGroup(defaults: WidgetStyle, groupDefaults: WidgetStyle) -> ConfigurationValue {
        guard groupDefaults.background == nil else { return .object([:]) }
        var style: [String: ConfigurationValue] = ["background": .string("#8080802e")]
        if groupDefaults.cornerRadius == nil { style["cornerRadius"] = .number(defaults.cornerRadius ?? 14) }
        if groupDefaults.paddingHorizontal == nil { style["paddingHorizontal"] = .number(4) }
        return .object(["style": .object(style)])
    }

    /// The choices for `id` among `listed`, the widgets one screen shows in their order, and `listedGroups`, that screen's
    /// groups: the units on either side of it in its position, except spacers and groups only the screen's own theme has.
    func choices(for id: String, among listed: [WidgetConfiguration], groups listedGroups: [String: WidgetGroupConfiguration]) -> [Choice] {
        guard let widget = listed.first(where: { $0.id == id }), widget.group == nil, widget.content != .spacer else { return [] }
        let units = BarUnit.make(widgets: listed.filter { $0.position == widget.position }, groups: listedGroups)
        guard let index = units.firstIndex(where: { $0.id == "widget:\(id)" }) else { return [] }
        return [index - 1, index + 1].filter(units.indices.contains).map { units[$0] }.compactMap { unit in
            if let group = unit.widgets[0].group { return groups[group] == nil ? nil : .join(group) }
            return unit.isSpacer ? nil : .groupWith(unit.widgets[0].id)
        }
    }

    /// The ID of the group `choice` puts `id` in.
    func group(of choice: Choice) -> String {
        switch choice {
        case let .join(group): group
        case .groupWith: newGroupID()
        }
    }

    func edits(_ choice: Choice, for id: String) throws -> [ConfigurationEdit] {
        switch choice {
        case let .join(group) where editingProfile == nil && theme.groups.contains(group):
            // The position stays in the main file, where moving the group later moves every member.
            var edits = [try themeEdit(ConfigurationEdit(action: .set, id: id, properties: ["group": .string(group)]))]
            if let position = position(ofGroup: group), position != self.position(ofWidget: id) {
                edits.append(ConfigurationEdit(action: .set, id: id, properties: ["position": .string(position.rawValue)]))
            }
            return edits
        case let .join(group):
            return [joining(id, group: group, position: position(ofGroup: group) ?? position(ofWidget: id))]
        case let .groupWith(other):
            let group = newGroupID()
            return [ConfigurationEdit(action: .groups, properties: [group: Self.newGroup(defaults: defaults, groupDefaults: groupDefaults)]),
                    joining(id, group: group, position: position(ofWidget: other)), joining(other, group: group, position: position(ofWidget: other))]
        }
    }

    func canLeave(_ id: String) -> Bool {
        widgets.first(where: { $0.id == id })?.ownGroup != nil && leaveBlocker(id) == nil
    }

    /// Why `id` can't leave the group it's in, if it can't.
    func leaveBlocker(_ id: String) -> String? {
        guard widgets.contains(where: { $0.id == id }) else { return nil }
        if let origin = profileElsewhere(setting: id), let profile = origin.profile {
            return "The profile “\(profile)” in \(URL(filePath: origin.file).lastPathComponent) puts this widget in the group. Change it there."
        }
        let left = WidgetGroupConfiguration.joining(widgets, groups: groups) { $0.id == id ? nil : $0.ownGroup }
        if left.first(where: { $0.id == id })?.joinedGroup != nil {
            return "This widget joins the group through its members, which your theme or configuration sets."
        }
        return nil
    }

    /// Why Ungroup can't take every widget out of `group`, if it can't.
    func ungroupBlocker(_ group: String) -> String? {
        guard groups[group] != nil else { return "Only this screen's own theme has this group, so it can't be ungrouped here." }
        return widgets.first { $0.ownGroup == group && profileElsewhere(setting: $0.id) != nil }.flatMap { leaveBlocker($0.id) }
    }

    /// The origin of `id`'s group when an active profile of another file sets it: the profile merges after anything
    /// Settings can write, so no edit here takes the widget out.
    private func profileElsewhere(setting id: String) -> ConfigurationOrigin? {
        origins["widgets.\(id).group"].flatMap { $0.profile != nil && $0.file != mainFile ? $0 : nil }
    }

    /// Takes `id` out of its own group in the profile being edited, else in the main file or the profile of it that
    /// sets the group. An edit of the selected theme that sets it is removed. A `null` hides a group that a layer below
    /// sets: an included file, a package or a template.
    func leaving(_ id: String) throws -> [ConfigurationEdit] {
        guard widgets.first(where: { $0.id == id })?.ownGroup != nil, profileElsewhere(setting: id) == nil else { return [] }
        var document = try mainDocument()
        let themeEdits = ThemeEdits(main: document, themeID: theme.id)
        if let change = themeChange(id, in: themeEdits) { return [themeEdits.removal(of: [change])!] }
        let layer = self.layer(setting: id)
        if let layer {
            let profiles = try document["profiles"]?.decoded([[String: ConfigurationValue]].self) ?? []
            document = try profiles.first { $0["name"] == .string(layer) }?["configuration"]?.decoded([String: ConfigurationValue].self) ?? [:]
        }
        let definition = try document["widgets"]?.decoded([[String: ConfigurationValue]].self).first { $0["id"] == .string(id) }
        let override = try document["widgetOverrides"]?.decoded([String: [String: ConfigurationValue]].self)[id]
        var edits: [ConfigurationEdit] = []
        if let definition {
            if override?["group"] != nil {
                edits.append(ConfigurationEdit(action: .unset, properties: ["widgetOverrides": .object([id: .object(["group": .null])])]))
            }
            if definition["template"] != nil {
                edits.append(ConfigurationEdit(action: .set, id: id, properties: ["group": .null]))
            } else if definition["group"] != nil {
                edits.append(ConfigurationEdit(action: .unset, id: id, properties: ["group": .null]))
            }
        } else {
            edits.append(ConfigurationEdit(action: .set, id: id, properties: ["group": .null]))
        }
        return edits.map { edit in
            var edit = edit
            edit.profile = layer
            return edit
        }
    }

    /// Takes every widget out of `group`, and removes its definition when only the main file has it and nothing else
    /// there names it.
    func dissolving(_ group: String) throws -> [ConfigurationEdit] {
        let own = widgets.filter { $0.ownGroup == group }
        let themeEdits = ThemeEdits(main: try mainDocument(), themeID: theme.id)
        // One removal for every member, so that it deletes the theme's profile once nothing else is left in it.
        let themed = Dictionary(uniqueKeysWithValues: own.compactMap { member in themeChange(member.id, in: themeEdits).map { (member.id, $0) } })
        var edits = try own.filter { themed[$0.id] == nil }.flatMap { try leaving($0.id) }
        edits += [themeEdits.removal(of: Array(themed.values))].compactMap { $0 }
        let definition = origins.filter { $0.key == "groups.\(group)" || $0.key.hasPrefix("groups.\(group).") }.values
        let namedElsewhere = contributions.contains { path, entries in
            path.hasSuffix(".group") && entries.contains { $0.origin.file != mainFile && $0.value == .string(group) }
        }
        let removable = editingProfile == nil && !definition.isEmpty && !namedElsewhere
            && definition.allSatisfy { $0.file == mainFile && $0.profile == nil }
            && own.allSatisfy { origins["widgets.\($0.id).group"].map { $0.file == mainFile && $0.profile == nil } == true }
        var document = removable ? try mainDocument() : [:]
        // A member defined elsewhere, such as in an included file, may still name the group under its `null`.
        let defined = try document["widgets"]?.decoded([[String: ConfigurationValue]].self).map { $0["id"] } ?? []
        if removable, own.allSatisfy({ defined.contains(.string($0.id)) }) {
            var ids = widgets.map(\.id)
            for edit in edits { document = try edit.applying(to: document, widgetIDs: &ids) }
            document["groups"] = nil
            if !names(group, in: .object(document)), !profiles.contains(where: { names(group, in: .object($0.configuration)) }) {
                return edits + [ConfigurationEdit(action: .unset, properties: ["groups": .object([group: .null])])]
            }
        }
        if groups[group]?.members.isEmpty == false {
            let emptying = ConfigurationEdit(action: .groups, properties: [group: .object(["members": .array([])])])
            edits.append(editingProfile == nil && theme.groups.contains(group) ? try themeEdit(emptying) : emptying)
        }
        return edits
    }

    /// The main file's layer that sets `id`'s group: the profile being edited, else the main file or one of its profiles.
    private func layer(setting id: String) -> String? {
        let origin = origins["widgets.\(id).group"]
        return editingProfile ?? (origin?.file == mainFile ? origin?.profile : nil)
    }

    /// The edit of the selected theme that puts `id` in its group, when the group comes from that edit.
    private func themeChange(_ id: String, in themeEdits: ThemeEdits) -> ThemeEdit? {
        guard let layer = self.layer(setting: id), layer == themeEdits.profile else { return nil }
        return themeEdits.changes.first { $0.path == ["widgetOverrides", id, "group"] }
    }

    /// `edit` as an edit of the selected theme, in the main file's profile of its edits, created on the first one.
    private func themeEdit(_ edit: ConfigurationEdit) throws -> ConfigurationEdit {
        var edit = edit
        edit.profile = ThemeEdits(main: try mainDocument(), themeID: theme.id).profileName(theme: theme.name)
        edit.profileConditions = ["theme": .string(theme.id)]
        return edit
    }

    private func joining(_ id: String, group: String, position: WidgetPosition?) -> ConfigurationEdit {
        var properties: [String: ConfigurationValue] = ["group": .string(group)]
        if let position, position != self.position(ofWidget: id) { properties["position"] = .string(position.rawValue) }
        return ConfigurationEdit(action: .set, id: id, properties: properties)
    }

    private func position(ofWidget id: String) -> WidgetPosition? {
        widgets.first { $0.id == id }?.position
    }

    /// Where the group's own members sit in the shared configuration, which the members it gains must share. A group
    /// that takes others has a pill in each position, so a widget joins the one beside it.
    private func position(ofGroup group: String) -> WidgetPosition? {
        guard !groups[group]!.takesOthers else { return nil }
        return widgets.first { $0.ownGroup == group }?.position ?? widgets.first { $0.group == group }?.position
    }

    private func newGroupID() -> String {
        let taken = Set(groups.keys).union(profiles.flatMap { profile in
            (try? profile.configuration["groups"]?.decoded([String: ConfigurationValue].self).keys).map(Array.init) ?? []
        })
        guard taken.contains("group") else { return "group" }
        var number = 2
        while taken.contains("group-\(number)") { number += 1 }
        return "group-\(number)"
    }

    private func names(_ group: String, in value: ConfigurationValue) -> Bool {
        switch value {
        case let .object(object): object["group"] == .string(group) || object.values.contains { names(group, in: $0) }
        case let .array(array): array.contains { names(group, in: $0) }
        default: false
        }
    }
}

extension WidgetGrouping {
    init(store: BarStore) {
        let configuration = store.configuration
        let loader = store.configurationStore.configurationLoader
        let themeID = String(store.configurationStore.selectedThemeKey.prefix { $0 != "/" })
        let themeFiles = loader.packageIDs.filter { $0.value == themeID }.keys
        let themeGroups = configuration?.groups.keys.filter { group in
            store.contributions["groups.\(group)"]?.contains { themeFiles.contains($0.origin.file) } == true
        } ?? []
        self.init(widgets: configuration?.widgets ?? [], groups: configuration?.groups ?? [:],
                  profiles: store.profiles,
                  contributions: store.contributions,
                  defaults: configuration?.defaults ?? WidgetStyle(), groupDefaults: configuration?.groupDefaults ?? WidgetStyle(),
                  origins: store.origins,
                  mainFile: store.configurationStore.configurationURL.standardizedFileURL.path,
                  editingProfile: store.customizationHistory.editingProfile,
                  theme: (themeID, themeFiles.first.flatMap { loader.packageNames[$0] } ?? themeID, Set(themeGroups)),
                  mainDocument: { [weak store] in try store?.configurationStore.editedMainDocument(replaying: store?.configurationStore.customizationEdits) ?? [:] })
    }
}
