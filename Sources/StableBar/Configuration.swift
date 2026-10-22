import AppKit
import SwiftUI

struct HexColor: Decodable, Equatable, Sendable {
    let light: UInt32
    let dark: UInt32

    enum CodingKeys: String, CodingKey, CaseIterable { case light, dark }

    init(_ rgba: UInt32) {
        light = rgba
        dark = rgba
    }

    init(light: UInt32, dark: UInt32) {
        self.light = light
        self.dark = dark
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            let rgba = try HexColor.rgba(string, in: container)
            light = rgba
            dark = rgba
        } else {
            try decoder.rejectUnknownKeys(CodingKeys.self)
            let values = try decoder.container(keyedBy: CodingKeys.self)
            light = try HexColor.rgba(values.decode(String.self, forKey: .light), in: container)
            dark = try HexColor.rgba(values.decode(String.self, forKey: .dark), in: container)
        }
    }

    private static func rgba(_ string: String, in container: SingleValueDecodingContainer) throws -> UInt32 {
        let hex = string.dropFirst()
        guard string.hasPrefix("#"), [6, 8].contains(hex.count),
              let value = UInt32(hex, radix: 16) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Use #RRGGBB or #RRGGBBAA for colors.")
        }
        return hex.count == 6 ? (value << 8) | 0xff : value
    }

    var color: Color {
        guard light != dark else { return HexColor.color(light) }
        let light = light, dark = dark
        return Color(nsColor: NSColor(name: nil) { appearance in
            let rgba = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(rgba >> 24) / 255, green: CGFloat((rgba >> 16) & 0xff) / 255,
                           blue: CGFloat((rgba >> 8) & 0xff) / 255, alpha: CGFloat(rgba & 0xff) / 255)
        })
    }

    private static func color(_ rgba: UInt32) -> Color {
        Color(.sRGB, red: Double(rgba >> 24) / 255,
              green: Double((rgba >> 16) & 0xff) / 255,
              blue: Double((rgba >> 8) & 0xff) / 255,
              opacity: Double(rgba & 0xff) / 255)
    }
}

enum BackgroundFill: Decodable, Equatable, Sendable {
    case color(HexColor)
    case gradient(BackgroundGradient)

    enum CodingKeys: String, CodingKey, CaseIterable { case gradient }

    init(from decoder: Decoder) throws {
        if let values = try? decoder.container(keyedBy: CodingKeys.self), values.contains(.gradient) {
            try decoder.rejectUnknownKeys(CodingKeys.self)
            self = .gradient(try values.decode(BackgroundGradient.self, forKey: .gradient))
        } else {
            self = .color(try HexColor(from: decoder))
        }
    }

    var shapeStyle: AnyShapeStyle {
        switch self {
        case let .color(color): AnyShapeStyle(color.color)
        case let .gradient(gradient): AnyShapeStyle(gradient.linearGradient)
        }
    }

    var firstColor: HexColor {
        switch self {
        case let .color(color): color
        case let .gradient(gradient): gradient.colors[0]
        }
    }

    var configurationValue: ConfigurationValue {
        switch self {
        case let .color(color): return color.configurationValue
        case let .gradient(gradient):
            var properties: [String: ConfigurationValue] = ["colors": .array(gradient.colors.map(\.configurationValue)),
                                                            "angle": .number(gradient.angle)]
            properties["locations"] = gradient.locations.map { .array($0.map(ConfigurationValue.number)) }
            return .object(["gradient": .object(properties)])
        }
    }
}

struct BackgroundGradient: Decodable, Equatable, Sendable {
    let colors: [HexColor]
    var angle = 90.0
    var locations: [Double]?

    enum CodingKeys: String, CodingKey, CaseIterable { case colors, angle, locations }

    var points: (start: UnitPoint, end: UnitPoint) {
        let radians = angle * .pi / 180
        let x = sin(radians), y = -cos(radians)
        let half = (abs(x) + abs(y)) / 2
        return (UnitPoint(x: 0.5 - x * half, y: 0.5 - y * half), UnitPoint(x: 0.5 + x * half, y: 0.5 + y * half))
    }

