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
    /// Every profile, from any file: a new group mustn't take an ID one defines, which would merge with theirs, and a
    /// group one names stays defined.
    var profiles: [ConfigurationProfile] = []
    let defaults: WidgetStyle
    let origins: [String: ConfigurationOrigin]
    /// The standardized path of the main configuration file.
    let mainFile: String
    /// The profile Settings is editing; its changes go there.
    let editingProfile: String?
    /// The main file with the unsaved Settings changes, read only to dissolve a group.
    let mainDocument: () throws -> [String: ConfigurationValue]

    /// A new group's look, which Settings then offers to change: a faint backdrop that works in light and dark.
    static func newGroupStyle(defaults: WidgetStyle) -> [String: ConfigurationValue] {
        ["background": .string("#8080802e"), "cornerRadius": .number(defaults.cornerRadius ?? 14), "paddingHorizontal": .number(4)]
    }

    /// The choices for `id` among `listed`, the widgets one screen shows in their order: the units on either side of
    /// it in its position, except spacers.
    func choices(for id: String, among listed: [WidgetConfiguration]) -> [Choice] {
        guard let widget = listed.first(where: { $0.id == id }), widget.group == nil, widget.content != .spacer else { return [] }
        let units = BarUnit.make(widgets: listed.filter { $0.position == widget.position }, groups: groups)
        guard let index = units.firstIndex(where: { $0.id == "widget:\(id)" }) else { return [] }
        return [index - 1, index + 1].filter(units.indices.contains).map { units[$0] }.compactMap { unit in
            if let group = unit.widgets[0].group { return .join(group) }
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

    func edits(_ choice: Choice, for id: String) -> [ConfigurationEdit] {
        switch choice {
        case let .join(group):
            return [joining(id, group: group, position: position(ofGroup: group) ?? position(ofWidget: id))]
        case let .groupWith(other):
            let group = newGroupID()
            return [ConfigurationEdit(action: .groups, properties: [group: .object(["style": .object(Self.newGroupStyle(defaults: defaults))])]),
                    joining(id, group: group, position: position(ofWidget: other)), joining(other, group: group, position: position(ofWidget: other))]
        }
    }

    /// Whether `id` can leave its group. A widget that a group's `members` take in would only join it again.
    func canLeave(_ id: String) -> Bool {
        guard widgets.first(where: { $0.id == id })?.ownGroup != nil else { return false }
        let left = WidgetGroupConfiguration.joining(widgets, groups: groups) { $0.id == id ? nil : $0.ownGroup }
        return left.first { $0.id == id }?.joinedGroup == nil
    }

    /// Takes `id` out of its own group in the profile being edited, else in the main file or the profile of it that
    /// sets the group. A `null` hides a group that a layer below sets: an included file, a package or a template.
    func leaving(_ id: String) throws -> [ConfigurationEdit] {
        guard widgets.first(where: { $0.id == id })?.ownGroup != nil else { return [] }
        let origin = origins["widgets.\(id).group"]
        let layer = editingProfile ?? (origin?.file == mainFile ? origin?.profile : nil)
        var document = try mainDocument()
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
        var edits = try own.flatMap { try leaving($0.id) }
        let definition = origins.filter { $0.key == "groups.\(group)" || $0.key.hasPrefix("groups.\(group).") }.values
        let removable = editingProfile == nil && !definition.isEmpty
            && definition.allSatisfy { $0.file == mainFile && $0.profile == nil }
            && own.allSatisfy { origins["widgets.\($0.id).group"].map { $0.file == mainFile && $0.profile == nil } == true }
        if removable {
            var document = try mainDocument()
            var ids = widgets.map(\.id)
            for edit in edits { document = try edit.applying(to: document, widgetIDs: &ids) }
            document["groups"] = nil
            if !names(group, in: .object(document)), !profiles.contains(where: { names(group, in: .object($0.configuration)) }) {
                return edits + [ConfigurationEdit(action: .unset, properties: ["groups": .object([group: .null])])]
            }
        }
        if groups[group]?.members.isEmpty == false {
            edits.append(ConfigurationEdit(action: .groups, properties: [group: .object(["members": .array([])])]))
        }
        return edits
    }

    private func joining(_ id: String, group: String, position: WidgetPosition?) -> ConfigurationEdit {
        var properties: [String: ConfigurationValue] = ["group": .string(group)]
        if let position, position != self.position(ofWidget: id) { properties["position"] = .string(position.rawValue) }
        return ConfigurationEdit(action: .set, id: id, properties: properties)
    }

    private func position(ofWidget id: String) -> WidgetPosition? {
        widgets.first { $0.id == id }?.position
    }

    /// Where the group's own members sit in the shared configuration, which the members it gains must share.
    private func position(ofGroup group: String) -> WidgetPosition? {
        widgets.first { $0.ownGroup == group }?.position ?? widgets.first { $0.group == group }?.position
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
        self.init(widgets: configuration?.widgets ?? [], groups: configuration?.groups ?? [:],
                  profiles: store.profiles,
                  defaults: configuration?.defaults ?? WidgetStyle(), origins: store.origins,
                  mainFile: store.configurationURL.standardizedFileURL.path,
                  editingProfile: store.customizationHistory.editingProfile,
                  mainDocument: { [weak store] in try store?.editedMainDocument(replaying: store?.customizationEdits) ?? [:] })
    }
}
