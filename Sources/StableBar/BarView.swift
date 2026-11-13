import SwiftUI

struct BarView: View {
    static let moreWidgetsID = "StableBar.moreWidgets"
    static let moreWidgetsUnit = BarUnit(id: "widget:\(moreWidgetsID).button", widgets: [try! ConfigurationValue.object([
        "id": .string("\(moreWidgetsID).button"), "position": .string("right"), "type": .string("text"), "text": .string(""),
        "icon": .string("ellipsis"), "tooltip": .string("More widgets")
    ]).decoded(WidgetConfiguration.self)], style: nil)

    /// Whether a widget squeezed to `width` scrolls: any widget narrower than its width at rest, except App menus,
    /// which hide their last menus down to `minimum`, the app name and ».
    static func scrolls(width: CGFloat, resting: CGFloat, minimum: CGFloat?) -> Bool {
        width < (minimum ?? resting) - 0.5
    }

    /// How narrow a unit can get: its width measured with its App menus down to the app name and », which keeps the
    /// widget's own `width` or `minWidth`. Nil when that's no narrower than at rest, so the unit doesn't shrink.
    static func minimumWidth(resting: CGFloat?, narrowest: CGFloat?) -> CGFloat? {
        guard let resting, let narrowest, narrowest < resting - 0.5 else { return nil }
        return narrowest
    }

    static func moreWidgetsID(_ position: WidgetPosition, notched: Bool) -> String {
        notched && [.left, .notchLeft].contains(position) ? "\(moreWidgetsID).left" : moreWidgetsID
    }

    /// The widget the left or right arrow key moves keyboard focus to from `id`, in the order `placements` puts `units`
    /// on the bar, wrapping around at its ends.
    static func focusTarget(from id: String?, moving direction: MoveCommandDirection, units: [BarUnit],
                            placements: [String: BarPlacement]) -> String? {
        let ids = units.filter { !$0.isSpacer && placements[$0.id] != nil }
            .sorted { placements[$0.id]!.x < placements[$1.id]!.x }
            .flatMap { $0.widgets.map(\.id) }
        guard let id, let index = ids.firstIndex(of: id) else { return ids.first }
        return switch direction {
        case .left: ids[(index + ids.count - 1) % ids.count]
        case .right: ids[(index + 1) % ids.count]
        default: id
        }
    }

    let store: BarStore
    let display: BarDisplay
    var nativeDecorations = false
    var preview = false
    /// Only the view in a bar's own panel follows `--focus`, not Settings' or the setup's.
    private var focusesWidgets: Bool { nativeDecorations && store.barPanel(display.id)?.focusesWidgets == true }
    @State private var measuredWidths: [String: CGFloat] = [:]
    @State private var measuredUnits: Set<String> = []
    @State private var restingWidths: [String: CGFloat] = [:]
    /// Each unit with App menus measured with only the app name and », by unit ID.
    @State private var narrowestWidths: [String: CGFloat] = [:]
    @FocusState private var focusedWidget: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .top) {
            if store.barEditing.isActive && !preview {
                BarEditView(store: store, display: display)
                    .transition(.opacity)
            } else if let config = store.configuration?.onScreen(ScreenKind(display)) {
                let scale = CGFloat(config.bar.scale(for: display))
                let barGeometry = config.barGeometry(for: display)
                let notch = config.bar.notch(on: display).map { range in
                    let range: ClosedRange<CGFloat> = ((range.lowerBound - config.bar.margin) / scale)...((range.upperBound - config.bar.margin) / scale)
                    return config.bar.notchWidth.map { width in
                        let center = (range.lowerBound + range.upperBound) / 2
                        return (center - width / 2)...(center + width / 2)
                    } ?? range
                }
                let widgets = store.barEditing.widgets(on: display)
                let units = BarUnit.make(widgets: widgets + [store.update?.widget, store.packageLibrary.updateWidget].compactMap { $0 }, groups: config.groups)
                GeometryReader { geometry in
                    let growth = Dictionary(uniqueKeysWithValues: units.map { unit in
                        (unit.id, max((measuredWidths[unit.id] ?? 0) - (restingWidths[unit.id] ?? 0), 0))
                    })
                    let minimums = Dictionary(uniqueKeysWithValues: units.compactMap { unit in
                        Self.minimumWidth(resting: restingWidths[unit.id], narrowest: narrowestWidths[unit.id]).map { (unit.id, $0) }
                    })
                    let items = units.map { unit in
                        BarLayoutItem(id: unit.id, position: unit.position, width: restingWidths[unit.id] ?? 0, priority: unit.priority,
                                      canOverflow: unit.canOverflow, isSpacer: unit.isSpacer, growth: growth[unit.id]!,
                                      minimumWidth: minimums[unit.id])
                    }
                    let moreWidth = measuredWidths[Self.moreWidgetsUnit.id] ?? 0
                    let plan = AdaptiveBarPlanner(inset: config.bar.inset, spacing: config.bar.spacing,
                                                  notchSpacing: config.bar.notchSpacing, notch: notch, overflowWidth: moreWidth)
                        .plan(width: geometry.size.width / scale, items: items)
                    let visible = Set(units.filter { plan.placements[$0.id] != nil }.flatMap { $0.widgets.map(\.id) })
                    ZStack(alignment: .topLeading) {
                        Color.clear.allowsHitTesting(false)
                        ForEach(units) { unit in
                            if let placement = plan.placements[unit.id] {
                                let alignment: Alignment = switch unit.position {
                                case .left: .leading
                                case .right: .trailing
                                case .notchLeft, .center, .notchRight: .center
                                }
                                unitView(unit, config: config, width: placement.width, minimum: minimums[unit.id])
                                    .environment(\.appMenuShrink, minimums[unit.id] != nil ? max((restingWidths[unit.id] ?? 0) - placement.width, 0) : 0)
                                    .environment(\.barExpansion, plan.cramped.contains(unit.id) ? .cramped : growth[unit.id]! > 0 ? .granted : .collapsed)
                                    .environment(\.barFocus, $focusedWidget)
                                    .environment(\.focusesWidgets, focusesWidgets)
                                    .geometryGroup()
                                    .frame(width: placement.width, height: geometry.size.height / scale, alignment: alignment)
                                    .transformAnchorPreference(key: BarAnchorPreference.self, value: .bounds) { anchors, bounds in
                                        anchors.viewports[unit.id] = bounds
                                    }
                                    .offset(x: placement.x)
                                    .transition(visibilityTransition(unit.transition ?? config.bar.motion.transition, still: reduceMotion))
                            }
                        }
                        ForEach(plan.overflow, id: \.atEnd) { overflow in
                            let overflowUnits = overflow.ids.map { id in units.first { $0.id == id }! }
                            MoreWidgetsButton(units: overflowUnits, config: config, store: store, display: display,
                                              id: Self.moreWidgetsID(overflowUnits[0].position, notched: notch != nil))
                                .frame(width: moreWidth, height: geometry.size.height / scale)
                                .offset(x: overflow.x)
                                .transition(.opacity)
                        }
                    }
                    .animation(reduceMotion ? nil : config.bar.animation.value, value: store.update?.version != nil)
                    .animation(reduceMotion ? nil : config.bar.animation.value, value: plan.overflow.map(\.ids))
                    .onMoveCommand { direction in
                        focusedWidget = Self.focusTarget(from: focusedWidget, moving: direction, units: units, placements: plan.placements)
                    }
                    .onChange(of: focusesWidgets) {
                        focusedWidget = focusesWidgets ? Self.focusTarget(from: nil, moving: .right, units: units, placements: plan.placements) : nil
                    }
                    .overlay {
                        HStack(spacing: 0) {
                            ForEach(units + [Self.moreWidgetsUnit]) { unit in
                                BarUnitView(unit: unit, config: config, store: store, display: display.id)
                                    .fixedSize()
                                    .background {
                                        GeometryReader { proxy in
                                            Color.clear.preference(key: BarWidthPreference.self, value: [unit.id: proxy.size.width])
                                        }
                                    }
                            }
                            // Units with App menus again, down to the app name and », as narrow as they get.
                            ForEach(units.filter(\.hasShrinkingAppMenus)) { unit in
                                BarUnitView(unit: unit, config: config, store: store, display: display.id)
                                    .environment(\.appMenuShrink, .greatestFiniteMagnitude)
                                    .fixedSize()
                                    .background {
                                        GeometryReader { proxy in
                                            Color.clear.preference(key: BarNarrowestWidthPreference.self, value: [unit.id: proxy.size.width])
                                        }
                                    }
                            }
                        }
                        .fixedSize()
                        .hidden()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .modifier(MeasuringCopy())
                        .onPreferenceChange(BarNarrowestWidthPreference.self) { widths in
                            if widths != narrowestWidths { narrowestWidths = widths }
                        }
                    }
                    // Keeps the last width of units that leave, so a returning widget is planned at its size.
                    .onPreferenceChange(BarWidthPreference.self) { widths in
                        let animates = BarUnit.animatesResize(units, measured: measuredUnits, from: measuredWidths, to: widths,
                                                              reduceMotion: reduceMotion, providerType: config.providerType(of:))
                        measuredUnits = Set(widths.keys)
                        let expanded = Set(units.filter { unit in
                            unit.widgets.contains { store.presentations[$0.id]?.expandedDisplays.contains(display.id) == true }
                        }.map(\.id))
                        withAnimation(animates ? config.bar.animation.value : nil) {
                            measuredWidths.merge(widths) { $1 }
                            restingWidths.merge(widths.filter { !expanded.contains($0.key) }) { $1 }
                        }
                    }
                    .onChange(of: visible, initial: true) { _, ids in if !preview { store.setVisibleWidgets(ids: ids, displayID: display.id) } }
                    .frame(width: geometry.size.width / scale, height: geometry.size.height / scale)
                    .scaleEffect(scale, anchor: .topLeading)
                }
                .background(alignment: .topLeading) {
                    if config.bar.fillNotch, !config.bar.belowMenuBar, let notch = config.bar.notch(on: display) {
                        UnevenRoundedRectangle(bottomLeadingRadius: 11, bottomTrailingRadius: 11)
                            .fill(.black)
                            .frame(width: notch.upperBound - notch.lowerBound, height: display.notchHeight)
                            .offset(x: notch.lowerBound - config.bar.margin, y: -config.bar.offset - config.bar.margin)
                            .allowsHitTesting(false)
                    }
                }
                .modifier(BarSurface(store: store, settings: config.bar, kind: ScreenKind(display)))
                .overlay(alignment: .topTrailing) {
                    if let error = store.configurationError {
                        Button { store.onCustomize?() } label: {
                            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.orange)
                        }
                        .buttonStyle(.plain)
                        .help("\(error)\nClick to open Settings.")
                    }
                }
                .padding(config.bar.margin)
                .frame(height: barGeometry.layoutHeight)
                .modifier(BarDecorationLayer(geometry: barGeometry, scale: scale, native: nativeDecorations))
                .frame(height: nativeDecorations ? barGeometry.layoutHeight : barGeometry.panelHeight,
                       alignment: config.bar.position == .top ? .top : .bottom)
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : store.configuration.map { .easeOut(duration: $0.bar(on: ScreenKind(display)).animation.duration) },
                   value: store.barEditing.isActive && !preview)
        .environment(\.colorScheme, store.configuration?.bar(on: ScreenKind(display)).appearance?.colorScheme ?? colorScheme)
        .environment(\.screenKind, ScreenKind(display))
        .focusEffectDisabled(!store.barEditing.isActive)
        .frame(maxHeight: .infinity, alignment: store.configuration?.bar(on: ScreenKind(display)).position == .bottom ? .bottom : .top)
        .allowsHitTesting(!preview)
        .accessibilityHidden(preview)
        .onDisappear { if !preview { store.setVisibleWidgets(ids: [], displayID: display.id) } }
        .contextMenu {
            if !preview {
                BarContextMenu(store: store, display: display.id)
            }
        }
    }

    @ViewBuilder
    private func unitView(_ unit: BarUnit, config: Configuration, width: CGFloat, minimum: CGFloat?) -> some View {
        if Self.scrolls(width: width, resting: restingWidths[unit.id, default: 0], minimum: minimum) {
            ScrollView(.horizontal) {
                BarUnitView(unit: unit, config: config, store: store, display: display.id).fixedSize()
            }
            .scrollIndicators(.hidden)
        } else {
            BarUnitView(unit: unit, config: config, store: store, display: display.id)
        }
    }
}