    var linearGradient: LinearGradient {
        let gradient = locations.map { Gradient(stops: zip(colors, $0).map { Gradient.Stop(color: $0.color, location: $1) }) }
            ?? Gradient(colors: colors.map(\.color))
        return LinearGradient(gradient: gradient, startPoint: points.start, endPoint: points.end)
    }
}

extension BackgroundGradient {
    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        colors = try values.decode([HexColor].self, forKey: .colors)
        guard colors.count >= 2 else {
            throw DecodingError.dataCorruptedError(forKey: .colors, in: values, debugDescription: "A gradient needs two or more colors.")
        }
        angle = try values.decodeIfPresent(Double.self, forKey: .angle)
            .map { ($0.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) } ?? angle
        locations = try values.decodeIfPresent([Double].self, forKey: .locations)
        if let locations, locations.count != colors.count || !locations.allSatisfy({ (0...1).contains($0) })
            || zip(locations, locations.dropFirst()).contains(where: { $0 > $1 }) {
            throw DecodingError.dataCorruptedError(forKey: .locations, in: values,
                                                   debugDescription: "Give one location per color, from 0 to 1 in ascending order.")
        }
    }
}

enum BarBorderEdges: String, Decodable, CaseIterable, Sendable {
    case bottom, all
}

enum IndicatorPlacement: String, Decodable, CaseIterable, Sendable {
    case cell, belowBar
}

struct GlassSettings: Decodable, Sendable {
    var enabled = false
    var transparency = 0.3
    var widgets = true
    var popups = true
    var bar = true

    enum CodingKeys: String, CodingKey, CaseIterable { case enabled, transparency, widgets, popups, bar }

    init() {}

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        transparency = try values.decodeIfPresent(Double.self, forKey: .transparency) ?? transparency
        guard (0...1).contains(transparency) else {
            throw DecodingError.dataCorruptedError(forKey: .transparency, in: values, debugDescription: "Use a number from 0 to 1.")
        }
        widgets = try values.decodeIfPresent(Bool.self, forKey: .widgets) ?? widgets
        popups = try values.decodeIfPresent(Bool.self, forKey: .popups) ?? popups
        bar = try values.decodeIfPresent(Bool.self, forKey: .bar) ?? bar
    }
}

struct WidgetStyle: Decodable, Equatable, Sendable {
    var foreground: HexColor?
    var background: BackgroundFill?
    var borderColor: HexColor?
    var accent: HexColor?
    var accentText: HexColor?
    var borderWidth: Double?
    var borderEdges: BarBorderEdges?
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
    /// Only workspace indicatorStyle consumes placement; ordinary style boxes ignore it.
    var placement: IndicatorPlacement?
    /// Styles that apply over this one while a state is active, keyed by state name.
    var states: [String: WidgetStyle]?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case foreground, background, hoverBackground, borderColor, accent, accentText, borderWidth, borderEdges, cornerRadius
        case fontName, fontSize, fontWeight, iconSize, paddingHorizontal, paddingVertical, spacing, width
        case minWidth, maxWidth, shadowRadius, shadowColor, height, paddingLeading, paddingTrailing, paddingTop
        case paddingBottom, offsetX, offsetY, opacity, placement, hoverForeground, states
    }

    var hoverBackground: BackgroundFill? { states?["hover"]?.background }
    var hoverForeground: HexColor? { states?["hover"]?.foreground }

    func inheriting(_ defaults: WidgetStyle) -> WidgetStyle {
        WidgetStyle(
            foreground: foreground ?? defaults.foreground,
            background: background ?? defaults.background,
            borderColor: borderColor ?? defaults.borderColor,
            accent: accent ?? defaults.accent,
            accentText: accentText ?? defaults.accentText,
            borderWidth: borderWidth ?? defaults.borderWidth,
            borderEdges: borderEdges ?? defaults.borderEdges,
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
            placement: placement ?? defaults.placement,
            states: states.map { own in own.merging(defaults.states ?? [:]) { $0.inheriting($1) } } ?? defaults.states
        )
    }

    /// This style with each of `aliases`, such as `focusedStyle`, merged into the state of the same
    /// name. Properties already set in `states` win.
    func addingStates(_ aliases: [String: WidgetStyle]) -> WidgetStyle {
        guard !aliases.isEmpty else { return self }
        var style = self
        style.states = (states ?? [:]).merging(aliases) { own, alias in own.inheriting(alias) }
        return style
    }
}

