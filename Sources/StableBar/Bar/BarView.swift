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
    @State private var measuredWidths: [String: CGFloat] = [:]
    @State private var measuredUnits: Set<String> = []
    @State private var restingWidths: [String: CGFloat] = [:]
    /// Each unit with App menus measured with only the app name and », by unit ID.
    @State private var narrowestWidths: [String: CGFloat] = [:]
    @FocusState private var focusedWidget: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .top) {
            // The edit bar starts from the widths this bar measured, so switching draws every widget where it was.
            if store.barEditing.isActive && !preview {
                BarEditStart(store: store, display: display, widths: $restingWidths)
            } else if let config = store.configuration?.onScreen(ScreenKind(display)) {
                let scale = CGFloat(config.bar.scale(for: display))
                let barGeometry = config.barGeometry(for: display)
                let notch = config.bar.layoutNotch(on: display)
                let widgets = store.barEditing.widgets(on: display)
                let units = BarUnit.make(widgets: widgets + [store.update?.widget, store.packageLibrary.updateWidget].compactMap { $0 }, groups: config.groups)
                PlacedUnits(store: store, display: display, nativeDecorations: nativeDecorations, preview: preview, config: config,
                            units: units, scale: scale, notch: notch, measuredWidths: $measuredWidths, measuredUnits: $measuredUnits,
                            restingWidths: $restingWidths, narrowestWidths: $narrowestWidths, focusedWidget: $focusedWidget)
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
                        Button { store.onWindowRequest?(.customize) } label: {
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
            }
        }
        .environment(\.colorScheme, store.configuration?.bar(on: ScreenKind(display)).appearance?.colorScheme ?? colorScheme)
        .environment(\.screenKind, ScreenKind(display))
        .focusEffectDisabled(!store.barEditing.isActive)
        .frame(maxHeight: .infinity, alignment: store.configuration?.bar(on: ScreenKind(display)).position == .bottom ? .bottom : .top)
        .allowsHitTesting(!preview)
        .accessibilityHidden(preview)
        .onDisappear { if !preview { store.widgetScripts.setVisibleWidgets(ids: [], displayID: display.id) } }
        .contextMenu {
            if !preview {
                BarContextMenu(store: store, display: display.id)
            }
        }
    }
}

struct PlacedUnits: View {
    let store: BarStore
    let display: BarDisplay
    let nativeDecorations: Bool
    let preview: Bool
    let config: Configuration
    let units: [BarUnit]
    let scale: CGFloat
    let notch: ClosedRange<CGFloat>?
    /// Only the view in a bar's own panel follows `--focus`, not Settings' or the setup's.
    private var focusesWidgets: Bool { nativeDecorations && store.barPanel(display.id)?.focusesWidgets == true }
    @Binding var measuredWidths: [String: CGFloat]
    @Binding var measuredUnits: Set<String>
    @Binding var restingWidths: [String: CGFloat]
    @Binding var narrowestWidths: [String: CGFloat]
    @FocusState.Binding var focusedWidget: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let growth = Dictionary(uniqueKeysWithValues: units.map { unit in
                (unit.id, max((measuredWidths[unit.id] ?? 0) - (restingWidths[unit.id] ?? 0), 0))
            })
            let minimums = Dictionary(uniqueKeysWithValues: units.compactMap { unit in
                BarView.minimumWidth(resting: restingWidths[unit.id], narrowest: narrowestWidths[unit.id]).map { (unit.id, $0) }
            })
            let items = units.map { unit in
                BarLayoutItem(id: unit.id, position: unit.position, width: restingWidths[unit.id] ?? 0, priority: unit.priority,
                              canOverflow: unit.canOverflow, isSpacer: unit.isSpacer, growth: growth[unit.id]!,
                              minimumWidth: minimums[unit.id])
            }
            let moreWidth = measuredWidths[BarView.moreWidgetsUnit.id] ?? 0
            let plan = AdaptiveBarPlanner(inset: config.bar.inset, spacing: config.bar.spacing,
                                          notchSpacing: config.bar.notchSpacing, notch: notch, overflowWidth: moreWidth)
                .plan(width: geometry.size.width / scale, items: items)
            let visible = Set(units.filter { plan.placements[$0.id] != nil }.flatMap { $0.widgets.map(\.id) })
            ZStack(alignment: .topLeading) {
                Color.clear.allowsHitTesting(false)
                if let divider = config.bar.divider, let fill = divider.background {
                    let width = divider.width ?? 1
                    ForEach(plan.dividers.keys.sorted(), id: \.self) { id in
                        RoundedRectangle(cornerRadius: divider.cornerRadius ?? 0)
                            .fill(fill.shapeStyle)
                            .frame(width: width, height: divider.height ?? 16)
                            .opacity(divider.opacity ?? 1)
                            .frame(height: geometry.size.height / scale)
                            .offset(x: plan.dividers[id]! - width / 2)
                            .allowsHitTesting(false)
                    }
                }
                ForEach(units) { unit in
                    if let placement = plan.placements[unit.id] {
                        let alignment: Alignment = switch unit.position {
                        case .left: .leading
                        case .right: .trailing
                        case .notchLeft, .center, .notchRight: .center
                        }
                        unitView(unit, width: placement.width, minimum: minimums[unit.id])
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
                                      id: BarView.moreWidgetsID(overflowUnits[0].position, notched: notch != nil))
                        .frame(width: moreWidth, height: geometry.size.height / scale)
                        .offset(x: overflow.x)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : config.bar.animation.value, value: store.update?.version != nil)
            .animation(reduceMotion ? nil : config.bar.animation.value, value: plan.overflow.map(\.ids))
            .onMoveCommand { direction in
                focusedWidget = BarView.focusTarget(from: focusedWidget, moving: direction, units: units, placements: plan.placements)
            }
            .onChange(of: focusesWidgets) {
                focusedWidget = focusesWidgets ? BarView.focusTarget(from: nil, moving: .right, units: units, placements: plan.placements) : nil
            }
            .overlay {
                HStack(spacing: 0) {
                    ForEach(units + [BarView.moreWidgetsUnit]) { unit in
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
                    unit.widgets.contains { store.barPresentation.presentations[$0.id]?.expandedDisplays.contains(display.id) == true }
                }.map(\.id))
                withAnimation(animates ? config.bar.animation.value : nil) {
                    measuredWidths.merge(widths) { $1 }
                    restingWidths.merge(widths.filter { !expanded.contains($0.key) }) { $1 }
                }
            }
            .onChange(of: visible, initial: true) { _, ids in if !preview { store.widgetScripts.setVisibleWidgets(ids: ids, displayID: display.id) } }
            .frame(width: geometry.size.width / scale, height: geometry.size.height / scale)
            .scaleEffect(scale, anchor: .topLeading)
        }
    }

    @ViewBuilder
    private func unitView(_ unit: BarUnit, width: CGFloat, minimum: CGFloat?) -> some View {
        if BarView.scrolls(width: width, resting: restingWidths[unit.id, default: 0], minimum: minimum) {
            ScrollView(.horizontal) {
                BarUnitView(unit: unit, config: config, store: store, display: display.id).fixedSize()
            }
            .scrollIndicators(.hidden)
        } else {
            BarUnitView(unit: unit, config: config, store: store, display: display.id)
        }
    }
}