private struct BarContextMenu: View {
    let store: BarStore
    let display: Int

    var body: some View {
        Group {
            Label { Text("StableBar") } icon: { if let heading = MenuIcon.heading { Image(nsImage: heading) } }
            if store.barEditing.isAvailable { item(store.barEditing.menuTitle, store.barEditing.menuIcon, action: store.barEditing.toggle) }
            item("Try Themes…", .themes) { store.onTryThemes?(display) }
            let error = store.configurationError ?? store.workspaceStore.error ?? store.configurationWarning
            if error != nil || store.crashReports.note != nil { Divider() }
            if let error {
                item(AppDelegate.menuTitle(error: error), .problem) {
                    NSApp.sendAction(#selector(AppDelegate.showStatus), to: NSApp.delegate, from: nil)
                }
            }
            if let note = store.crashReports.note { item(note, .problem) { store.onShowCrashes?() } }
            Divider()
            item("Send Feedback…", .feedback) { NSApp.sendAction(#selector(AppDelegate.showFeedback), to: NSApp.delegate, from: nil) }
            item("Settings…", .settings) { store.onCustomize?() }
            item("Quit StableBar", .quit) { NSApp.terminate(nil) }
        }
        .labelStyle(.titleAndIcon)
    }

    private func item(_ title: String, _ icon: MenuIcon, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label { Text(title) } icon: { icon.menuImage } }
    }
}

private struct MoreWidgetsButton: View {
    let units: [BarUnit]
    let config: Configuration
    let store: BarStore
    let display: BarDisplay
    let id: String
    @State private var anchor = NSView()

    var body: some View {
        Button {
            store.popup.showWidgets(defaults: config.popupDefaults.inheriting(config.defaults), store: store, anchor: anchor) {
                HStack(spacing: config.bar.spacing) {
                    ForEach(units) { BarUnitView(unit: $0, config: config, store: store, display: display.id) }
                }
                .environment(\.moreWidgetsAnchor, anchor)
                .environment(\.screenKind, ScreenKind(display))
            }
        } label: {
            BarUnitView(unit: BarView.moreWidgetsUnit, config: config, store: store, display: display.id)
        }
        .buttonStyle(.plain)
        .background(PopupAnchor(view: anchor, popup: store.popup, id: id))
        .onChange(of: units.map(\.id)) { store.popup.removeAnchor(anchor) }
        .accessibilityLabel("More widgets")
    }
}

private struct BarWidthPreference: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The width of each unit with App menus measured with only the app name and », by unit ID.
private struct BarNarrowestWidthPreference: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct MeasuringBarWidthsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True in the bar's hidden copy that measures widget widths. Nothing moves there: it measures
    /// final widths only.
    var measuringBarWidths: Bool {
        get { self[MeasuringBarWidthsKey.self] }
        set { self[MeasuringBarWidthsKey.self] = newValue }
    }
    @Entry var moreWidgetsAnchor: NSView?
    @Entry var barExpansion: BarExpansion?
    /// The widget with the bar's keyboard focus. Only the bar's own widgets take it, not those in More widgets or Settings.
    @Entry var barFocus: FocusState<String?>.Binding?
    /// Whether the bar has the keyboard from `StableBar --focus`, the only time its widgets can take `barFocus`.
    @Entry var focusesWidgets = false
    /// A date to draw instead of the current time, so a render shows the same clock on every run.
    @Entry var fixedDate: Date?
    /// Draws without the network, as a render does: remote images stay empty.
    @Entry var offline = false
}

enum BarExpansion {
    case collapsed, granted, cramped
}

/// Marks the bar's hidden copy that measures widget widths and keeps it still: nothing animates there.
struct MeasuringCopy: ViewModifier {
    func body(content: Content) -> some View {
        content
            .environment(\.measuringBarWidths, true)
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
    }
}

struct BarUnitView: View {
    let unit: BarUnit
    let config: Configuration
    let store: BarStore
    let display: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.measuringBarWidths) private var measuring

    var body: some View {
        if unit.isSpacer {
            Color.clear.frame(minWidth: unit.widgets[0].style.minWidth ?? 0,
                              idealWidth: unit.widgets[0].style.minWidth ?? 0, maxWidth: .infinity, minHeight: 1)
        } else {
            BarUnitSurface(style: unit.style ?? WidgetStyle(), defaults: config.defaults, spacing: config.bar.spacing) {
                ForEach(unit.widgets) { widget in
                    WidgetView(widget: widget, defaults: config.defaults, popupDefaults: config.popupDefaults, store: store,
                               monitor: display, defaultAnimation: config.bar.animation, defaultTransition: config.bar.motion.transition)
                        .environment(\.barUnitID, unit.id)
                        .transition(visibilityTransition(widget.transition ?? config.bar.motion.transition, still: reduceMotion || measuring))
                }
            }
        }
    }
}

/// The same group spacing and surface wrap normal widgets and their edit decorations.
struct BarUnitSurface<Content: View>: View {
    let style: WidgetStyle
    let defaults: WidgetStyle
    let spacing: Double
    @ViewBuilder let content: () -> Content
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let surface = HStack(spacing: style.spacing ?? spacing, content: content)
            .padding(.leading, style.paddingLeading ?? style.paddingHorizontal ?? 0)
            .padding(.trailing, style.paddingTrailing ?? style.paddingHorizontal ?? 0)
            .padding(.top, style.paddingTop ?? style.paddingVertical ?? 0)
            .padding(.bottom, style.paddingBottom ?? style.paddingVertical ?? 0)
        let fill = style.background?.shapeStyle ?? AnyShapeStyle(Color.clear)
        if let flare = style.flare {
            surface.background(fill, in: FlaredRectangle(cornerRadius: style.cornerRadius ?? 0, flare: flare))
        } else {
            let outlined = contrast == .increased && style.background != nil
            let appearance = WidgetAppearance(WidgetStyle(), defaults: defaults)
            surface
                .background(fill, in: RoundedRectangle(cornerRadius: style.cornerRadius ?? 0))
                .overlay {
                    if outlined {
                        // As in WidgetView, a RoundedRectangle's border would get stray marks at the ends of a pill offscreen.
                        let radius = style.cornerRadius ?? 0
                        UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: radius, bottomTrailingRadius: radius,
                                               topTrailingRadius: radius)
                            .strokeBorder(appearance.foreground, lineWidth: max(style.borderWidth ?? 1, 1))
                    } else {
                        RoundedRectangle(cornerRadius: style.cornerRadius ?? 0)
                            .strokeBorder(style.borderColor?.color ?? .clear, lineWidth: style.borderWidth ?? 0)
                    }
                }
        }
    }
}