extension WidgetStyle {
    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        foreground = try values.decodeIfPresent(HexColor.self, forKey: .foreground)
        background = try values.decodeIfPresent(BackgroundFill.self, forKey: .background)
        borderColor = try values.decodeIfPresent(HexColor.self, forKey: .borderColor)
        accent = try values.decodeIfPresent(HexColor.self, forKey: .accent)
        accentText = try values.decodeIfPresent(HexColor.self, forKey: .accentText)
        borderWidth = try values.decodeIfPresent(Double.self, forKey: .borderWidth)
        borderEdges = try values.decodeIfPresent(BarBorderEdges.self, forKey: .borderEdges)
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
        placement = try values.decodeIfPresent(IndicatorPlacement.self, forKey: .placement)
        let hoverForeground = try values.decodeIfPresent(HexColor.self, forKey: .hoverForeground)
        let hoverBackground = try values.decodeIfPresent(BackgroundFill.self, forKey: .hoverBackground)
        let explicit = try values.decodeIfPresent([String: WidgetStyle?].self, forKey: .states)?.compactMapValues { $0 }
        states = explicit?.isEmpty == false ? explicit : nil
        if hoverForeground != nil || hoverBackground != nil {
            self = addingStates(["hover": WidgetStyle(foreground: hoverForeground, background: hoverBackground)])
        }
    }
}

let fontWeights: [(name: String, weight: Font.Weight)] = [
    ("ultralight", .ultraLight), ("thin", .thin), ("light", .light), ("regular", .regular),
    ("medium", .medium), ("semibold", .semibold), ("bold", .bold)
]

struct WidgetAppearance {
    let foreground: Color
    let background: AnyShapeStyle
    let hoverBackground: AnyShapeStyle
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
        foreground = (style.foreground ?? defaults.foreground)?.color ?? .primary
        background = (style.background ?? defaults.background)?.shapeStyle ?? AnyShapeStyle(Color.clear)
        hoverBackground = (style.hoverBackground ?? defaults.hoverBackground)?.shapeStyle ?? background
        borderColor = (style.borderColor ?? defaults.borderColor)?.color ?? .clear
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
        shadowColor = (style.shadowColor ?? defaults.shadowColor)?.color ?? .clear
        let size = style.fontSize ?? defaults.fontSize ?? 13
        let name = style.fontName ?? defaults.fontName ?? "system"
        let weight = fontWeights.first { $0.name == style.fontWeight ?? defaults.fontWeight }?.weight ?? .regular
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
    case appMenu(expandOnHover: Bool)
    case appleMenu
    case clock(format: String)
    case text(String)
    case script(command: String, interval: Double?)
}

