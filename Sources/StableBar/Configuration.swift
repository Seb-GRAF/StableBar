import AppKit
import SwiftUI

struct HexColor: Decodable, Equatable, Sendable {
    let rgba: UInt32

    init(_ rgba: UInt32) {
        self.rgba = rgba
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        let hex = string.dropFirst()
        guard string.hasPrefix("#"), [6, 8].contains(hex.count),
              let value = UInt32(hex, radix: 16) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Use #RRGGBB or #RRGGBBAA for colors.")
        }
        rgba = hex.count == 6 ? (value << 8) | 0xff : value
    }

    var color: Color {
        Color(.sRGB, red: Double(rgba >> 24) / 255,
              green: Double((rgba >> 16) & 0xff) / 255,
              blue: Double((rgba >> 8) & 0xff) / 255,
              opacity: Double(rgba & 0xff) / 255)
    }

    var hex: String { String(format: "#%08x", rgba) }
}

struct WidgetStyle: Decodable, Equatable, Sendable {
    var foreground: HexColor?
    var background: HexColor?
    var hoverBackground: HexColor?
    var borderColor: HexColor?
    var accent: HexColor?
    var accentText: HexColor?
    var borderWidth: Double?
    var cornerRadius: Double?
    var fontName: String?
    var fontSize: Double?
    var fontWeight: String?
    var iconSize: Double?
    var paddingHorizontal: Double?
    var paddingVertical: Double?
    var spacing: Double?
    var width: Double?
    var minWidth: Double?
    var maxWidth: Double?
    var shadowRadius: Double?
    var shadowColor: HexColor?
    var height: Double?
    var paddingLeading: Double?
    var paddingTrailing: Double?
    var paddingTop: Double?
    var paddingBottom: Double?
    var offsetX: Double?
    var offsetY: Double?
    var opacity: Double?
    var hoverForeground: HexColor?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case foreground, background, hoverBackground, borderColor, accent, accentText, borderWidth, cornerRadius
        case fontName, fontSize, fontWeight, iconSize, paddingHorizontal, paddingVertical, spacing, width
        case minWidth, maxWidth, shadowRadius, shadowColor, height, paddingLeading, paddingTrailing, paddingTop
        case paddingBottom, offsetX, offsetY, opacity, hoverForeground
    }

    func inheriting(_ defaults: WidgetStyle) -> WidgetStyle {
        WidgetStyle(
            foreground: foreground ?? defaults.foreground,
            background: background ?? defaults.background,
            hoverBackground: hoverBackground ?? defaults.hoverBackground,
            borderColor: borderColor ?? defaults.borderColor,
            accent: accent ?? defaults.accent,
            accentText: accentText ?? defaults.accentText,
            borderWidth: borderWidth ?? defaults.borderWidth,
            cornerRadius: cornerRadius ?? defaults.cornerRadius,
            fontName: fontName ?? defaults.fontName,
            fontSize: fontSize ?? defaults.fontSize,
            fontWeight: fontWeight ?? defaults.fontWeight,
            iconSize: iconSize ?? defaults.iconSize,
            paddingHorizontal: paddingHorizontal ?? defaults.paddingHorizontal,
            paddingVertical: paddingVertical ?? defaults.paddingVertical,
            spacing: spacing ?? defaults.spacing,
            width: width ?? defaults.width,
            minWidth: minWidth ?? defaults.minWidth,
            maxWidth: maxWidth ?? defaults.maxWidth,
            shadowRadius: shadowRadius ?? defaults.shadowRadius,
            shadowColor: shadowColor ?? defaults.shadowColor,
            height: height ?? defaults.height,
            paddingLeading: paddingLeading ?? defaults.paddingLeading,
            paddingTrailing: paddingTrailing ?? defaults.paddingTrailing,
            paddingTop: paddingTop ?? defaults.paddingTop,
            paddingBottom: paddingBottom ?? defaults.paddingBottom,
            offsetX: offsetX ?? defaults.offsetX,
            offsetY: offsetY ?? defaults.offsetY,
            opacity: opacity ?? defaults.opacity,
            hoverForeground: hoverForeground ?? defaults.hoverForeground
        )
    }
}

