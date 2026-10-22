import Foundation

/// The states active for one drawn element. Their styles apply over the base style in the order
/// of `names`, later ones winning: data, workspace, mode, mode alias, hover, then open.
struct StyleStates: Equatable, Sendable {
    var data: String?
    var workspace: WorkspaceState?
    var mode = ModePresentation()
    var hover = false
    var open = false

    /// The states StableBar sets itself, which output `state` and rules can't use.
    static let reservedNames: Set<String> = ["hover", "open", "focused", "visible", "empty", "mode"]

    static func isReserved(_ name: String) -> Bool {
        reservedNames.contains(name) || name == "mode" || name.hasPrefix("mode.")
    }

    var names: [String] {
        [data, workspace?.rawValue, mode.active ? "mode" : nil, mode.alias.map { "mode.\($0)" },
         hover ? "hover" : nil, open ? "open" : nil].compactMap { $0 }
    }
}

struct ModePresentation: Equatable, Sendable {
    var active = false
    var alias: String?

    init(mode: String? = nil, aliases: [String: String] = [:]) {
        active = mode.map { !$0.isEmpty && $0 != "main" } ?? false
        alias = active ? mode.flatMap { aliases[$0] } : nil
    }
}

/// A workspace cell's state. A cell has at most one: focused, else visible, else empty.
enum WorkspaceState: String, CaseIterable, Sendable {
    case focused, visible, empty

    init?(_ workspace: Workspace) {
        if workspace.isFocused { self = .focused }
        else if workspace.isVisible { self = .visible }
        else if workspace.apps.isEmpty { self = .empty }
        else { return nil }
    }
}

extension WidgetStyle {
    var usesModeStates: Bool {
        states?.contains { $0.key == "mode" || $0.key.hasPrefix("mode.") || $0.value.usesModeStates } == true
    }

    /// This style with the style of each active state applied over it, in `states.names` order.
    /// A state's style merges with `inheriting`, so its own `states` refine the states after it, and
    /// a state that sets no background keeps the background.
    func resolved(for states: StyleStates) -> WidgetStyle {
        var style = self
        for name in states.names {
            style = (style.states?[name] ?? WidgetStyle()).inheriting(style)
        }
        return style
    }
}

/// The style an element draws: `layers` from lowest to highest precedence, such as the defaults,
/// the configured style and script overrides, merged with `inheriting`, then the active `states`.
func resolveStyle(_ layers: [WidgetStyle], states: StyleStates = StyleStates()) -> WidgetStyle {
    layers.reduce(WidgetStyle()) { $1.inheriting($0) }.resolved(for: states)
}

/// A bar widget's style layers, lowest precedence first: the defaults, its configured style, the
/// `widgetStyles` each widget's output sets for it in configuration order, then its own output's
/// `style` and `color`.
func widgetStyleLayers(_ widget: WidgetConfiguration, defaults: WidgetStyle, widgets: [WidgetConfiguration],
                       output: (String) -> ScriptOutput?) -> [WidgetStyle] {
    widgetStyleLayers(widget, defaults: defaults, overrides: OrderedStyleOverrides(widgets: widgets, output: output),
                      own: output(widget.id))
}

/// Aggregate once per update, retaining configuration order and dropping targets absent from the
/// current outputs. This is deliberately just an ordered fold, not a persistent selector cache.
struct OrderedStyleOverrides {
    var widgets: [String: WidgetStyle] = [:]
    var bar = WidgetStyle()

    init(widgets: [WidgetConfiguration], output: (String) -> ScriptOutput?) {
        for widget in widgets {
            guard let value = output(widget.id) else { continue }
            for (id, style) in value.widgetStyles ?? [:] {
                self.widgets[id] = style.inheriting(self.widgets[id] ?? WidgetStyle())
            }
            if let style = value.barStyle { bar = style.inheriting(bar) }
        }
    }
}

func widgetStyleLayers(_ widget: WidgetConfiguration, defaults: WidgetStyle, overrides: OrderedStyleOverrides,
                       own: ScriptOutput?, role: WidgetStyle = WidgetStyle()) -> [WidgetStyle] {
    [defaults, role, widget.style, overrides.widgets[widget.id] ?? WidgetStyle(), own?.style ?? WidgetStyle(),
     WidgetStyle(foreground: own?.color)]
}

/// The bar's style layers: `bar.style`, then each widget's output `barStyle` in configuration order.
func barStyleLayers(_ style: WidgetStyle, widgets: [WidgetConfiguration], output: (String) -> ScriptOutput?) -> [WidgetStyle] {
    barStyleLayers(style, overrides: OrderedStyleOverrides(widgets: widgets, output: output))
}

