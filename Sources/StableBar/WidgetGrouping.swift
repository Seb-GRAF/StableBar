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
        guard let widget = widgets.first(where: { $0.id == id }), widget.ownGroup != nil else { return false }
        return !groups.values.contains { $0.members.contains { $0.matches(widget) } }
    }

    func leaving(_ id: String) -> ConfigurationEdit? {
        guard let widget = widgets.first(where: { $0.id == id }), widget.ownGroup != nil else { return nil }
        if let origin = origins["widgets.\(id).group"], origin.file == mainFile {
            if editingProfile == nil, origin.profile == nil {
                return ConfigurationEdit(action: .unset, id: id, properties: ["group": .null])
            }
            if let profile = origin.profile, editingProfile == nil || editingProfile == profile {
                var edit = ConfigurationEdit(action: .unset, id: id, properties: ["group": .null])
                edit.profile = profile
                return edit
            }
        }
        // A group set in another file, or outside the profile being edited, is overridden instead.
        return ConfigurationEdit(action: .set, id: id, properties: ["group": .null])
    }

    /// Takes every widget out of `group`, and removes its definition when only the main file has it and nothing else
    /// there names it.
    func dissolving(_ group: String) throws -> [ConfigurationEdit] {
        let own = widgets.filter { $0.ownGroup == group }
        var edits = own.compactMap { leaving($0.id) }
        let definition = origins.filter { $0.key == "groups.\(group)" || $0.key.hasPrefix("groups.\(group).") }.values
        let removable = editingProfile == nil && !definition.isEmpty
            && definition.allSatisfy { $0.file == mainFile && $0.profile == nil }
            && own.allSatisfy { origins["widgets.\($0.id).group"].map { $0.file == mainFile && $0.profile == nil } == true }
        if removable {
            var document = try mainDocument()
            var ids = widgets.map(\.id)
            for edit in edits { document = try edit.applying(to: document, widgetIDs: &ids) }
            document["groups"] = nil
            if !names(group, in: .object(document)) {
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
        guard groups["group"] != nil else { return "group" }
        var number = 2
        while groups["group-\(number)"] != nil { number += 1 }
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
                  defaults: configuration?.defaults ?? WidgetStyle(), origins: store.origins,
                  mainFile: store.configurationURL.standardizedFileURL.path,
                  editingProfile: store.customizationHistory.editingProfile,
                  mainDocument: { [weak store] in try store?.editedMainDocument(replaying: store?.customizationEdits) ?? [:] })
    }
}