struct WidgetConfiguration: Decodable, Identifiable, Sendable {
    let id: String
    let role: PresentationRole?
    var position: WidgetPosition
    let content: WidgetContent
    let icon: String?
    let tooltip: String?
    let onClick: String?
    let open: String?
    let menu: [WidgetMenuItem]?
    let popup: PopupConfiguration?
    let popupName: String?
    let style: WidgetStyle
    let display: DisplaySelection
    let layout: PopupBlock?
    let hoverLayout: PopupBlock?
    let overlay: PopupBlock?
    let animation: WidgetAnimation?
    var workspace: WorkspaceConfiguration?
    let events: [String]
    let environment: [String: String]
    let timeout: Double
    let actions: WidgetActions?
    let enabled: Bool
    let group: String?
    let priority: Int
    let overflow: WidgetOverflow
    let rules: [StyleRule]
    let transition: WidgetTransition?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, role, position, type, icon, tooltip, onClick, open, menu, popup, popupName, style, format, text, command, interval
        case display, layout, hoverLayout, overlay, animation, workspace, events, environment, timeout, actions, enabled, provider, group, priority, overflow, rules, transition
        case expandOnHover
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        role = try values.decodeIfPresent(PresentationRole.self, forKey: .role)
        position = try values.decode(WidgetPosition.self, forKey: .position)
        icon = try values.decodeIfPresent(String.self, forKey: .icon)
        tooltip = try values.decodeIfPresent(String.self, forKey: .tooltip)
        onClick = try values.decodeIfPresent(String.self, forKey: .onClick)
        open = try values.decodeIfPresent(String.self, forKey: .open)
        if let open, OpenTarget(open) == nil {
            throw DecodingError.dataCorruptedError(forKey: .open, in: values, debugDescription: "Use an http, https, mailto or x-apple.systempreferences URL, or an application bundle identifier such as com.apple.iCal.")
        }
        if onClick != nil, open != nil {
            throw DecodingError.dataCorruptedError(forKey: .open, in: values, debugDescription: "A widget cannot set both onClick and open.")
        }
        menu = try values.decodeIfPresent([WidgetMenuItem].self, forKey: .menu)
        popup = try values.decodeIfPresent(PopupConfiguration.self, forKey: .popup)
        popupName = try values.decodeIfPresent(String.self, forKey: .popupName)
        style = try values.decodeIfPresent(WidgetStyle.self, forKey: .style) ?? WidgetStyle()
        display = try values.decodeIfPresent(DisplaySelection.self, forKey: .display) ?? .all
        layout = try values.decodeIfPresent(PopupBlock.self, forKey: .layout)
        hoverLayout = try values.decodeIfPresent(PopupBlock.self, forKey: .hoverLayout)
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
        rules = try values.decodeIfPresent([StyleRule].self, forKey: .rules) ?? []
        transition = try values.decodeIfPresent(WidgetTransition.self, forKey: .transition)
        switch try values.decode(String.self, forKey: .type) {
        case "spacer": content = .spacer
        case "provider": content = .provider(try values.decode(String.self, forKey: .provider))
        case "aerospace", "workspaces": content = .workspaces
        case "activeApp": content = .activeApp
        case "appMenu": content = .appMenu(expandOnHover: try values.decodeIfPresent(Bool.self, forKey: .expandOnHover) ?? false)
        case "appleMenu": content = .appleMenu
        case "clock": content = .clock(format: try values.decodeIfPresent(String.self, forKey: .format) ?? "EEE d MMM  HH:mm")
        case "text": content = .text(try values.decode(String.self, forKey: .text))
        case "script":
            let interval = try values.contains(.interval) ? values.decodeIfPresent(Double.self, forKey: .interval) : 30
            if let interval, interval <= 0 {
                throw DecodingError.dataCorruptedError(forKey: .interval, in: values, debugDescription: "A script interval must be greater than zero.")
            }
            content = .script(command: try values.decode(String.self, forKey: .command), interval: interval)
        case let type:
            guard DataSourceRegistry.builtIn[type]?.isNative == true else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: values, debugDescription: "Unknown widget type.")
            }
            content = .provider(type)
        }
        if !rules.isEmpty {
            switch content {
            case .script, .provider: break
            default:
                throw DecodingError.dataCorruptedError(forKey: .rules, in: values, debugDescription: "Rules need a script or provider widget.")
            }
        }
    }
}

extension WidgetConfiguration {
    /// The provider this widget shows: the one it names, or the native type it is.
    var providerName: String? {
        if case let .provider(name) = content { return name }
        return nil
    }
}