private struct BarEditStart: View {
    let store: BarStore
    let display: BarDisplay
    @Binding var widths: [String: CGFloat]

    var body: some View {
        BarEditView(store: store, display: display, widths: widths)
    }
}

private struct BarContextMenu: View {
    let store: BarStore
    let display: Int

    var body: some View {
        Group {
            Label { Text("StableBar") } icon: { if let heading = MenuIcon.heading { Image(nsImage: heading) } }
            if store.barEditing.isAvailable { item(store.barEditing.menuTitle, store.barEditing.menuIcon, action: store.barEditing.toggle) }
            item("Try Themes…", .themes) { store.onWindowRequest?(.tryThemes(display)) }
            item("Get Widgets…", .store) { NSApp.sendAction(#selector(AppDelegate.getWidgets), to: NSApp.delegate, from: nil) }
            let error = store.configurationError ?? store.workspaceStore.error ?? store.configurationWarning
            if error != nil || store.crashReports.note != nil { Divider() }
            if let error {
                item(AppDelegate.menuTitle(error: error), .problem) {
                    NSApp.sendAction(#selector(AppDelegate.showStatus), to: NSApp.delegate, from: nil)
                }
            }
            if let note = store.crashReports.note { item(note, .problem) { store.onWindowRequest?(.showCrashes) } }
            Divider()
            item("Share My Bar…", .share) { if let screen = store.barPanel(display)?.screen { barShare.show(store: store, screen: screen) } }
            item("Send Feedback…", .feedback) { NSApp.sendAction(#selector(AppDelegate.showFeedback), to: NSApp.delegate, from: nil) }
            item("Settings…", .settings) { store.onWindowRequest?(.customize) }
            item("Quit StableBar", .quit) { NSApp.terminate(nil) }
        }
        .labelStyle(.titleAndIcon)
    }

    private func item(_ title: String, _ icon: MenuIcon, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label { Text(title) } icon: { icon.menuImage } }
    }
}

/// Edit Widget… and the bar's menu, unless the widget's `rightClick` action takes the click.
struct WidgetContextMenu: View {
    let widget: WidgetConfiguration
    let store: BarStore
    let display: Int
    /// For a menu that lists other commands first.
    var dividerAbove = false

    var body: some View {
        if store.barEditing.allowsWidgetActions, widget.actions?.rightClick == nil,
           store.configuration?.widgets.contains(where: { $0.id == widget.id }) == true {
            if dividerAbove { Divider() }
            Button("Edit Widget…") { store.onWindowRequest?(.customizeItem(.widget(widget.id))) }
            Divider()
            BarContextMenu(store: store, display: display)
        }
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
            store.popup.showWidgets(defaults: config.popupDefaults.popupStyle(over: config.defaults), store: store, anchor: anchor) {
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
    /// Drawn by `OffscreenSnapshot`, for an image rather than the screen.
    @Entry var offscreenSnapshot = false
}