extension WidgetStyle {
    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        foreground = try values.decodeIfPresent(HexColor.self, forKey: .foreground)
        background = try values.decodeIfPresent(HexColor.self, forKey: .background)
        hoverBackground = try values.decodeIfPresent(HexColor.self, forKey: .hoverBackground)
        borderColor = try values.decodeIfPresent(HexColor.self, forKey: .borderColor)
        accent = try values.decodeIfPresent(HexColor.self, forKey: .accent)
        accentText = try values.decodeIfPresent(HexColor.self, forKey: .accentText)
        borderWidth = try values.decodeIfPresent(Double.self, forKey: .borderWidth)
        cornerRadius = try values.decodeIfPresent(Double.self, forKey: .cornerRadius)
        fontName = try values.decodeIfPresent(String.self, forKey: .fontName)
        fontSize = try values.decodeIfPresent(Double.self, forKey: .fontSize)
        fontWeight = try values.decodeIfPresent(String.self, forKey: .fontWeight)
        iconSize = try values.decodeIfPresent(Double.self, forKey: .iconSize)
        paddingHorizontal = try values.decodeIfPresent(Double.self, forKey: .paddingHorizontal)
        paddingVertical = try values.decodeIfPresent(Double.self, forKey: .paddingVertical)
        spacing = try values.decodeIfPresent(Double.self, forKey: .spacing)
        width = try values.decodeIfPresent(Double.self, forKey: .width)
        minWidth = try values.decodeIfPresent(Double.self, forKey: .minWidth)
        maxWidth = try values.decodeIfPresent(Double.self, forKey: .maxWidth)
        shadowRadius = try values.decodeIfPresent(Double.self, forKey: .shadowRadius)
        shadowColor = try values.decodeIfPresent(HexColor.self, forKey: .shadowColor)
        height = try values.decodeIfPresent(Double.self, forKey: .height)
        paddingLeading = try values.decodeIfPresent(Double.self, forKey: .paddingLeading)
        paddingTrailing = try values.decodeIfPresent(Double.self, forKey: .paddingTrailing)
        paddingTop = try values.decodeIfPresent(Double.self, forKey: .paddingTop)
        paddingBottom = try values.decodeIfPresent(Double.self, forKey: .paddingBottom)
        offsetX = try values.decodeIfPresent(Double.self, forKey: .offsetX)
        offsetY = try values.decodeIfPresent(Double.self, forKey: .offsetY)
        opacity = try values.decodeIfPresent(Double.self, forKey: .opacity)
        hoverForeground = try values.decodeIfPresent(HexColor.self, forKey: .hoverForeground)
    }

    static let light = WidgetStyle(foreground: HexColor(0x1d1d1fff), background: HexColor(0xf8f8faed), hoverBackground: HexColor(0xffffffff),
                                   borderColor: HexColor(0xffffffb3), shadowColor: HexColor(0x00000014))
    static let dark = WidgetStyle(foreground: HexColor(0xf5f5f7ff), background: HexColor(0x242629ee), hoverBackground: HexColor(0x36383cff),
                                  borderColor: HexColor(0xffffff1f), shadowColor: HexColor(0x00000040))
}

private func systemColor(_ color: KeyPath<WidgetStyle, HexColor?>) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let style = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? WidgetStyle.dark : WidgetStyle.light
        return NSColor(style[keyPath: color]!.color)
    })
}

struct WidgetAppearance {
    let foreground: Color
    let hoverForeground: Color
    let background: Color
    let hoverBackground: Color
    let borderColor: Color
    let accent: Color
    let accentText: Color
    let borderWidth: Double
    let cornerRadius: Double
    let font: Font
    let iconSize: Double
    let paddingHorizontal: Double
    let paddingVertical: Double
    let spacing: Double
    let width: CGFloat?
    let shadowRadius: Double
    let shadowColor: Color