extension Configuration {
    /// The type of the provider `widget` shows, such as `audio` for the Sound widget.
    func providerType(of widget: WidgetConfiguration) -> String? {
        widget.providerName.flatMap { providers[$0]?.type }
    }
}

enum BarAppearance: String, Decodable, Sendable {
    case light, dark

    var colorScheme: ColorScheme { self == .dark ? .dark : .light }
}

struct BarSettings: Decodable, Sendable {
    var height = 40.0
    var displayScale: [String: Double] = [:]
    var offset = 0.0
    var margin = 0.0
    var keepWindowsClear = false
    var keepNotificationsClear = false
    var menuBarRevealDelay = 0.0
    var inset = 12.0
    var spacing = 8.0
    var background = BackgroundFill.color(HexColor(0x00000000))
    var motion = BarMotion.smooth
    var popupTransition: PopupTransition?
    var animationDuration: Double?
    var notchWidth: Double?
    var notchSpacing = 16.0
    var style = WidgetStyle()
    var appearance: BarAppearance?
    var glass = GlassSettings()

    enum CodingKeys: String, CodingKey, CaseIterable {
        case height, displayScale, offset, margin, keepWindowsClear, keepNotificationsClear, menuBarRevealDelay, inset, spacing, background, motion, popupTransition, animationDuration, notchWidth, notchSpacing, style, appearance, glass
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
        margin = try values.decodeIfPresent(Double.self, forKey: .margin) ?? margin
        keepWindowsClear = try values.decodeIfPresent(Bool.self, forKey: .keepWindowsClear) ?? keepWindowsClear
        keepNotificationsClear = try values.decodeIfPresent(Bool.self, forKey: .keepNotificationsClear) ?? keepNotificationsClear
        menuBarRevealDelay = try values.decodeIfPresent(Double.self, forKey: .menuBarRevealDelay) ?? menuBarRevealDelay
        inset = try values.decodeIfPresent(Double.self, forKey: .inset) ?? inset
        spacing = try values.decodeIfPresent(Double.self, forKey: .spacing) ?? spacing
        background = try values.decodeIfPresent(BackgroundFill.self, forKey: .background) ?? background
        motion = try values.decodeIfPresent(BarMotion.self, forKey: .motion) ?? motion
        popupTransition = try values.decodeIfPresent(PopupTransition.self, forKey: .popupTransition)
        animationDuration = try values.decodeIfPresent(Double.self, forKey: .animationDuration)
        notchWidth = try values.decodeIfPresent(Double.self, forKey: .notchWidth)
        notchSpacing = try values.decodeIfPresent(Double.self, forKey: .notchSpacing) ?? notchSpacing
        style = try values.decodeIfPresent(WidgetStyle.self, forKey: .style) ?? style
        appearance = try values.decodeIfPresent(BarAppearance.self, forKey: .appearance)
        glass = try values.decodeIfPresent(GlassSettings.self, forKey: .glass) ?? glass
    }

    func scale(for display: BarDisplay) -> Double {
        displayScale[display.isBuiltIn ? "builtIn" : "external"] ?? 1
    }

    var animation: WidgetAnimation {
        var animation = motion.animation
        animation.duration = animationDuration ?? animation.duration
        return animation
    }
}

struct ScreenConfiguration: Decodable, Sendable {
    static let barKeys: Set<String> = ["height", "offset", "margin", "inset", "spacing", "background", "notchWidth", "notchSpacing", "style",
                                       "glass", "appearance", "motion", "popupTransition"]
    let bar: [String: ConfigurationValue]?
    let layout: [String: [String]]?
    let hasLook: Bool