struct FlaredRectangle: Shape {
    let cornerRadius: Double
    let flare: Double

    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX - flare, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX + flare, y: rect.minY))
            path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: flare)
            path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: cornerRadius)
            path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: cornerRadius)
            path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX - flare, y: rect.minY), radius: flare)
            path.closeSubpath()
        }
    }
}

@MainActor
func widgetPopup(_ widget: WidgetConfiguration, store: BarStore) -> PopupConfiguration? {
    if widget.id == AppUpdate.widgetID { return AppUpdate.popup }
    if let popup = widget.popup { return popup }
    if let name = widget.popupName { return store.configuration?.popups[name] }
    if let menu = store.scripts[widget.id]?.output.menu ?? widget.menu, !menu.isEmpty {
        return PopupConfiguration(
            style: WidgetStyle(fontSize: 12, paddingHorizontal: 12, paddingVertical: 12, spacing: 4),
            layout: PopupBlock(content: .menu)
        )
    }
    if widget.details, widget.onClick == nil, widget.open == nil, store.scripts[widget.id]?.output.onClick == nil,
       let kind = EssentialsPopup.kind(for: widget, providerType: store.configuration?.providerType(of: widget)) {
        return kind.popup(timeZone: widget.timeZone)
    }
    return nil
}

/// A clock's refresh schedule: each second when its format shows seconds, otherwise each minute.
private func clockSchedule(_ format: String) -> PeriodicTimelineSchedule {
    .periodic(from: Calendar.current.startOfDay(for: .now), by: format.contains("s") ? 1 : 60)
}