    init(_ style: WidgetStyle, defaults: WidgetStyle) {
        foreground = (style.foreground ?? defaults.foreground)?.color ?? systemColor(\.foreground)
        hoverForeground = (style.hoverForeground ?? defaults.hoverForeground)?.color ?? foreground
        background = (style.background ?? defaults.background)?.color ?? systemColor(\.background)
        hoverBackground = (style.hoverBackground ?? defaults.hoverBackground)?.color ?? systemColor(\.hoverBackground)
        borderColor = (style.borderColor ?? defaults.borderColor)?.color ?? systemColor(\.borderColor)
        accent = (style.accent ?? defaults.accent ?? HexColor(0xf7821bff)).color
        accentText = (style.accentText ?? defaults.accentText ?? HexColor(0xffffffff)).color
        borderWidth = style.borderWidth ?? defaults.borderWidth ?? 1
        cornerRadius = style.cornerRadius ?? defaults.cornerRadius ?? 14
        iconSize = style.iconSize ?? defaults.iconSize ?? 13
        paddingHorizontal = style.paddingHorizontal ?? defaults.paddingHorizontal ?? 10
        paddingVertical = style.paddingVertical ?? defaults.paddingVertical ?? 6
        spacing = style.spacing ?? defaults.spacing ?? 6
        width = (style.width ?? defaults.width).map { CGFloat($0) }
        shadowRadius = style.shadowRadius ?? defaults.shadowRadius ?? 2
        shadowColor = (style.shadowColor ?? defaults.shadowColor)?.color ?? systemColor(\.shadowColor)
        let size = style.fontSize ?? defaults.fontSize ?? 12
        let name = style.fontName ?? defaults.fontName ?? "system"
        let weight: Font.Weight
        switch style.fontWeight ?? defaults.fontWeight ?? "medium" {
        case "ultralight": weight = .ultraLight
        case "thin": weight = .thin
        case "light": weight = .light
        case "regular": weight = .regular
        case "semibold": weight = .semibold
        case "bold": weight = .bold
        default: weight = .medium
        }
        font = name == "system" ? .system(size: size, weight: weight) : .custom(name, size: size).weight(weight)
    }
}

enum WidgetPosition: String, Decodable, Sendable, CaseIterable {
    case left, notchLeft, center, notchRight, right
}

enum WidgetContent: Equatable, Sendable {
    case spacer
    case provider(String)
    case workspaces
    case activeApp
    case clock(format: String)
    case text(String)
    case script(command: String, interval: Double?)
}