func barStyleLayers(_ style: WidgetStyle, overrides: OrderedStyleOverrides) -> [WidgetStyle] {
    [style, overrides.bar]
}

/// A bar widget's style for each combination of its interaction states, resolved once so drawing
/// only picks one.
struct ResolvedWidgetStyle: Equatable, Sendable {
    /// The merged layers, with their `states`, that the widget's layout and overlay blocks inherit.
    let base: WidgetStyle
    /// The data state, from the widget's output or its rules.
    let state: String?
    let mode: ModePresentation
    /// `base` resolved at rest, hovered, open, then open and hovered.
    private let variants: [WidgetStyle]

    init(base: WidgetStyle, state: String? = nil, mode: ModePresentation = ModePresentation()) {
        self.base = base
        self.state = state
        self.mode = mode
        variants = [(false, false), (true, false), (false, true), (true, true)].map {
            base.resolved(for: StyleStates(data: state, mode: mode, hover: $0.0, open: $0.1))
        }
    }

    func style(hovered: Bool, open: Bool = false) -> WidgetStyle { variants[(hovered ? 1 : 0) + (open ? 2 : 0)] }

    /// The states the widget's layout and overlay blocks share; each block adds its own hover.
    func blockStates(open: Bool) -> StyleStates { StyleStates(data: state, mode: mode, open: open) }
}

/// A workspace cell's styles in one workspace state, resolved when the configuration loads.
/// Hover changes the label and app glyphs; the indicators follow the workspace state only.
struct WorkspaceCellStyle: Equatable, Sendable {
    /// The label at rest, and the background indicator's fill, border and corners.
    let resting: WidgetStyle
    let hovered: WidgetStyle
    let underline: WidgetStyle
    let app: WidgetStyle
    let hoveredApp: WidgetStyle

    init(state: WorkspaceState? = nil, cell: WidgetStyle = WidgetStyle(), underline: WidgetStyle = WidgetStyle(),
         app: WidgetStyle = WidgetStyle(), mode: ModePresentation = ModePresentation()) {
        let rest = StyleStates(workspace: state, mode: mode)
        let hover = StyleStates(workspace: state, mode: mode, hover: true)
        resting = cell.resolved(for: rest)
        hovered = cell.resolved(for: hover)
        self.underline = underline.resolved(for: rest)
        self.app = app.resolved(for: rest)
        hoveredApp = app.resolved(for: hover)
    }

    func label(hovered isHovered: Bool) -> WidgetStyle { isHovered ? hovered : resting }
    func glyph(hovered isHovered: Bool) -> WidgetStyle { isHovered ? hoveredApp : app }
}

/// A layout block's styles for one draw.
struct BlockStyle: Equatable, Sendable {
    /// The block's style over the inherited one, without states: what its child blocks inherit.
    let inherited: WidgetStyle
    /// Fonts, colors, accent and spacing, inherited and own, with the active states.
    let text: WidgetStyle
    /// Background, border, padding, size, offset and opacity: the block's own, with the active states.
    let box: WidgetStyle
}

extension PopupBlock {
    var usesModeStates: Bool { usesModeStates(roles: [:]) }

    func usesModeStates(roles: [String: WidgetStyle]) -> Bool {
        if style.usesModeStates || role.flatMap({ roles[$0.rawValue] })?.usesModeStates == true { return true }
        switch content {
        case let .row(children), let .column(children): return children.contains { $0.usesModeStates(roles: roles) }
        case let .list(_, row), let .search(_, _, _, row): return row.usesModeStates(roles: roles)
        default: return false
        }
    }

    /// Resolves this block's styles: its `style`, under the named output style that `styleField`
    /// (read from `fields`) or `styleSource` selects, over `inherited`.
    func resolvedStyle(inherited: WidgetStyle, styles: [String: WidgetStyle], fields: [String: String],
                       states: StyleStates, roles: [String: WidgetStyle] = [:]) -> BlockStyle {
        let name = styleField.flatMap { fields[$0] } ?? styleSource
        let role = role.flatMap { roles[$0.rawValue] } ?? WidgetStyle()
        let output = name.flatMap { styles[$0] } ?? WidgetStyle()
        let own = resolveStyle([role, style, output])
        let merged = resolveStyle([inherited, own])
        // Preserve the legacy cascade for unannotated blocks. Only the new role's box
        // properties are excluded from child inheritance; explicit styles retain their behavior.
        let children = resolveStyle([inherited, role.inheritedByBlocks, style, output])
        return BlockStyle(inherited: children, text: merged.resolved(for: states), box: own.resolved(for: states))
    }
}