struct WidgetView: View {
    let widget: WidgetConfiguration
    let defaults: WidgetStyle
    let popupDefaults: WidgetStyle
    let store: BarStore
    let monitor: Int
    let defaultAnimation: WidgetAnimation
    let defaultTransition: WidgetTransition
    @State private var hovered = false
    @State private var popupAnchor = NSView()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.measuringBarWidths) private var measuring
    @Environment(\.barUnitID) private var unitID
    @Environment(\.screenKind) private var screenKind
    @Environment(\.moreWidgetsAnchor) private var moreWidgetsAnchor
    @Environment(\.barExpansion) private var barExpansion
    @Environment(\.fixedDate) private var fixedDate
    @Environment(\.barFocus) private var barFocus
    @Environment(\.focusesWidgets) private var focusesWidgets

    private var resolution: ResolvedWidgetStyle {
        store.presentations[widget.id]?.style(on: screenKind) ?? ResolvedWidgetStyle(base: resolveStyle([defaults, widget.barStyle]))
    }

    private var clickAnchor: NSView { moreWidgetsAnchor ?? popupAnchor }

    /// Whether the widget's own command, link, popup or menu takes its click, before a built-in click such as the Apple logo's.
    /// A menu counts even when empty, as in Settings.
    private var hasOwnClick: Bool {
        let output = store.scripts[widget.id]?.output
        return widgetPopup(widget, store: store) != nil || (output?.onClick ?? widget.onClick) != nil || widget.open != nil
            || (output?.menu ?? widget.menu) != nil
    }

    private var inlineHoverControls: Bool { store.configuration?.bar.inlineHoverControls == true }

    private var isSound: Bool { widget.layout == nil && store.configuration?.providerType(of: widget) == DataSourceType.audio.name }

    /// `tile` as a button for its click action, popup or link, or as it is while the bar is being
    /// edited, when it takes no clicks. `isOpen` tells whether the popup it opens is open.
    @ViewBuilder private func clickable(_ tile: some View, output: ScriptOutput?, isOpen: Bool) -> some View {
        if store.barEditing.isActive {
            tile
        } else if widget.id == PackageLibrary.updateWidgetID {
            let buttons = HStack(spacing: 0) {
                Button(action: store.packageLibrary.openUpdates) { tile }
                    .accessibilityLabel("Open package updates")
                Button(action: store.packageLibrary.dismissUpdates) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                        .padding(6)
                }
                .accessibilityLabel("Dismiss package update notification")
                .help("Dismiss package update notification")
            }
            .buttonStyle(.plain)
            pressable(buttons, click: store.packageLibrary.openUpdates)
        } else if widget.hoverLayout != nil, let command = output?.onClick ?? widget.onClick {
            let click = { runAction(command, sender: "mouse.clicked", button: "left") }
            pressable(Button(action: click) { tile }.buttonStyle(.plain), click: click)
        } else if let popup = widgetPopup(widget, store: store) {
            let click = {
                guard store.barEditing.allowsWidgetActions else { return }
                store.popup.toggle(popup, widget: widget, defaults: popupDefaults.inheriting(defaults), store: store, anchor: clickAnchor)
            }
            pressable(Button(action: click) { tile }.buttonStyle(.plain), click: click, popupOpen: isOpen)
        } else if let command = output?.onClick ?? widget.onClick {
            let click = { runAction(command, sender: "mouse.clicked", button: "left") }
            pressable(Button(action: click) { tile }.buttonStyle(.plain), click: click)
        } else if let open = widget.open {
            let click = { if store.barEditing.allowsWidgetActions { OpenTarget(open)!.open() } }
            pressable(Button(action: click) { tile }.buttonStyle(.plain), click: click)
        } else if store.configuration?.providerType(of: widget) == DataSourceType.inputSource.name, !hasOwnClick {
            let click = { if store.barEditing.allowsWidgetActions { store.selectInputSource(nil, widget: widget) } }
            pressable(Button(action: click) { tile }.buttonStyle(.plain), click: click)
        } else if case let .appleMenu(appleClick) = widget.content, widget.layout != nil, !hasOwnClick {
            let click = { clickAppleLogo(appleClick, anchor: clickAnchor) }
            let button = Button(action: click) { tile }
                .buttonStyle(.plain)
                .onHover { if $0, appleClick == .menu { store.appMenu.refresh() } }
            pressable(button, click: click, popupOpen: appleClick == .menu ? isOpen : nil)
        } else if widget.content == .controlCenter {
            let click = { if store.barEditing.allowsWidgetActions { store.appMenu.openControlCenter() } }
            pressable(Button(action: click) { tile }.buttonStyle(MouseDownButtonStyle()), click: click)
        } else if widget.content == .stableBar, !hasOwnClick {
            let click = { if store.barEditing.allowsWidgetActions { store.onCustomize?() } }
            pressable(Button(action: click) { tile }.buttonStyle(.plain), click: click)
        } else if case let .menuBarItems(_, _, hidden) = widget.content, !widget.drawsMenuBarItems {
            let click = { toggleMenuBarItems(leavingOut: hidden.references, anchor: clickAnchor) }
            pressable(Button(action: click) { tile }.buttonStyle(.plain), click: click, popupOpen: isOpen)
        } else {
            pressable(tile)
        }
    }

    /// `view`, the widget's tile or button, as the keyboard and VoiceOver press it. While the bar has keyboard focus, the
    /// arrow keys reach it and Return or Space does `click`. A click that opens a popup reads as a button that expands,
    /// with `popupOpen` as its state, which SwiftUI can't report.
    @ViewBuilder private func pressable(_ view: some View, click: (() -> Void)? = nil, popupOpen: Bool? = nil) -> some View {
        let element = Group {
            if let click, let popupOpen {
                view.accessibilityRepresentation {
                    PopupButtonAccessibility(label: accessibilityName, value: { accessibilityValue(date: .now) },
                                             expanded: popupOpen, press: click)
                }
            } else {
                view
            }
        }
        if let barFocus {
            element
                .focusable(focusesWidgets)
                .focused(barFocus, equals: widget.id)
                .onKeyPress(keys: [.return, .space]) { _ in
                    guard let click else { return .ignored }
                    click()
                    return .handled
                }
        } else {
            element
        }
    }

    /// What VoiceOver calls the widget: its name in Settings, or the offer of the update widget.
    private var accessibilityName: String {
        widget.id == AppUpdate.widgetID ? widget.tooltip!
            : WidgetDisplayName.name(for: widget, packageName: store.widgetPackageNames[widget.id], providers: store.configuration?.providers ?? [:])
    }

    /// What VoiceOver reads after the widget's name: the text it shows at `date`, or the latest value of a graph shown
    /// without text.
    private func accessibilityValue(date: Date) -> String {
        let text = store.label(for: widget, date: date).overlaid(by: store.presentations[widget.id]?.temporaryFields).text
        guard text.isEmpty, let value = store.scripts[widget.id]?.output.value else { return text }
        return value.formatted(.percent.precision(.fractionLength(0)))
    }

    /// Opens the widget's hover popup, hover controls or tooltip when the pointer enters it, closes
    /// them when it leaves, and runs the widget's mouse actions.
    private func hoverChanged(_ inside: Bool, tooltip: String?, output: ScriptOutput?) {
        guard store.barEditing.allowsWidgetActions else { return }
        hovered = inside
        if !inside {
            store.popup.hover(false, store: store, anchor: popupAnchor) {}
        } else if let popup = widgetPopup(widget, store: store), popup.openOnHover {
            store.popup.hover(inside, store: store, anchor: popupAnchor) {
                store.popup.open(popup, widget: widget, defaults: popupDefaults.inheriting(defaults),
                                 store: store, anchor: popupAnchor, onHover: true)
            }
        } else if case let .menuBarItems(openOnHover: true, _, hidden) = widget.content, !widget.drawsMenuBarItems,
                  widgetPopup(widget, store: store) == nil, widget.onClick == nil, widget.open == nil {
            hoverMenuBarItems(inside, leavingOut: hidden.references, anchor: popupAnchor)
        } else if !inlineHoverControls, widget.hoverLayout != nil || (isSound && output?.values?["volume"] != nil) {
            store.popup.hover(inside, store: store, anchor: popupAnchor) {
                store.popup.showControls(widget: widget, defaults: popupDefaults.inheriting(defaults), store: store,
                                         anchor: popupAnchor) { style in hoverControls(style) }
            }
        } else if widget.hoverLayout == nil, let tooltip, !tooltip.isEmpty {
            store.popup.hover(inside, store: store, anchor: popupAnchor) {
                store.popup.showTooltip(tooltip, widget: widget, defaults: popupDefaults.inheriting(defaults),
                                        store: store, anchor: popupAnchor)
            }
        }
        if let command = inside ? widget.actions?.mouseEntered : widget.actions?.mouseExited {
            runAction(command, sender: inside ? "mouse.entered" : "mouse.exited")
        }
    }

    /// How the widget's text, field and symbol blocks show changes.
    private var motion: BlockMotion {
        BlockMotion(transition: widget.transition ?? defaultTransition,
                    animation: store.scripts[widget.id]?.output.animation ?? widget.animation ?? defaultAnimation)
    }

    var body: some View {
        let output = store.scripts[widget.id]?.output
        let tooltip = store.scripts[widget.id]?.error ?? widget.tooltip ?? output?.tooltip
        let resolution = self.resolution
        let isOpen = store.presentations[widget.id]?.popupAnchor == ObjectIdentifier(popupAnchor)
        let style = resolution.style(hovered: hovered || barFocus?.wrappedValue == widget.id, open: isOpen)
        let appearance = WidgetAppearance(style, defaults: WidgetStyle())
        let animation = output?.animation ?? widget.animation ?? defaultAnimation
        let leading = style.paddingLeading ?? appearance.paddingHorizontal
        let trailing = style.paddingTrailing ?? appearance.paddingHorizontal
        // The Apple logo's button takes the side padding too, so the whole tile takes its click.
        let isAppleLogo = if case .appleMenu = widget.content { widget.layout == nil } else { false }
        let padding = EdgeInsets(top: style.paddingTop ?? appearance.paddingVertical, leading: isAppleLogo ? leading : 0,
                                 bottom: style.paddingBottom ?? appearance.paddingVertical, trailing: isAppleLogo ? trailing : 0)
        // Workspace and menu buttons include vertical padding so their selection fills the tile.
        let hasCells = switch widget.content {
        case .workspaces, .appMenu, .appleMenu: widget.layout == nil
        case .menuBarItems: widget.drawsMenuBarItems
        default: false
        }
        let tile = Group {
            if let layout = widget.hoverLayout, inlineHoverControls {
                HoverLayoutView(widget: widget, layout: layout, store: store, monitor: monitor,
                                style: resolution.layoutStyle(configured: true, hovered: hovered, open: isOpen),
                                hovered: hovered, motion: motion, runAction: blockAction) {
                    content(resolution, open: isOpen, padding: padding)
                }
            } else {
                content(resolution, open: isOpen, padding: padding)
            }
        }
            .overlay(alignment: .topTrailing) {
                if widget.id == AppUpdate.widgetID {
                    Circle()
                        .fill(appearance.accent)
                        .frame(width: appearance.iconSize / 2, height: appearance.iconSize / 2)
                        .overlay { Circle().strokeBorder(appearance.background, lineWidth: 1.5) }
                        .offset(x: 2, y: -2)
                        .accessibilityHidden(true)
                }
            }
            .padding(.leading, isAppleLogo ? 0 : leading)
            .padding(.trailing, isAppleLogo ? 0 : trailing)
            .padding(.top, hasCells ? 0 : padding.top)
            .padding(.bottom, hasCells ? 0 : padding.bottom)
            .frame(width: appearance.width, height: style.height.map { CGFloat($0) })
            .frame(minWidth: style.minWidth.map { CGFloat($0) }, maxWidth: style.maxWidth.map { CGFloat($0) })
            .contentShape(Rectangle())
        clickable(tile, output: output, isOpen: isOpen)
        .font(appearance.font)
        .foregroundStyle(appearance.foreground)
        .modifier(GlassBackground(fill: style.background, glass: store.configuration?.bar(on: screenKind).glass ?? GlassSettings(), surface: \.widgets,
                                  shape: RoundedRectangle(cornerRadius: appearance.cornerRadius)))
        .overlay {
            if contrast == .increased && style.background != nil {
                // SwiftUI draws a RoundedRectangle's border as a layer border, which drawing offscreen, as the scenes do, gives
                // stray marks at the ends of a pill.
                let radius = appearance.cornerRadius
                UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: radius, bottomTrailingRadius: radius, topTrailingRadius: radius)
                    .strokeBorder(appearance.foreground, lineWidth: max(appearance.borderWidth, 1))
            } else {
                RoundedRectangle(cornerRadius: appearance.cornerRadius)
                    .strokeBorder(appearance.borderColor, lineWidth: appearance.borderWidth)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let error = store.scripts[widget.id]?.error ?? store.actionErrors[widget.id] {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).font(.system(size: 8)).help(error)
            }
        }
        .shadow(color: appearance.shadowColor, radius: appearance.shadowRadius, y: 1)
        .overlay(alignment: .bottom) {
            if let overlay = widget.overlay {
                timed { date in
                    WidgetBlocks(widget: widget, store: store, style: resolution.layoutStyle(configured: true, hovered: hovered, open: isOpen),
                                 block: overlay, date: date, fillsWidth: true, motion: motion, runAction: blockAction)
                }
                .allowsHitTesting(false)
            }
        }
        .overlay {
            if store.barEditing.allowsWidgetActions, let actions = widget.actions {
                WidgetActionCapture(actions: actions, display: monitor) { command, context in
                    store.runAction(command, widget: widget,
                                    event: ScriptEvent(sender: context.sender, environment: context.environment))
                }
            }
        }
        .background {
            if !measuring && store.barEditing.allowsWidgetActions { PopupAnchor(view: popupAnchor, popup: store.popup, id: widget.id) }
        }
        .transformAnchorPreference(key: BarAnchorPreference.self, value: .bounds) { anchors, bounds in
            if !measuring { anchors.widgets[widget.id] = BarWidgetAnchor(bounds: bounds, unit: unitID) }
        }
        .offset(x: style.offsetX ?? 0, y: style.offsetY ?? 0)
        .opacity(style.opacity ?? 1)
        .onHover { hoverChanged($0, tooltip: tooltip, output: output) }
        .animation(hoverAnimation(hovered, reduceMotion: reduceMotion), value: hovered)
        .animation(reduceMotion ? nil : animation.value, value: style)
        .animation(reduceMotion ? nil : animation.value, value: widget.content == .activeApp ? store.activeApp : nil)
        .accessibilityHint(tooltip ?? "")
        .accessibilityIdentifier(widget.id)
        .contextMenu {
            if store.barEditing.allowsWidgetActions, widget.actions?.rightClick == nil,
               store.configuration?.widgets.contains(where: { $0.id == widget.id }) == true {
                Button("Edit Widget…") { store.onCustomizeWidget?(widget.id) }
                Divider()
                BarContextMenu(store: store, display: monitor)
            }
        }
    }

    private func showMenuRow(appearance: WidgetAppearance, padding: EdgeInsets) {
        store.popup.hover(true, store: store, anchor: popupAnchor) {
            store.popup.showRow(widget: widget, defaults: popupDefaults.inheriting(defaults), store: store, anchor: popupAnchor) {
                AppMenuRow(widget: widget, store: store, defaults: popupDefaults.inheriting(defaults), appearance: appearance, padding: padding)
            }
        }
    }

    private func toggleMenuBarItems(leavingOut references: [MenuBarItemReference], anchor: NSView) {
        guard store.barEditing.allowsWidgetActions, !store.popup.toggleIfOpen(widget.id, anchor: anchor) else { return }
        Task {
            guard let popup = await store.appMenu.menuBarItemsPopup(leavingOut: references) else { return }
            store.popup.toggle(popup, widget: widget, defaults: popupDefaults.inheriting(defaults), store: store, anchor: anchor)
        }
    }

    private func hoverMenuBarItems(_ inside: Bool, leavingOut references: [MenuBarItemReference], anchor: NSView) {
        store.popup.hover(inside, store: store, anchor: anchor) {
            guard let popup = await store.appMenu.menuBarItemsPopup(leavingOut: references, requestingAccess: false), !Task.isCancelled else { return }
            store.popup.open(popup, widget: widget, defaults: popupDefaults.inheriting(defaults),
                             store: store, anchor: anchor, onHover: true)
        }
    }

    /// The menus that don't fit beside the notch, each opening its own menu.
    private func openAppMenus(_ items: [AppMenuItem], anchor: NSView) {
        guard store.barEditing.allowsWidgetActions, let popup = store.appMenu.overflowPopup(for: items) else { return }
        store.popup.toggle(popup, widget: widget, defaults: popupDefaults.inheriting(defaults), store: store, anchor: moreWidgetsAnchor ?? anchor)
    }

    private func openAppMenu(_ item: AppMenuItem, anchor: NSView) {
        guard let popup = store.appMenu.popup(for: item) else { return }
        store.popup.toggle(popup, widget: widget, defaults: popupDefaults.inheriting(defaults), store: store, anchor: moreWidgetsAnchor ?? anchor)
    }

    /// Runs the Apple logo's click. Without Accessibility access, a menu click asks for it; with access but no menu read
    /// yet, such as just after access was allowed, it reads the menus so the next click opens it.
    private func clickAppleLogo(_ click: AppleMenuClick, anchor: NSView) {
        guard store.barEditing.allowsWidgetActions else { return }
        switch click {
        case .menu:
            if !AXIsProcessTrusted() { store.windowClearance.requestAccess() }
            else if store.appMenu.isTrusted, let item = store.appMenu.appleMenu { openAppMenu(item, anchor: anchor) }
            else { store.appMenu.refresh() }
        case .systemSettings: OpenTarget("com.apple.systempreferences")!.open()
        case .lockScreen:
            let error = lockScreen()
            if store.actionErrors[widget.id] != error { store.actionErrors[widget.id] = error }
        }
    }

    private func runAction(_ command: String, sender: String, button: String? = nil) {
        let context = WidgetActionContext(sender: sender, button: button, modifiers: NSEvent.modifierFlags, display: monitor)
        store.runAction(command, widget: widget, event: ScriptEvent(sender: sender, environment: context.environment))
    }

    @ViewBuilder
    private func content(_ resolution: ResolvedWidgetStyle, open: Bool, padding: EdgeInsets) -> some View {
        switch widget.content {
        case .workspaces where widget.layout == nil:
            WorkspaceView(workspaceStore: store.workspaceStore, monitor: monitor,
                          appearance: WidgetAppearance(resolution.style(hovered: false, open: open), defaults: WidgetStyle()),
                          padding: padding, configuration: widget.workspace, animation: widget.animation ?? defaultAnimation,
                          defaults: resolution.base,
                          modeAliases: store.configuration?.look(on: screenKind).modeAliases ?? [:], widgetID: widget.id,
                          allowsWindowDragging: store.barEditing.allowsWidgetActions) { inside, name, anchor in
                store.popup.hover(inside, store: store, anchor: anchor) {
                    store.popup.showTooltip(name, widget: widget, defaults: popupDefaults.inheriting(defaults), store: store, anchor: anchor)
                }
            }
        case let .appMenu(expandOnHover) where widget.layout == nil:
            let expands = expandOnHover && moreWidgetsAnchor == nil
            let appearance = WidgetAppearance(resolution.style(hovered: false, open: open), defaults: WidgetStyle())
            AppMenuView(appMenu: store.appMenu, items: store.appMenu.items, expandOnHover: expands, hovering: hovered,
                        expanded: barExpansion.map { $0 == .granted } ?? (store.presentations[widget.id]?.expandedDisplays.contains(monitor) == true),
                        appearance: appearance, padding: padding, openAnchor: store.presentations[widget.id]?.popupAnchor, open: openAppMenu,
                        requestAccess: store.windowClearance.requestAccess, expansionChanged: { expanded in
                if !measuring && expands {
                    store.presentations[widget.id]?.setExpanded(expanded, on: monitor, animation: reduceMotion ? nil : motion.animation)
                }
            }, openOverflow: openAppMenus)
            .onChange(of: barExpansion == .cramped && hovered) { _, cramped in
                if cramped { showMenuRow(appearance: appearance, padding: padding) }
            }
        case let .appleMenu(click) where widget.layout == nil:
            let appearance = WidgetAppearance(resolution.style(hovered: false, open: open), defaults: WidgetStyle())
            if hasOwnClick {
                Image(systemName: "apple.logo").accessibilityLabel("Apple")
                    .foregroundStyle(appearance.foreground)
                    .padding(padding)
            } else if click == .menu, store.appMenu.isTrusted, let appleMenu = store.appMenu.appleMenu {
                AppMenuView(appMenu: store.appMenu, items: [appleMenu], isAppleMenu: true,
                            appearance: appearance, padding: padding, openAnchor: store.presentations[widget.id]?.popupAnchor,
                            open: openAppMenu, requestAccess: store.windowClearance.requestAccess)
            } else {
                AppleLogoButton(appearance: appearance, padding: padding, label: click.title,
                                help: click == .menu && !store.appMenu.isTrusted ? "Allow StableBar in Privacy & Security → Accessibility to open the Apple menu. Click to open System Settings and drag StableBar into the list." : nil) {
                    clickAppleLogo(click, anchor: clickAnchor)
                } hover: {
                    if click == .menu { store.appMenu.refresh() }
                }
            }
        case .stableBar where widget.layout == nil:
            if let image = NSImage(named: "StatusBarIconTemplate") {
                let appearance = WidgetAppearance(resolution.style(hovered: hovered || barFocus?.wrappedValue == widget.id, open: open),
                                                  defaults: WidgetStyle())
                ZStack {
                    Text(" ").hidden()
                    Image(nsImage: image).resizable().scaledToFit().frame(height: appearance.iconSize)
                        .accessibilityLabel(accessibilityName)
                        .foregroundStyle(appearance.foreground)
                }
            }
        case let .menuBarItems(openOnHover, _, hidden) where widget.drawsMenuBarItems:
            let leftOut = widget.shownMenuBarItems.references + hidden.references
            MenuBarItemsView(widget: widget, store: store, defaults: popupDefaults.inheriting(defaults),
                             appearance: WidgetAppearance(resolution.style(hovered: false, open: open), defaults: WidgetStyle()),
                             padding: padding, symbol: store.label(for: widget).icon!) { anchor in
                toggleMenuBarItems(leavingOut: leftOut, anchor: anchor)
            } hoverRow: { inside, anchor in
                if openOnHover { hoverMenuBarItems(inside, leavingOut: leftOut, anchor: anchor) }
            }
        case .provider where isSound && inlineHoverControls:
            SoundWidgetView(widget: widget, store: store, monitor: monitor,
                            style: resolution.layoutStyle(configured: false, hovered: hovered, open: open),
                            hovered: hovered, motion: motion, runAction: blockAction)
        case .spacer where widget.layout == nil:
            Spacer(minLength: resolution.base.minWidth ?? 0)
        default:
            if store.scripts[widget.id]?.error != nil && !store.barEditing.hasContent(widget) {
                Image(systemName: store.label(for: widget).icon ?? "exclamationmark.triangle")
                    .font(.system(size: WidgetAppearance(resolution.style(hovered: false, open: open), defaults: WidgetStyle()).iconSize))
            } else {
                timed { date in blocks(resolution, open: open, date: date) }
            }
        }
    }

    /// `content` drawn for the time the widget shows: the render's fixed date when it has one, a clock's
    /// redrawn on its schedule, otherwise now.
    @ViewBuilder
    private func timed<Content: View>(@ViewBuilder _ content: @escaping (Date) -> Content) -> some View {
        if let fixedDate {
            content(fixedDate)
        } else if case let .clock(format) = widget.content {
            TimelineView(clockSchedule(format)) { context in content(context.date) }
        } else {
            content(.now)
        }
    }

    private func hoverControls(_ style: WidgetStyle) -> some View {
        Group {
            if let layout = widget.hoverLayout {
                WidgetBlocks(widget: widget, store: store,
                             style: LayoutStyle(inherited: style, states: resolution.blockStates(open: false), tracksHover: true),
                             block: layout, motion: motion, runAction: blockAction)
            } else {
                VolumeSlider(widget: widget, store: store, appearance: WidgetAppearance(style, defaults: WidgetStyle()), width: 120)
            }
        }
        .controlSize(.small)
        .labelsHidden()
    }

    private func blocks(_ resolution: ResolvedWidgetStyle, open: Bool, date: Date) -> some View {
        WidgetBlocks(widget: widget, store: store,
                     style: resolution.layoutStyle(configured: widget.layout != nil, hovered: hovered, open: open),
                     date: date, motion: motion, runAction: blockAction)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityName)
            .accessibilityValue(accessibilityValue(date: date))
    }

    private func blockAction(_ command: String, _ environment: [String: String]) {
        if environment.isEmpty {
            runAction(command, sender: "mouse.clicked", button: "left")
        } else {
            store.runAction(command, widget: widget,
                            event: ScriptEvent(sender: "control.changed", environment: environment.merging(["SID": String(monitor)]) { first, _ in first }))
        }
    }
}