struct WidgetConfiguration: Decodable, Identifiable, Sendable {
    let id: String
    let position: WidgetPosition
    let content: WidgetContent
    let icon: String?
    let onClick: String?
    let menu: [WidgetMenuItem]?
    let popup: PopupConfiguration?
    let popupName: String?
    let style: WidgetStyle
    let display: DisplaySelection
    let layout: PopupBlock?
    let overlay: PopupBlock?
    let animation: WidgetAnimation?
    let workspace: WorkspaceConfiguration?
    let events: [String]
    let environment: [String: String]
    let timeout: Double
    let actions: WidgetActions?
    let enabled: Bool
    let group: String?
    let priority: Int
    let overflow: WidgetOverflow

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, position, type, icon, onClick, menu, popup, popupName, style, format, text, command, interval
        case display, layout, overlay, animation, workspace, events, environment, timeout, actions, enabled, provider, group, priority, overflow
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        position = try values.decode(WidgetPosition.self, forKey: .position)
        icon = try values.decodeIfPresent(String.self, forKey: .icon)
        onClick = try values.decodeIfPresent(String.self, forKey: .onClick)
        menu = try values.decodeIfPresent([WidgetMenuItem].self, forKey: .menu)
        popup = try values.decodeIfPresent(PopupConfiguration.self, forKey: .popup)
        popupName = try values.decodeIfPresent(String.self, forKey: .popupName)
        style = try values.decodeIfPresent(WidgetStyle.self, forKey: .style) ?? WidgetStyle()
        display = try values.decodeIfPresent(DisplaySelection.self, forKey: .display) ?? .all
        layout = try values.decodeIfPresent(PopupBlock.self, forKey: .layout)
        overlay = try values.decodeIfPresent(PopupBlock.self, forKey: .overlay)
        animation = try values.decodeIfPresent(WidgetAnimation.self, forKey: .animation)
        workspace = try values.decodeIfPresent(WorkspaceConfiguration.self, forKey: .workspace)
        events = try values.decodeIfPresent([String].self, forKey: .events) ?? []
        environment = try values.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        timeout = try values.decodeIfPresent(Double.self, forKey: .timeout) ?? 10
        guard timeout > 0, timeout.isFinite else {
            throw DecodingError.dataCorruptedError(forKey: .timeout, in: values, debugDescription: "A command timeout must be greater than zero and finite.")
        }
        actions = try values.decodeIfPresent(WidgetActions.self, forKey: .actions)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        group = try values.decodeIfPresent(String.self, forKey: .group)
        priority = try values.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        overflow = try values.decodeIfPresent(WidgetOverflow.self, forKey: .overflow) ?? .automatic
        switch try values.decode(String.self, forKey: .type) {
        case "spacer": content = .spacer
        case "provider": content = .provider(try values.decode(String.self, forKey: .provider))
        case "aerospace", "workspaces": content = .workspaces
        case "activeApp": content = .activeApp
        case "clock": content = .clock(format: try values.decodeIfPresent(String.self, forKey: .format) ?? "EEE d MMM  HH:mm")
        case "text": content = .text(try values.decode(String.self, forKey: .text))
        case "script":
            let interval = try values.contains(.interval) ? values.decodeIfPresent(Double.self, forKey: .interval) : 30
            if let interval, interval <= 0 {
                throw DecodingError.dataCorruptedError(forKey: .interval, in: values, debugDescription: "A script interval must be greater than zero.")
            }
            content = .script(command: try values.decode(String.self, forKey: .command), interval: interval)
        case let type:
            guard ProviderType(rawValue: type)?.isNative == true else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: values, debugDescription: "Unknown widget type.")
            }
            content = .provider(type)
        }
    }
}

struct BarSettings: Decodable, Sendable {
    var height = 40.0
    var displayScale: [String: Double] = [:]
    var offset = 0.0
    var inset = 12.0
    var spacing = 8.0
    var background = HexColor(0x00000000)
    var animationDuration = 0.22
    var notchWidth: Double?
    var notchSpacing = 16.0
    var style = WidgetStyle()

    enum CodingKeys: String, CodingKey, CaseIterable {
        case height, displayScale, offset, inset, spacing, background, animationDuration, notchWidth, notchSpacing, style
    }

    init() {}

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        height = try values.decodeIfPresent(Double.self, forKey: .height) ?? height
        displayScale = try values.decodeIfPresent([String: Double].self, forKey: .displayScale) ?? displayScale
        guard displayScale.allSatisfy({ ["builtIn", "external"].contains($0.key) && $0.value > 0 && $0.value.isFinite }) else {
            throw DecodingError.dataCorruptedError(forKey: .displayScale, in: values, debugDescription: "Use builtIn or external with a positive number.")
        }
        offset = try values.decodeIfPresent(Double.self, forKey: .offset) ?? offset
        inset = try values.decodeIfPresent(Double.self, forKey: .inset) ?? inset
        spacing = try values.decodeIfPresent(Double.self, forKey: .spacing) ?? spacing
        background = try values.decodeIfPresent(HexColor.self, forKey: .background) ?? background
        animationDuration = try values.decodeIfPresent(Double.self, forKey: .animationDuration) ?? animationDuration
        notchWidth = try values.decodeIfPresent(Double.self, forKey: .notchWidth)
        notchSpacing = try values.decodeIfPresent(Double.self, forKey: .notchSpacing) ?? notchSpacing
        style = try values.decodeIfPresent(WidgetStyle.self, forKey: .style) ?? style
    }

    func scale(for display: BarDisplay) -> Double {
        displayScale[display.isBuiltIn ? "builtIn" : "external"] ?? 1
    }
}