    enum CodingKeys: String, CodingKey, CaseIterable { case bar, layout, theme, tokens, defaults, popupDefaults, roles, workspaceDefaults, modeAliases }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        bar = try values.decodeIfPresent([String: ConfigurationValue].self, forKey: .bar)
        if let bar, !bar.keys.allSatisfy(Self.barKeys.contains) {
            throw DecodingError.dataCorruptedError(forKey: .bar, in: values,
                debugDescription: "Use \(Self.barKeys.sorted().joined(separator: ", ")).")
        }
        layout = try values.decodeIfPresent([String: [String]].self, forKey: .layout)
        if let layout {
            let ids = layout.values.flatMap { $0 }
            guard layout.keys.allSatisfy({ WidgetPosition(rawValue: $0) != nil }), Set(ids).count == ids.count else {
                throw DecodingError.dataCorruptedError(forKey: .layout, in: values,
                    debugDescription: "List widget IDs once under left, notchLeft, center, notchRight or right.")
            }
        }
        _ = try values.decodeIfPresent(WidgetPackageSelection.self, forKey: .theme)
        hasLook = [.bar, .theme, .tokens, .defaults, .popupDefaults, .roles, .workspaceDefaults, .modeAliases].contains(where: values.contains)
    }
}

struct Configuration: Decodable, Sendable {
    let workspaceSource: WorkspaceSource
    let modeAliases: [String: String]
    let bar: BarSettings
    let defaults: WidgetStyle
    let popupDefaults: WidgetStyle
    let roles: [String: WidgetStyle]
    let workspaceDefaults: WorkspaceDefaults
    private(set) var widgets: [WidgetConfiguration]
    let screenLayouts: [String: [String: [String]]]
    let screensWithOwnLook: [ScreenKind]
    var screenLooks: [String: Configuration] = [:]
    let popups: [String: PopupConfiguration]
    let environment: [String: String]

    let providers: [String: ProviderConfiguration]
    let groups: [String: WidgetGroupConfiguration]
    /// Events that enabled widgets, and the providers they show, subscribe to.
    let subscribedEvents: Set<String>
    /// The providers to run: those enabled widgets show and, for each subscribed event a data
    /// source sends, a provider of that source, unless a provider of another type has its name.
    let activeProviders: Set<String>