/// One of a widget's block trees drawn with its data: `block` when given, such as its overlay,
/// otherwise its `layout`, otherwise the default layout of its type.
struct WidgetBlocks: View {
    let widget: WidgetConfiguration
    let store: BarStore
    let style: LayoutStyle
    var block: PopupBlock?
    var date = Date.now
    var fillsWidth = false
    var motion = BlockMotion()
    let runAction: (String, [String: String]) -> Void
    @Environment(\.screenKind) private var screenKind

    var body: some View {
        let script = store.scripts[widget.id]
        let label = store.label(for: widget, date: date).overlaid(by: store.presentations[widget.id]?.temporaryFields)
        let appIcon = widget.content == .activeApp ? store.activeApp?.icon : nil
        let providerType = store.configuration?.providerType(of: widget)
        if let layout = block ?? widget.layout ?? widget.defaultLayout(label, output: script?.output, appIcon: appIcon != nil, providerType: providerType) {
            PopupBlockView(block: layout, inheritedStyle: style.inherited, fields: label.fields,
                           context: BlockContext(lists: script?.output.lists ?? [:], samples: script?.samples ?? [],
                                                 menu: script?.output.menu ?? widget.menu ?? [], values: script?.output.values ?? [:],
                                                 targets: script?.output.targets ?? [:], styles: script?.output.styles ?? [:],
                                                 series: script?.output.series ?? [:], roles: store.configuration?.look(on: screenKind).roles ?? [:],
                                                 fillsWidth: fillsWidth, open: { if store.barEditing.allowsWidgetActions { $0.open() } },
                                                 quit: { if store.barEditing.allowsWidgetActions { confirmQuit($0) } },
                                                 pressMenuBarItem: { if store.barEditing.allowsWidgetActions { store.appMenu.press($0) } },
                                                 selectInputSource: { if store.barEditing.allowsWidgetActions { store.selectInputSource($0, widget: widget) } },
                                                 states: style.states, tracksHover: style.tracksHover, appIcon: appIcon, motion: motion,
                                                 runAction: runAction))
        }
    }
}

