import Foundation

struct ThemeOverride: Equatable {
    let path: [String]
    let title: String
}

struct ThemeOverrides {
    let values: [ThemeOverride]

    var notice: String {
        "Your settings override this theme in \(values.count) \(values.count == 1 ? "place" : "places")."
    }

    init(main: [String: ConfigurationValue], theme: [String: ConfigurationValue],
         widgets: [WidgetConfiguration], activeProfiles: [String] = []) {
        var found: [ThemeOverride] = []
        let widgetRoles = Dictionary(uniqueKeysWithValues: widgets.compactMap { widget in
            widget.role.map { (widget.id, $0.rawValue) }
        })
        func inspect(_ document: [String: ConfigurationValue], prefix: [String] = [], suffix: String = "") {
            for key in ["tokens", "defaults", "popupDefaults", "roles", "workspaceDefaults", "bar", "groups"] {
                guard let own = document[key] else { continue }
                var themed = theme[key]
                if key == "tokens" {
                    // Theme colors also include colors inherited from Built-in.
                    let colors = ConfigurationValue.object(Dictionary(uniqueKeysWithValues: themeTokens.map { ($0.name, ConfigurationValue.null) }))
                    themed = themed.map { $0.overriding(colors) } ?? colors
                }
                guard let themed else { continue }
                for path in overlapping(own, themed, path: [key]) where path != ["bar", "appearance"] {
                    found.append(ThemeOverride(path: prefix + path, title: overrideTitle(path) + suffix))
                }
            }
            var definitions: [(String, [String: ConfigurationValue], [String])] = []
            if case let .array(widgets) = document["widgets"] {
                for case let .object(widget) in widgets {
                    if case let .string(id) = widget["id"] { definitions.append((id, widget, ["widgets", id])) }
                }
            }
            if case let .object(overrides) = document["widgetOverrides"] {
                for (id, value) in overrides {
                    if case let .object(widget) = value { definitions.append((id, widget, ["widgetOverrides", id])) }
                }
            }
            for (id, widget, path) in definitions {
                guard let own = widget["style"] else { continue }
                var style = theme["defaults"] ?? .object([:])
                if let role = widgetRoles[id], case let .object(roles) = theme["roles"], let themed = roles[role] {
                    style = themed.overriding(style)
                }
                for property in overlapping(own, style) {
                    found.append(ThemeOverride(path: prefix + path + ["style"] + property,
                        title: "\(friendly(id)): \(detailTitle(property))" + suffix))
                }
            }
        }
        inspect(main)
        if case let .array(profiles) = main["profiles"] {
            for case let .object(profile) in profiles {
                if case let .string(name) = profile["name"], activeProfiles.contains(name),
                   case let .object(configuration) = profile["configuration"] {
                    inspect(configuration, prefix: ["profiles", name, "configuration"], suffix: " (\(name))")
                }
            }
        }
        values = found.sorted { $0.path.lexicographicallyPrecedes($1.path) }
    }

    var resetEdit: ConfigurationEdit {
        var properties: [String: ConfigurationValue] = [:]
        for value in values {
            guard let key = value.path.first else { continue }
            let removal = value.path.dropFirst().reversed().reduce(ConfigurationValue.null) { .object([$1: $0]) }
            properties[key] = removal.overriding(properties[key] ?? .object([:]))
        }
        return ConfigurationEdit(action: .unset, properties: properties)
    }
}

/// Compare raw paths, before token substitution, including an entire value that masks a subtree.
private func overlapping(_ main: ConfigurationValue, _ theme: ConfigurationValue, path: [String] = []) -> [[String]] {
    if case let .object(themed) = theme, themed.isEmpty { return [] }
    if case let .object(own) = main {
        if case let .object(themed) = theme {
            return own.keys.sorted().flatMap { key in
                themed[key].map { overlapping(own[key]!, $0, path: path + [key]) } ?? []
            }
        }
        return own.keys.sorted().flatMap { overlapping(own[$0]!, theme, path: path + [$0]) }
    }
    return [path]
}

private func overrideTitle(_ path: [String]) -> String {
    let tail = Array(path.dropFirst())
    switch path.first {
    case "tokens":
        let name = themeTokens.first { $0.name == tail.first }?.title ?? friendly(tail.first ?? "")
        return appearanceTitle(name.lowercased().hasSuffix("color") ? name : "\(name) color", appearance: tail.last)
    case "defaults": return "All widgets: \(detailTitle(tail))"
    case "popupDefaults": return "Popups: \(detailTitle(tail))"
    case "roles": return "\(friendly(tail.first ?? "")) widgets: \(detailTitle(Array(tail.dropFirst())))"
    case "workspaceDefaults": return "Workspaces: \(detailTitle(tail))"
    case "groups": return "\(friendly(tail.first ?? "")) group: \(detailTitle(Array(tail.dropFirst().filter { $0 != "style" })))"
    case "bar":
        if tail == ["height"] { return "Bar height" }
        return "Bar: \(detailTitle(tail.filter { $0 != "style" }))"
    default: return styleTitle(path)
    }
}

private func detailTitle(_ path: [String]) -> String {
    let title = styleTitle(path)
    return title.prefix(1).lowercased() + title.dropFirst()
}

private func styleTitle(_ path: [String]) -> String {
    let appearance = ["light", "dark"].contains(path.last ?? "") ? path.last : nil
    let title = path.filter { $0 != "states" && $0 != appearance }.map { key in
        ["foreground": "Text color", "background": "Background", "borderColor": "Border color",
         "shadowColor": "Shadow color", "hoverBackground": "Hover background", "hoverForeground": "Hover text color",
         "fontName": "Font", "fontSize": "Font size", "fontWeight": "Font weight", "inset": "Side inset",
         "paddingHorizontal": "Horizontal padding", "paddingVertical": "Vertical padding",
         "paddingLeading": "Leading padding", "paddingTrailing": "Trailing padding", "paddingTop": "Top padding",
         "paddingBottom": "Bottom padding", "offsetX": "Horizontal offset", "offsetY": "Vertical offset",
         "minWidth": "Minimum width", "maxWidth": "Maximum width", "cornerRadius": "Corner radius",
         "offset": "Offset from top", "surface": "Surface", "surfaceRaised": "Raised surface", "text": "Text",
         "textMuted": "Muted text", "hairline": "Hairline", "accentText": "Accent text color"][key] ?? friendly(key)
    }.joined(separator: ": ")
    return appearanceTitle(title, appearance: appearance)
}

private func appearanceTitle(_ title: String, appearance: String?) -> String {
    guard let appearance, ["light", "dark"].contains(appearance) else { return title }
    return "\(title) in \(appearance) mode"
}

private func friendly(_ value: String) -> String {
    let spaced = value.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        .replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        .lowercased()
    return spaced.prefix(1).uppercased() + spaced.dropFirst()
}

extension ThemeChoice {
    /// Raw theme values keep token references intact for the override notice.
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