    enum CodingKeys: String, CodingKey, CaseIterable { case workspaceSource, modeAliases, bar, defaults, popupDefaults, roles, workspaceDefaults, widgets, screens, popups, templates, widgetOverrides, environment, providers, groups }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self, allowing: ["$schema", "tokens", "packages", "theme"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        workspaceSource = try values.decodeIfPresent(WorkspaceSource.self, forKey: .workspaceSource) ?? .aerospace
        modeAliases = try values.decodeIfPresent([String: String?].self, forKey: .modeAliases)?.compactMapValues { $0 } ?? [:]
        guard modeAliases.allSatisfy({ !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && $0.value.range(of: "^[A-Za-z][A-Za-z0-9_-]*$", options: .regularExpression) != nil }) else {
            throw DecodingError.dataCorruptedError(forKey: .modeAliases, in: values,
                debugDescription: "Map nonempty AeroSpace mode names to aliases starting with a letter and containing only letters, digits, _ or -.")
        }
        bar = try values.decodeIfPresent(BarSettings.self, forKey: .bar) ?? BarSettings()
        defaults = try values.decodeIfPresent(WidgetStyle.self, forKey: .defaults) ?? WidgetStyle()
        popupDefaults = try values.decodeIfPresent(WidgetStyle.self, forKey: .popupDefaults) ?? WidgetStyle()
        let roleDefinitions = try values.decodeIfPresent([String: WidgetStyle?].self, forKey: .roles) ?? [:]
        guard roleDefinitions.keys.allSatisfy({ PresentationRole(rawValue: $0) != nil }) else {
            throw DecodingError.dataCorruptedError(forKey: .roles, in: values,
                debugDescription: "Unknown presentation role. Use \(PresentationRole.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        roles = roleDefinitions.compactMapValues { $0 }
        let workspaceDefaults = try values.decodeIfPresent(WorkspaceDefaults.self, forKey: .workspaceDefaults) ?? WorkspaceDefaults()
        self.workspaceDefaults = workspaceDefaults
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
                var widget = try JSONDecoder().decode(WidgetConfiguration.self, from: JSONEncoder().encode(expanded))
                if widget.content == .workspaces { widget.workspace = try workspaceDefaults.merging(expanded["workspace"]) }
                return widget
            } catch {
                throw CommandFailure(message: "widgets.\(expanded["id"].flatMap { try? $0.decoded(String.self) } ?? "?"): \(errorMessage(error))")
            }
        }
        let screens = try values.decodeIfPresent([String: ScreenConfiguration].self, forKey: .screens) ?? [:]
        guard screens.keys.allSatisfy({ ScreenKind(rawValue: $0) != nil }) else {
            throw DecodingError.dataCorruptedError(forKey: .screens, in: values, debugDescription: "Use laptop, monitor or vertical.")
        }
        screenLayouts = screens.compactMapValues(\.layout)
        screensWithOwnLook = ScreenKind.allCases.filter { screens[$0.rawValue]?.hasLook == true }
        environment = try values.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        popups = try values.decodeIfPresent([String: PopupConfiguration].self, forKey: .popups) ?? [:]
        var providers = try values.decodeIfPresent([String: ProviderConfiguration].self, forKey: .providers) ?? [:]
        for widget in widgets {
            if case let .provider(name) = widget.content, providers[name] == nil {
                guard DataSourceRegistry.builtIn[name]?.isNative == true else { throw CommandFailure(message: "Unknown provider: \(name).") }
                providers[name] = ProviderConfiguration(type: name)
            }
        }
        let shown = Set(widgets.filter(\.enabled).compactMap(\.providerName))
        let subscribed = Set(widgets.filter(\.enabled).flatMap(\.events) + shown.flatMap { providers[$0]?.events ?? [] })
        var active = shown
        for type in DataSourceRegistry.builtIn.types {
            guard type.events.contains(where: { subscribed.contains($0.rawValue) }),
                  !shown.contains(where: { providers[$0]?.type == type.name }),
                  (providers[type.name]?.type ?? type.name) == type.name else { continue }
            providers[type.name] = providers[type.name] ?? ProviderConfiguration(type: type.name)
            active.insert(type.name)
        }
        self.providers = providers
        subscribedEvents = subscribed
        activeProviders = active
        groups = try values.decodeIfPresent([String: WidgetGroupConfiguration].self, forKey: .groups) ?? [:]
        var groupPositions: [String: WidgetPosition] = [:]
        var ids = Set<String>()
        for widget in widgets {
            let style = resolveStyle([defaults, roles[widget.role?.rawValue ?? ""] ?? WidgetStyle(), widget.style])
            let states = (style.states ?? [:]).sorted { $0.key < $1.key }.map { $0.value.inheriting(style) }
            for checked in [style] + states {
                if let min = checked.minWidth, min < 0 { throw CommandFailure(message: "minWidth must be nonnegative.") }
                if let max = checked.maxWidth, max < 0 { throw CommandFailure(message: "maxWidth must be nonnegative.") }
                if let min = checked.minWidth, let max = checked.maxWidth, min > max {
                    throw CommandFailure(message: "minWidth must not exceed maxWidth.")
                }
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

    func look(on kind: ScreenKind) -> Configuration {
        screenLooks[kind.rawValue] ?? self
    }

    func bar(on kind: ScreenKind) -> BarSettings {
        look(on: kind).bar
    }

    func onScreen(_ kind: ScreenKind) -> Configuration {
        var configuration = look(on: kind)
        configuration.widgets = configuration.widgets(on: kind)
        return configuration
    }

    private func widgets(on kind: ScreenKind) -> [WidgetConfiguration] {
        guard let layout = screenLayouts[kind.rawValue] else { return widgets }
        let listed = WidgetPosition.allCases.flatMap { position in
            (layout[position.rawValue] ?? []).compactMap { id in widgets.first { $0.id == id } }.map { widget in
                var widget = widget
                widget.position = position
                return widget
            }
        }
        return listed + widgets.filter { widget in !listed.contains { $0.id == widget.id } }
    }
}