extension Configuration {
    var needsModeConnection: Bool {
        subscribedEvents.contains(BuiltInEvent.aerospaceMode.rawValue) || bar.style.usesModeStates
            || defaults.usesModeStates || popupDefaults.usesModeStates
            || popups.values.contains { $0.style.usesModeStates || $0.layout.usesModeStates(roles: roles) }
            || widgets.contains { widget in
                widget.enabled && (widget.style.usesModeStates || roleStyle(widget.role).usesModeStates
                    || widget.layout?.usesModeStates(roles: roles) == true
                    || widget.hoverLayout?.usesModeStates(roles: roles) == true
                    || widget.overlay?.usesModeStates(roles: roles) == true || widget.workspace?.usesModeStates == true
                    || widget.popup.map { $0.style.usesModeStates || $0.layout.usesModeStates(roles: roles) } == true)
            }
    }
}

/// A widget's data state: its output's `state` when that is a non-empty string other than a reserved
/// name, otherwise the state of the first rule that matches the output.
func dataState(_ output: ScriptOutput?, rules: [StyleRule] = []) -> String? {
    guard let output else { return nil }
    if case let .string(name)? = output.state, !name.isEmpty, !StyleStates.isReserved(name) { return name }
    return rules.first { $0.when.matches(output) }?.state
}

/// Sets a widget's data state while its output matches `when`.
struct StyleRule: Decodable, Equatable, Sendable {
    let when: RuleCondition
    let state: String

    enum CodingKeys: String, CodingKey, CaseIterable { case when, state }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        when = try values.decode(RuleCondition.self, forKey: .when)
        state = try values.decode(String.self, forKey: .state)
        guard !state.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .state, in: values,
                                                   debugDescription: "A rule's state must not be empty. Use a data state such as warning.")
        }
        guard !StyleStates.isReserved(state) else {
            throw DecodingError.dataCorruptedError(forKey: .state, in: values,
                                                   debugDescription: "\(state) is set by StableBar. Use a data state such as warning.")
        }
    }
}

/// Compares one entry of a widget's output: a number in `values` at or below `below` and at or
/// above `above`, or a string in `fields` equal to `equals`. A missing entry never matches.
struct RuleCondition: Decodable, Equatable, Sendable {
    let value: String?
    let field: String?
    let below: Double?
    let above: Double?
    let equals: String?

    enum CodingKeys: String, CodingKey, CaseIterable { case value, field, below, above, equals }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        value = try values.decodeIfPresent(String.self, forKey: .value)
        field = try values.decodeIfPresent(String.self, forKey: .field)
        below = try values.decodeIfPresent(Double.self, forKey: .below)
        above = try values.decodeIfPresent(Double.self, forKey: .above)
        equals = try values.decodeIfPresent(String.self, forKey: .equals)
        let comparesValue = value != nil && field == nil && equals == nil && (below != nil || above != nil)
        let comparesField = field != nil && value == nil && below == nil && above == nil && equals != nil
        guard comparesValue || comparesField else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Compare a value with below or above, or a field with equals."))
        }
    }

    func matches(_ output: ScriptOutput) -> Bool {
        if let field { return output.fields?[field] == equals }
        guard let value, let number = output.values?[value] else { return false }
        return (below.map { number <= $0 } ?? true) && (above.map { number >= $0 } ?? true)
    }
}

/// The style a widget's blocks inherit, and the states they apply over it.
struct LayoutStyle: Equatable, Sendable {
    let inherited: WidgetStyle
    let states: StyleStates
    /// Whether each block adds its own hover.
    let tracksHover: Bool
}

extension ResolvedWidgetStyle {
    /// A configured `layout` or `overlay` inherits `base` and applies the widget's data and `open`
    /// states, each block adding its own hover. A default layout inherits the style the widget draws
    /// with, hover and open included, and adds nothing, so it looks exactly like the widget did
    /// before it was drawn through blocks.
    func layoutStyle(configured: Bool, hovered: Bool, open: Bool) -> LayoutStyle {
        configured
            ? LayoutStyle(inherited: base, states: blockStates(open: open), tracksHover: true)
            : LayoutStyle(inherited: style(hovered: hovered, open: open), states: StyleStates(), tracksHover: false)
    }
}
