import Foundation

enum PresentationRole: String, Decodable, CaseIterable, Sendable {
    case time, primary, secondary, key, value, heading, button, meter, separator
}

/// Only presentation belongs in workspace defaults. Workspace visibility and local app-glyph
/// mappings remain widget-owned. Keep raw nulls until the widget layer has merged.
struct WorkspaceDefaults: Decodable, Sendable {
    let properties: [String: ConfigurationValue]

    enum CodingKeys: String, CodingKey, CaseIterable { case indicator, indicatorStyle, style, appStyle, groupDivider }

    init() { properties = [:] }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        _ = try values.decodeIfPresent(WorkspaceConfiguration.Indicator.self, forKey: .indicator)
        _ = try values.decodeIfPresent(Bool.self, forKey: .groupDivider)
        for key in [CodingKeys.indicatorStyle, .style, .appStyle] {
            _ = try values.decodeIfPresent(WidgetStyle.self, forKey: key)
        }
        properties = try decoder.singleValueContainer().decode([String: ConfigurationValue].self)
    }

    func merging(_ own: ConfigurationValue?) throws -> WorkspaceConfiguration? {
        guard !properties.isEmpty || (own != nil && own != .null) else { return nil }
        return try ConfigurationValue.object(mergedProperties(own)).decoded(WorkspaceConfiguration.self)
    }

    func mergedProperties(_ own: ConfigurationValue?) throws -> [String: ConfigurationValue] {
        let own = try own.flatMap { $0 == .null ? nil : try $0.decoded([String: ConfigurationValue].self) } ?? [:]
        let normalized = try normalizedWorkspaceStates(own)
        return try ConfigurationValue.object(normalized).overriding(.object(properties)).decoded([String: ConfigurationValue].self)
    }
}

/// Canonicalize a widget's legacy aliases before layering it over workspaceDefaults, so its
/// focusedStyle overrides a theme's states.focused property by property. Explicit states in the
/// same widget still beat the shorthand, exactly as before.
private func normalizedWorkspaceStates(_ object: [String: ConfigurationValue]) throws -> [String: ConfigurationValue] {
    var result = object
    for (key, aliases) in [("style", ["focusedStyle": "focused", "visibleStyle": "visible", "emptyStyle": "empty"]),
                            ("appStyle", ["focusedAppStyle": "focused", "visibleAppStyle": "visible"])] {
        var states: [String: ConfigurationValue] = [:]
        for (alias, state) in aliases {
            if let value = object[alias], value != .null {
                states[state] = try value.decoded(WidgetStyle.self).configurationValue
            }
            result.removeValue(forKey: alias)
        }
        let explicit = object[key].map(canonicalWorkspaceHover)
        guard !states.isEmpty else {
            if let explicit { result[key] = explicit }
            continue
        }
        let aliases = ConfigurationValue.object(["states": .object(states)])
        result[key] = workspaceAliasFallback(explicit, aliases)
    }
    return result
}

/// Normalize an explicit state's hover shorthand before merging a workspace shorthand beneath
/// it. Otherwise the alias's canonical states.hover would incorrectly beat explicit hoverBackground.
private func canonicalWorkspaceHover(_ value: ConfigurationValue) -> ConfigurationValue {
    guard case var .object(style) = value else { return value }
    var states: [String: ConfigurationValue]?
    if case let .object(values)? = style["states"] { states = values.mapValues(canonicalWorkspaceHover) }
    var hover: [String: ConfigurationValue] = [:]
    for (key, property) in [("hoverBackground", "background"), ("hoverForeground", "foreground")] {
        if let value = style[key], value != .null { hover[property] = value }
    }
    if !hover.isEmpty {
        var merged = states ?? [:]
        merged["hover"] = workspaceAliasFallback(merged["hover"], .object(hover))
        states = merged
    }
    if let states { style["states"] = .object(states) }
    return .object(style)
}

/// Within a workspace, null explicit state properties fall back to a non-null shorthand value,
/// just like WidgetStyle.addingStates. Keep other explicit nulls so they can clear defaults.
private func workspaceAliasFallback(_ explicit: ConfigurationValue?, _ alias: ConfigurationValue) -> ConfigurationValue {
    guard let explicit, explicit != .null else { return alias }
    if case let .object(own) = explicit, case let .object(base) = alias, !explicit.isGradient, !alias.isGradient {
        return .object(base.merging(own) { workspaceAliasFallback($1, $0) })
    }
    return explicit
}

extension Configuration {
    func roleStyle(_ role: PresentationRole?) -> WidgetStyle {
        role.flatMap { roles[$0.rawValue] } ?? WidgetStyle()
    }
}

extension WidgetStyle {
    /// Query/Diagnostics use the same names as authoring, including resolved values and states.
    var configurationValue: ConfigurationValue {
        var value: [String: ConfigurationValue] = [:]
        for (key, color) in [("foreground", foreground), ("borderColor", borderColor),
                             ("accent", accent), ("accentText", accentText), ("shadowColor", shadowColor)] {
            if let color { value[key] = color.configurationValue }
        }
        if let background { value["background"] = background.configurationValue }
        for (key, number) in [("borderWidth", borderWidth), ("cornerRadius", cornerRadius), ("fontSize", fontSize),
                              ("iconSize", iconSize), ("paddingHorizontal", paddingHorizontal), ("paddingVertical", paddingVertical),
                              ("spacing", spacing), ("width", width), ("minWidth", minWidth), ("maxWidth", maxWidth),
                              ("height", height), ("shadowRadius", shadowRadius), ("paddingLeading", paddingLeading),
                              ("paddingTrailing", paddingTrailing), ("paddingTop", paddingTop), ("paddingBottom", paddingBottom),
                              ("offsetX", offsetX), ("offsetY", offsetY), ("opacity", opacity)] {
            if let number { value[key] = .number(number) }
        }
        for (key, text) in [("fontName", fontName), ("fontWeight", fontWeight), ("borderEdges", borderEdges?.rawValue),
                            ("placement", placement?.rawValue)] {
            if let text { value[key] = .string(text) }
        }
        if let states { value["states"] = .object(states.mapValues(\.configurationValue)) }
        return .object(value)
    }

    /// Box properties belong to the block that declares them. Only text, accent and spacing
    /// (including their nested states) propagate into its children.
    var inheritedByBlocks: WidgetStyle {
        WidgetStyle(foreground: foreground, accent: accent, accentText: accentText, fontName: fontName,
                    fontSize: fontSize, fontWeight: fontWeight, iconSize: iconSize, spacing: spacing,
                    states: states?.mapValues(\.inheritedByBlocks))
    }
}