struct Sparkline: Shape {
    let samples: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for (index, value) in samples.enumerated() {
            let point = CGPoint(x: rect.width * Double(60 - samples.count + index) / 59,
                                y: rect.height * (1 - min(max(value, 0), 1)))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

struct WorkspaceView: View {
    let workspaceStore: WorkspaceStore
    let monitor: Int
    let appearance: WidgetAppearance
    var padding = EdgeInsets()
    var configuration: WorkspaceConfiguration?
    let animation: WidgetAnimation
    var defaults = WidgetStyle()
    var modeAliases: [String: String] = [:]
    var widgetID = ""
    var allowsWindowDragging = true
    var appNameTooltip: (Bool, String, NSView) -> Void = { _, _, _ in }
    @Environment(\.measuringBarWidths) private var measuring
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @Namespace private var selection
    @State private var hoveredWorkspace: String?
    @State private var appIcons = WorkspaceAppIcons()
    @State private var magnifier = WorkspaceMagnifier()

    var body: some View {
        let workspaces = workspaceStore.workspaces(on: monitor,
            showEmpty: configuration?.showEmpty == true
                || (workspaceStore.source.supportsWindowMoves && workspaceStore.windowDrag.active != nil),
            hideApps: configuration?.hideApps ?? [], hideWorkspaces: configuration?.hideWorkspaces ?? [])
        let indicator = configuration?.indicator ?? .background
        HStack(spacing: appearance.spacing) {
            ForEach(workspaces) { workspace in
                let mode = configuration?.usesModeStates == true
                    ? ModePresentation(mode: workspaceStore.mode, aliases: modeAliases) : ModePresentation()
                let styles = configuration?.cellStyle(WorkspaceState(workspace), mode: mode) ?? WorkspaceCellStyle()
                let hovered = hoveredWorkspace == workspace.name
                let style = styles.label(hovered: hovered)
                let glyph = styles.glyph(hovered: hovered)
                let zoomedBelow = magnification.map { (glyph.height ?? 14) * ($0 - 1) } ?? 0
                let textColor = style.foreground?.color ?? (workspace.isFocused ? appearance.accentText : appearance.foreground)
                let highlight = configuration?.focusedWindowStyle
                    .map { $0.resolved(for: StyleStates(workspace: WorkspaceState(workspace), mode: mode, hover: hovered)) }
                    .map { FocusedWindowHighlight(style: $0, color: textColor, magnifying: magnifying,
                                                  cornerRadius: $0.cornerRadius ?? styles.resting.cornerRadius ?? max(appearance.cornerRadius - 4, 0)) }
                HStack(spacing: style.spacing ?? 4) {
                    Button { workspaceStore.select(workspace) } label: {
                        Text(workspace.label)
                    }
                    .magnified(.label, by: magnifier, upTo: magnification)
                    .help("Switch to workspace \(workspace.label)")
                    .accessibilityLabel("Workspace \(workspace.label)\(workspace.isFocused ? ", focused" : workspace.isVisible ? ", visible" : "")")
                    .accessibilityAddTraits(workspace.isFocused ? .isSelected : [])
                    if configuration?.showApps != false {
                        if configuration?.windows == true {
                            ForEach(workspace.windows) { window in
                                windowButton(windows: [window], below: zoomedBelow, action: { workspaceStore.focus(window) }) {
                                    HStack(spacing: style.spacing ?? 4) {
                                        appIcon(window.app, style: glyph, spacing: style.spacing ?? 4,
                                                highlight: window.isFocused ? highlight : nil)
                                        if let length = configuration?.titleLength, length > 0 {
                                            Text(String(window.title.prefix(length))).magnified(.label, by: magnifier, upTo: magnification)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .help(magnification == nil ? window.title : "")
                                .accessibilityLabel("\(window.app.name): \(window.title)\(window.isFocused ? ", focused" : "")")
                                .accessibilityAddTraits(window.isFocused ? .isSelected : [])
                                .accessibilityValue(badgeValue(for: window.app))
                            }
                        } else {
                            ForEach(workspace.apps) { app in
                                let windows = workspace.windows.filter { $0.app.bundleID == app.bundleID }
                                let focused = windows.contains(where: \.isFocused)
                                windowButton(windows: windows, below: zoomedBelow, action: { workspaceStore.select(workspace) }) {
                                    appIcon(app, style: glyph, spacing: style.spacing ?? 4, highlight: focused ? highlight : nil)
                                }
                                .help(magnification == nil ? app.name : "")
                                .accessibilityValue(badgeValue(for: app))
                                .accessibilityLabel("\(app.name)\(focused ? ", focused" : "")")
                                .accessibilityAddTraits(focused ? .isSelected : [])
                            }
                        }
                    }
                }
                .font(WidgetAppearance(style, defaults: defaults).font)
                .foregroundStyle(textColor)
                .padding(.leading, style.paddingLeading ?? style.paddingHorizontal ?? 7)
                .padding(.trailing, style.paddingTrailing ?? style.paddingHorizontal ?? 7)
                .frame(width: style.width.map { CGFloat($0) }, height: style.height.map { CGFloat($0) })
                .padding(padding)
                .background {
                    Button { workspaceStore.select(workspace) } label: {
                        Color.clear.contentShape(Rectangle())
                    }
                    .accessibilityLabel("Switch to workspace \(workspace.label)")
                }
                .buttonStyle(.plain)
                .modifier(WorkspaceWindowDrop(store: workspaceStore, workspace: workspace.name, enabled: canDragWindows))
                .overlay(alignment: .bottom) {
                    if indicator == .underline && workspace.isVisible && styles.underline.placement != .belowBar {
                        RoundedRectangle(cornerRadius: styles.underline.cornerRadius ?? 0)
                            .fill(styles.underline.background?.shapeStyle ?? AnyShapeStyle(appearance.accent))
                            .frame(width: styles.underline.width.map { CGFloat($0) }, height: styles.underline.height ?? 2)
                            .magnified(.background, by: magnifier, upTo: magnification)
                            .matchedGeometryEffect(id: "workspace-underline", in: selection)
                            .offset(x: styles.underline.offsetX ?? 0, y: (styles.underline.offsetY ?? 0) - padding.bottom)
                    }
                }
                .background {
                    if indicator == .background && workspace.isFocused {
                        RoundedRectangle(cornerRadius: styles.resting.cornerRadius ?? max(appearance.cornerRadius - 4, 0))
                            .fill(styles.resting.background?.shapeStyle ?? AnyShapeStyle(appearance.accent))
                            .magnified(.background, by: magnifier, upTo: magnification)
                            .matchedGeometryEffect(id: "focused-workspace", in: selection)
                    } else if indicator == .background && workspace.isVisible {
                        RoundedRectangle(cornerRadius: styles.resting.cornerRadius ?? max(appearance.cornerRadius - 4, 0))
                            .strokeBorder(styles.resting.borderColor?.color ?? appearance.accent, lineWidth: styles.resting.borderWidth ?? 1)
                            .magnified(.background, by: magnifier, upTo: magnification)
                    }
                }
                .overlay {
                    if canDragWindows && workspaceStore.windowDrag.target == workspace.name {
                        RoundedRectangle(cornerRadius: styles.resting.cornerRadius ?? max(appearance.cornerRadius - 4, 0))
                            .strokeBorder(appearance.accent, lineWidth: 2)
                            .allowsHitTesting(false)
                    }
                }
                .anchorPreference(key: BarAnchorPreference.self, value: .bounds) { anchor in
                    guard !measuring, indicator == .underline, workspace.isVisible, styles.underline.placement == .belowBar else {
                        return BarAnchors()
                    }
                    // One visible selection per widget/display keeps its identity as focus moves.
                    return BarAnchors(underlines: [widgetID: WorkspaceUnderlineAnchor(widget: widgetID, cell: anchor,
                        selection: workspace.name,
                        style: styles.underline, color: styles.underline.background?.firstColor.color ?? appearance.accent,
                        animation: animation)])
                }
                .onHover { hoveredWorkspace = $0 ? workspace.name : nil }
                .animation(hoverAnimation(hovered, reduceMotion: reduceMotion), value: hovered)
            }
            if let error = workspaceStore.error {
                Image(systemName: "exclamationmark.triangle").padding(padding).help(error)
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .global) { phase in
            if workspaceStore.windowDrag.active == nil { magnifier.track(phase) }
        }
        .onChange(of: workspaceStore.windowDrag.active != nil) { _, dragging in
            if dragging { magnifier.track(.ended) }
        }
        .fixedSize(horizontal: true, vertical: false)
        .animation(reduceMotion ? nil : animation.value, value: workspaces)
    }

    private var magnification: CGFloat? { configuration?.magnification.map { CGFloat($0) } }

    /// The magnifier tracks the pointer even with magnification off, when nothing zooms.
    private var magnifying: Bool { magnification != nil && magnifier.isActive }

    private var canDragWindows: Bool {
        allowsWindowDragging && !measuring && workspaceStore.source.supportsWindowMoves
    }

    @ViewBuilder private func windowButton(windows: [WorkspaceWindow], below: CGFloat, action: @escaping () -> Void,
                                           @ViewBuilder label: @escaping () -> some View) -> some View {
        if canDragWindows && !windows.isEmpty {
            WorkspaceWindowDragSource(store: workspaceStore, windows: windows, action: action) {
                Button(action: action) { label().padding(.bottom, below).contentShape(Rectangle()) }.buttonStyle(.plain)
            }
            .padding(.bottom, -below)
        } else {
            Button(action: action) { label().padding(.bottom, below).contentShape(Rectangle()) }
                .padding(.bottom, -below)
        }
    }

    private func badgeValue(for app: WorkspaceApp) -> String {
        guard configuration?.badges != nil, let label = workspaceStore.dockBadges.labels[app.bundleID] else { return "" }
        return "Badge \(label)"
    }

    @ViewBuilder private func appIcon(_ app: WorkspaceApp, style: WidgetStyle, spacing: CGFloat,
                                      highlight: FocusedWindowHighlight? = nil) -> some View {
        let zoom = magnification ?? 1
        let style = highlight.map { $0.style.inheriting(style) } ?? style
        let icon = Group {
            if let glyphs = configuration?.appGlyphs, let text = appGlyph(for: app, in: glyphs) {
                Text(text)
                    .font(WidgetAppearance(style, defaults: WidgetStyle()).font)
                    .foregroundStyle(style.foreground?.color ?? appearance.foreground)
            } else if let image = appIcons.image(for: app.bundleID,
                                                 size: NSSize(width: (style.width ?? 14) * zoom, height: (style.height ?? 14) * zoom),
                                                 scale: displayScale) {
                Image(nsImage: image)
                    .renderingMode(.original)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: style.width ?? 14, height: style.height ?? 14)
            }
        }
        // Inside the icon, so magnification zooms and slides the highlight with it.
        .background { highlight }
        .overlay(alignment: .topTrailing) {
            if let badges = configuration?.badges, let label = workspaceStore.dockBadges.labels[app.bundleID] {
                DockBadge(style: badges, label: label, iconHeight: style.height ?? 14)
            }
        }
        if let magnification {
            icon
                .modifier(WorkspaceMagnification(magnifier: magnifier, part: .icon, maximum: magnification))
                .modifier(AppNameTooltip(name: app.name, magnifier: magnifier, spacing: spacing, hover: appNameTooltip))
        } else {
            icon
        }
    }
}

/// The focused window's highlight, drawn outside the icon's frame so focus moving doesn't shift the icons.
private struct FocusedWindowHighlight: View {
    let style: WidgetStyle
    let color: Color
    /// Scaled with a magnified icon, so it hugs the icon then to stay small and below the bar's top edge.
    let magnifying: Bool
    let cornerRadius: Double

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        shape.fill(style.background?.shapeStyle ?? AnyShapeStyle(color.opacity(0.22)))
            .overlay {
                if let border = style.borderColor { shape.strokeBorder(border.color, lineWidth: style.borderWidth ?? 1) }
            }
            .padding(.horizontal, magnifying ? -2 : -3)
            .padding(.vertical, magnifying ? 0 : -2)
            .allowsHitTesting(false)
    }
}

private struct MenuBarItemsView: View {
    let widget: WidgetConfiguration
    let store: BarStore
    let defaults: WidgetStyle
    let appearance: WidgetAppearance
    let padding: EdgeInsets
    let symbol: String
    let toggleRow: (NSView) -> Void
    let hoverRow: (Bool, NSView) -> Void

    var body: some View {
        let shown = widget.shownMenuBarItems
        let openAnchor = store.presentations[widget.id]?.popupAnchor
        HStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.offset) { position, entry in
                switch entry {
                case .symbol:
                    MenuBarItemCell(appearance: appearance, padding: padding, openAnchor: openAnchor, click: toggleRow) { anchor, inside in
                        if inside, switches(to: anchor) { toggleRow(anchor) }
                        hoverRow(inside, anchor)
                    } label: {
                        Image(systemName: symbol).font(.system(size: appearance.iconSize))
                    }
                    .accessibilityLabel("Menu bar items")
                    .contextMenu { commands(position, count: shown.count, isSymbol: true) }
                case let .item(reference):
                    ForEach(Array(store.appMenu.menuBarItems.filter(reference.matches).enumerated()), id: \.offset) { _, item in
                        itemCell(item, icon: reference.icon, openAnchor: openAnchor)
                            .contextMenu { commands(position, count: shown.count, isSymbol: false) }
                    }
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .onHover { if $0 { Task { await store.appMenu.readMenuBarItems(requestingAccess: false) } } }
    }

    private func itemCell(_ item: MenuBarItem, icon: String?, openAnchor: ObjectIdentifier?) -> some View {
        MenuBarItemCell(appearance: appearance, padding: padding, openAnchor: openAnchor, actsOnMouseDown: !item.entry.hasSubmenu) { anchor in
            open(item, anchor: anchor)
        } hover: { anchor, inside in
            if inside, switches(to: anchor) {
                if item.entry.hasSubmenu { open(item, anchor: anchor) } else { store.popup.close() }
            }
            store.popup.hover(inside, store: store, anchor: anchor) {
                store.popup.showTooltip(item.entry.title, widget: widget, defaults: defaults, store: store, anchor: anchor)
            }
        } label: {
            if let icon {
                Image(systemName: icon).font(.system(size: appearance.iconSize))
            } else {
                Image(nsImage: item.entry.icon!).resizable().scaledToFit().frame(height: appearance.iconSize)
            }
        }
        .accessibilityLabel(item.entry.title)
    }

    private func commands(_ position: Int, count: Int, isSymbol: Bool) -> some View {
        MenuBarItemCommands(source: .shown(position), shownCount: count, isSymbol: isSymbol) { placement, index in
            store.move(.shown(position), to: placement, before: index, in: widget)
        }
    }

    private func switches(to anchor: NSView) -> Bool {
        let openAnchor = store.presentations[widget.id]?.popupAnchor
        return openAnchor != nil && openAnchor != ObjectIdentifier(anchor) && store.popup.pinned
    }

    private func open(_ item: MenuBarItem, anchor: NSView) {
        if item.entry.hasSubmenu {
            store.popup.toggle(store.appMenu.popup(forMenuBarItem: item.entry.element), widget: widget, defaults: defaults, store: store, anchor: anchor)
        } else if store.barEditing.allowsWidgetActions {
            store.popup.close()
            store.appMenu.pressUnlessOpen(item.entry)
        }
    }
}

struct MenuBarItemCommands: View {
    let source: MenuBarItemSource
    let shownCount: Int
    let isSymbol: Bool
    let move: (MenuBarItemPlacement, Int?) -> Void

    var body: some View {
        if case let .shown(position) = source {
            Button("Move Left") { move(.bar, position - 1) }.disabled(position == 0)
            Button("Move Right") { move(.bar, position + 2) }.disabled(position == shownCount - 1)
            Divider()
        }
        if source.placement != .bar { Button("Show on Bar") { move(.bar, nil) } }
        if source.placement != .row && !isSymbol { Button("Move to Row") { move(.row, nil) } }
        if source.placement != .hidden { Button("Hide") { move(.hidden, nil) } }
    }
}

private struct MenuBarItemCell<Label: View>: View {
    let appearance: WidgetAppearance
    let padding: EdgeInsets
    let openAnchor: ObjectIdentifier?
    var actsOnMouseDown = false
    let click: (NSView) -> Void
    let hover: (NSView, Bool) -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovered = false
    @State private var anchor = NSView()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let highlighted = openAnchor.map { $0 == ObjectIdentifier(anchor) } ?? hovered
        let button = Button { click(anchor) } label: {
            ZStack {
                Text(" ").hidden()
                label()
            }
            .padding(.horizontal, 7)
            .padding(padding)
            .background {
                if highlighted { RoundedRectangle(cornerRadius: max(appearance.cornerRadius - 4, 0)).fill(appearance.hoverBackground) }
            }
            .background(MenuAnchor(view: anchor))
            .contentShape(Rectangle())
        }
        Group {
            if actsOnMouseDown { button.buttonStyle(MouseDownButtonStyle()) } else { button.buttonStyle(.plain) }
        }
        .animation(hoverAnimation(highlighted, reduceMotion: reduceMotion), value: highlighted)
        .onHover { inside in
            hovered = inside
            hover(anchor, inside)
        }
    }
}

private struct AppMenuRow: View {
    let widget: WidgetConfiguration
    let store: BarStore
    let defaults: WidgetStyle
    let appearance: WidgetAppearance
    let padding: EdgeInsets

    var body: some View {
        AppMenuView(appMenu: store.appMenu, items: store.appMenu.items, appearance: appearance, padding: padding,
                    openAnchor: store.presentations[widget.id]?.innerPopupAnchor, open: { item, anchor in
            guard let popup = store.appMenu.popup(for: item) else { return }
            store.innerPopup.toggle(popup, widget: widget, defaults: defaults, store: store, anchor: anchor)
        }, requestAccess: store.windowClearance.requestAccess)
    }
}

extension AppMenuView {
    /// How many menus, from the app's name on, fit in `available` points, leaving room for the overflow button when
    /// some don't. The app's name always stays.
    static func visibleCount(widths: [CGFloat], available: CGFloat, overflowWidth: CGFloat) -> Int {
        guard !widths.isEmpty else { return 0 }
        if widths.reduce(0, +) <= available + 0.5 { return widths.count }
        var used = overflowWidth
        var count = 0
        for width in widths {
            if count > 0 && used + width > available + 0.5 { break }
            used += width
            count += 1
        }
        return count
    }
}

/// How much narrower than all its menus the bar needs an App menus widget to be; 0 shows every menu.
private struct AppMenuShrinkKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }

extension EnvironmentValues {
    var appMenuShrink: CGFloat {
        get { self[AppMenuShrinkKey.self] }
        set { self[AppMenuShrinkKey.self] = newValue }
    }
}

struct AppMenuView: View {
    let appMenu: AppMenu
    let items: [AppMenuItem]
    var expandOnHover = false
    var hovering = false
    var expanded = false
    var isAppleMenu = false
    let appearance: WidgetAppearance
    let padding: EdgeInsets
    var openAnchor: ObjectIdentifier?
    let open: (AppMenuItem, NSView) -> Void
    let requestAccess: () -> Void
    var expansionChanged: (Bool) -> Void = { _ in }
    /// Opens the menus that don't fit, from the overflow button.
    var openOverflow: ([AppMenuItem], NSView) -> Void = { _, _ in }
    @State private var hoveredItem: AppMenuItem?
    @State private var anchors: [Int: NSView] = [:]
    /// Each menu title's width by its place and title, measured in a hidden row.
    @State private var titleWidths: [String: CGFloat] = [:]
    @State private var overflowWidth: CGFloat = 0
    @State private var overflowAnchor = NSView()
    @State private var hoveringOverflow = false
    @Environment(\.appMenuShrink) private var shrink

    private var widths: [CGFloat]? {
        let widths = items.enumerated().compactMap { titleWidths["\($0.offset):\($0.element.title)"] }
        return widths.count == items.count ? widths : nil
    }

    var body: some View {
        let collapsed = expandOnHover && !expanded
        let count = collapsed ? min(items.count, 1)
            : shrink > 0.5 && !isAppleMenu ? widths.map { Self.visibleCount(widths: $0, available: $0.reduce(0, +) - shrink, overflowWidth: overflowWidth) } ?? items.count
            : items.count
        HStack(spacing: 0) {
            if !appMenu.isTrusted && !appMenu.hidesAccessWarning {
                Button(action: requestAccess) {
                    Image(systemName: "exclamationmark.triangle").padding(padding).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Allow StableBar in Privacy & Security → Accessibility to show the app's menus. Click to open System Settings and drag StableBar into the list.")
            }
            ForEach(Array(items.prefix(count).enumerated()), id: \.offset) { index, item in
                let anchor = anchors[index].map(ObjectIdentifier.init)
                AppMenuTitle(item: item, index: index, isAppleMenu: isAppleMenu, appearance: appearance, padding: padding,
                             highlighted: openAnchor.map { $0 == anchor } ?? (hoveredItem == item), anchors: $anchors) {
                    open(item, anchors[index]!)
                }
                .onHover { inside in
                    hoveredItem = inside ? item : nil
                    if inside, openAnchor != nil, openAnchor != anchor { open(item, anchors[index]!) }
                }
                .transition(.opacity)
            }
            if !collapsed && count < items.count {
                AppMenuOverflowButton(appearance: appearance, padding: padding, anchor: overflowAnchor,
                                      highlighted: openAnchor.map { $0 == ObjectIdentifier(overflowAnchor) } ?? hoveringOverflow) {
                    openOverflow(Array(items.dropFirst(count)), overflowAnchor)
                }
                .onHover { inside in
                    hoveringOverflow = inside
                    hoveredItem = nil
                    if inside, openAnchor != nil, openAnchor != ObjectIdentifier(overflowAnchor) {
                        openOverflow(Array(items.dropFirst(count)), overflowAnchor)
                    }
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .clipped()
        .background { measuringRow }
        .onHover { if $0 { appMenu.refresh() } }
        .onChange(of: hovering || openAnchor != nil, initial: true) { _, expanded in expansionChanged(expanded) }
        .onDisappear { expansionChanged(false) }
    }
}

extension AppMenuView {
    /// Every menu title and the overflow button, hidden, to measure what fits.
    private var measuringRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                Text(item.title).fontWeight(index == 0 ? .bold : nil)
                    .padding(.horizontal, isAppleMenu ? 0 : 7)
                    .padding(padding)
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { titleWidths["\(index):\(item.title)"] = $0 }
            }
            AppMenuOverflowButton.label(padding: padding)
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { overflowWidth = $0 }
        }
        .hidden()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// » after the menus that fit, which opens the rest.
private struct AppMenuOverflowButton: View {
    let appearance: WidgetAppearance
    let padding: EdgeInsets
    let anchor: NSView
    let highlighted: Bool
    let open: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func label(padding: EdgeInsets) -> some View {
        Image(systemName: "chevron.right.2").font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(padding)
    }

    var body: some View {
        Button(action: open) {
            Self.label(padding: padding)
                .foregroundStyle(appearance.foreground)
                .background {
                    if highlighted { RoundedRectangle(cornerRadius: max(appearance.cornerRadius - 4, 0)).fill(appearance.hoverBackground) }
                }
                .background(MenuAnchor(view: anchor))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("More menus")
        .accessibilityLabel("More menus")
        .animation(hoverAnimation(highlighted, reduceMotion: reduceMotion), value: highlighted)
    }
}

private struct AppMenuTitle: View {
    let item: AppMenuItem
    let index: Int
    let isAppleMenu: Bool
    let appearance: WidgetAppearance
    let padding: EdgeInsets
    let highlighted: Bool
    @Binding var anchors: [Int: NSView]
    let open: () -> Void
    @State private var anchor = NSView()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: open) {
            Group {
                if isAppleMenu {
                    Image(systemName: "apple.logo").accessibilityLabel(item.title)
                } else {
                    Text(item.title).fontWeight(index == 0 ? .bold : nil)
                }
            }
            .foregroundStyle(appearance.foreground)
            .padding(.horizontal, isAppleMenu ? 0 : 7)
            .padding(padding)
            .background {
                if highlighted { RoundedRectangle(cornerRadius: max(appearance.cornerRadius - 4, 0)).fill(appearance.hoverBackground) }
            }
            .background(MenuAnchor(view: anchor))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(hoverAnimation(highlighted, reduceMotion: reduceMotion), value: highlighted)
        .onAppear { anchors[index] = anchor }
    }
}

/// The Apple logo as a button, drawn like the Apple menu's logo, for clicks that don't open the menu and until the menu is read.
private struct AppleLogoButton: View {
    let appearance: WidgetAppearance
    let padding: EdgeInsets
    let label: String
    let help: String?
    let action: () -> Void
    let hover: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: "apple.logo").accessibilityLabel(label)
                .foregroundStyle(appearance.foreground)
                .padding(padding)
                .background {
                    if hovered { RoundedRectangle(cornerRadius: max(appearance.cornerRadius - 4, 0)).fill(appearance.hoverBackground) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help ?? "")
        .animation(hoverAnimation(hovered, reduceMotion: reduceMotion), value: hovered)
        .onHover { inside in
            hovered = inside
            if inside { hover() }
        }
    }
}

private struct MouseDownButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: PrimitiveButtonStyleConfiguration) -> some View {
        configuration.label.onLongPressGesture(minimumDuration: 0, perform: {}) { pressing in
            if pressing { configuration.trigger() }
        }
    }
}

struct MenuAnchor: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

func appGlyph(for app: WorkspaceApp, in glyphs: [String: String]) -> String? {
    if let glyph = glyphs[app.bundleID] ?? glyphs[app.name] { return glyph }
    return glyphs.filter { $0.key.hasSuffix("*") && appMatches(app, key: $0.key) }.max { $0.key.count < $1.key.count }?.value
}

/// Whether an `appGlyphs` or `hideApps` key names the app: its bundle ID, its name, or a name prefix followed by `*`.
func appMatches(_ app: WorkspaceApp, key: String) -> Bool {
    key == app.bundleID || key == app.name || key.hasSuffix("*") && app.name.hasPrefix(key.dropLast())
}