struct Configuration: Decodable, Sendable {
    let workspaceSource: WorkspaceSource
    let bar: BarSettings
    let defaults: WidgetStyle
    let widgets: [WidgetConfiguration]
    let popups: [String: PopupConfiguration]
    let environment: [String: String]

    let providers: [String: ProviderConfiguration]
    let groups: [String: WidgetGroupConfiguration]

    enum CodingKeys: String, CodingKey, CaseIterable { case workspaceSource, bar, defaults, widgets, popups, templates, widgetOverrides, environment, providers, groups }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self, allowing: ["$schema", "tokens", "packages"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        workspaceSource = try values.decodeIfPresent(WorkspaceSource.self, forKey: .workspaceSource) ?? .aerospace
        bar = try values.decodeIfPresent(BarSettings.self, forKey: .bar) ?? BarSettings()
        defaults = try values.decodeIfPresent(WidgetStyle.self, forKey: .defaults) ?? WidgetStyle()
        let templates = try values.decodeIfPresent([String: [String: ConfigurationValue]].self, forKey: .templates) ?? [:]
        let overrides = try values.decodeIfPresent([String: [String: ConfigurationValue]].self, forKey: .widgetOverrides) ?? [:]
        for (id, properties) in overrides where properties["id"] != nil {
            throw ConfigurationCompositionError.widgetOverrideID(id)
        }
        let definitions = try values.decode([[String: ConfigurationValue]].self, forKey: .widgets)
        widgets = try definitions.map { definition in
            var expanded = try expandWidgetTemplate(definition, templates: templates)
            if let id = expanded["id"], let properties = overrides[try id.decoded(String.self)] {
                expanded.merge(properties) { $1.overriding($0) }
            }
            do {
                return try JSONDecoder().decode(WidgetConfiguration.self, from: JSONEncoder().encode(expanded))
            } catch {
                throw CommandFailure(message: "widgets.\(expanded["id"].flatMap { try? $0.decoded(String.self) } ?? "?"): \(errorMessage(error))")
            }
        }
        environment = try values.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        popups = try values.decodeIfPresent([String: PopupConfiguration].self, forKey: .popups) ?? [:]
        var providers = try values.decodeIfPresent([String: ProviderConfiguration].self, forKey: .providers) ?? [:]
        for widget in widgets {
            if case let .provider(name) = widget.content, providers[name] == nil {
                guard let type = ProviderType(rawValue: name), type.isNative else { throw CommandFailure(message: "Unknown provider: \(name).") }
                providers[name] = ProviderConfiguration(type: type)
            }
        }
        self.providers = providers
        groups = try values.decodeIfPresent([String: WidgetGroupConfiguration].self, forKey: .groups) ?? [:]
        var groupPositions: [String: WidgetPosition] = [:]
        var ids = Set<String>()
        for widget in widgets {
            let style = widget.style.inheriting(defaults)
            if let min = style.minWidth, min < 0 { throw CommandFailure(message: "minWidth must be nonnegative.") }
            if let max = style.maxWidth, max < 0 { throw CommandFailure(message: "maxWidth must be nonnegative.") }
            if let min = style.minWidth, let max = style.maxWidth, min > max {
                throw CommandFailure(message: "minWidth must not exceed maxWidth.")
            }
            if let group = widget.group {
                guard groups[group] != nil else { throw CommandFailure(message: "Unknown group: \(group).") }
                if let position = groupPositions[group], position != widget.position {
                    throw CommandFailure(message: "Widgets in group \(group) must share a position.")
                }
                groupPositions[group] = widget.position
            }
            if let name = widget.popupName, popups[name] == nil {
                throw DecodingError.dataCorruptedError(forKey: .popups, in: values, debugDescription: "Unknown popup: \(name).")
            }
            guard ids.insert(widget.id).inserted else {
                throw DecodingError.dataCorruptedError(forKey: .widgets, in: values, debugDescription: "Duplicate widget id: \(widget.id). Each widget needs a stable, unique id.")
            }
        }
        for id in overrides.keys where !ids.contains(id) {
            throw ConfigurationCompositionError.unknownWidgetOverride(id)
        }
    }
}
