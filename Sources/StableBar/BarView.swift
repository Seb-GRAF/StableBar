import SwiftUI

struct BarView: View {
    static let moreWidgetsID = "StableBar.moreWidgets"
    let store: BarStore
    let display: BarDisplay
    var nativeDecorations = false
    var preview = false
    @State private var measuredWidths: [String: CGFloat] = [:]
    @State private var measuredUnits: Set<String> = []
    @State private var overflowAnchor = NSView()
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
                let notch = display.notch.map { range in
                    let range: ClosedRange<CGFloat> = ((range.lowerBound - config.bar.margin) / scale)...((range.upperBound - config.bar.margin) / scale)
                    return config.bar.notchWidth.map { width in
                        let center = (range.lowerBound + range.upperBound) / 2
                        return (center - width / 2)...(center + width / 2)
                    } ?? range
                }
                let widgets = store.barEditing.widgets(on: display)
                let units = BarUnit.make(widgets: widgets + [store.update?.widget, store.packageLibrary.updateWidget].compactMap { $0 }, groups: config.groups)
                GeometryReader { geometry in
                    let items = units.map { unit in
                        BarLayoutItem(id: unit.id, position: unit.position, width: measuredWidths[unit.id] ?? 0,
                                      priority: unit.priority, canOverflow: unit.canOverflow, isSpacer: unit.isSpacer)
                    }
                    let plan = AdaptiveBarPlanner(inset: config.bar.inset, spacing: config.bar.spacing,
                                                  notchSpacing: config.bar.notchSpacing, notch: notch)
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
                                unitView(unit, config: config, width: placement.width)
                                    .geometryGroup()
                                    .frame(width: placement.width, height: geometry.size.height / scale, alignment: alignment)
                                    .transformAnchorPreference(key: BarAnchorPreference.self, value: .bounds) { anchors, bounds in
                                        anchors.viewports[unit.id] = bounds
                                    }
                                    .offset(x: placement.x)
                                    .transition(visibilityTransition(unit.transition ?? config.bar.motion.transition, still: reduceMotion))
                            }
                        }
                        if let x = plan.overflowX {
                            overflowMenu(units.filter { plan.overflow.contains($0.id) }, config: config)
                                .frame(width: 30, height: geometry.size.height / scale)
                                .background(PopupAnchor(view: overflowAnchor, popup: store.popup, id: Self.moreWidgetsID))
                                .offset(x: x)
                        }
                    }
                    .animation(reduceMotion ? nil : config.bar.animation.value, value: store.update?.version != nil)
                    .overlay {
                        HStack(spacing: 0) {
                            ForEach(units) { unit in
                                BarUnitView(unit: unit, config: config, store: store, display: display.id)
                                    .fixedSize()
                                    .background {
                                        GeometryReader { proxy in
                                            Color.clear.preference(key: BarWidthPreference.self, value: [unit.id: proxy.size.width])
                                        }
                                    }
                            }
                        }
                        .fixedSize()
                        .hidden()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .modifier(MeasuringCopy())
                    }
                    // Keeps the last width of units that leave, so a returning widget is planned at its size.
                    .onPreferenceChange(BarWidthPreference.self) { widths in
                        let animates = BarUnit.animatesResize(units, measured: measuredUnits, from: measuredWidths, to: widths,
                                                              reduceMotion: reduceMotion, providerType: config.providerType(of:))
                        measuredUnits = Set(widths.keys)
                        withAnimation(animates ? config.bar.animation.value : nil) {
                            measuredWidths.merge(widths) { $1 }
                        }
                    }
                    .onChange(of: visible, initial: true) { _, ids in if !preview { store.setVisibleWidgets(ids: ids, displayID: display.id) } }
                    .frame(width: geometry.size.width / scale, height: geometry.size.height / scale)
                    .scaleEffect(scale, anchor: .topLeading)
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
                .frame(height: nativeDecorations ? barGeometry.layoutHeight : barGeometry.panelHeight, alignment: .top)
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : store.configuration.map { .easeOut(duration: $0.bar(on: ScreenKind(display)).animation.duration) },
                   value: store.barEditing.isActive && !preview)
        .environment(\.colorScheme, store.configuration?.bar(on: ScreenKind(display)).appearance?.colorScheme ?? colorScheme)
        .environment(\.screenKind, ScreenKind(display))
        .frame(maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(!preview)
        .accessibilityHidden(preview)
        .onDisappear { if !preview { store.setVisibleWidgets(ids: [], displayID: display.id) } }
        .contextMenu {
            if !preview {
                Text("StableBar")
                if store.barEditing.isAvailable { Button(store.barEditing.menuTitle, action: store.barEditing.toggle) }
                Button("Try Themes…") { store.onTryThemes?(display.id) }
                if let error = store.configurationError ?? store.workspaceStore.error {
                    Divider()
                    Text(error)
                }
                Divider()
                Button("Settings…") { store.onCustomize?() }
                Button("Quit StableBar") { NSApp.terminate(nil) }
            }
        }
    }

    @ViewBuilder
    private func unitView(_ unit: BarUnit, config: Configuration, width: CGFloat) -> some View {
        if width < measuredWidths[unit.id, default: 0] - 0.5 {
            ScrollView(.horizontal) {
                BarUnitView(unit: unit, config: config, store: store, display: display.id).fixedSize()
            }
            .scrollIndicators(.hidden)
        } else {
            BarUnitView(unit: unit, config: config, store: store, display: display.id)
        }
    }

    private func overflowMenu(_ units: [BarUnit], config: Configuration) -> some View {
        Menu {
            ForEach(units) { unit in
                Section {
                    ForEach(unit.widgets) { widget in
                        let popup = widgetPopup(widget, store: store)
                        let command = store.scripts[widget.id]?.output.onClick ?? widget.onClick
                        let menuItems: [AppMenuItem]? = switch widget.content {
                        case .appleMenu: [store.appMenu.appleMenu].compactMap { $0 }
                        case .appMenu: store.appMenu.items
                        default: nil
                        }
                        if widget.content == .workspaces && popup == nil && command == nil {
                            ForEach(store.workspaceStore.workspaces.filter { $0.monitor == display.id }) { workspace in
                                Button("Workspace \(workspace.label)") { store.workspaceStore.select(workspace) }
                            }
                        } else if popup == nil && command == nil, let items = menuItems {
                            ForEach(items, id: \.self) { item in
                                Button(item.title) { store.appMenu.open(item, at: NSEvent.mouseLocation, in: nil) }
                            }
                        } else {
                            Button(overflowTitle(widget)) {
                                if let popup {
                                    store.popup.toggle(popup, widget: widget, defaults: config.popupDefaults.inheriting(config.defaults), store: store, anchor: overflowAnchor)
                                } else if let command {
                                    store.runAction(command, widget: widget,
                                                    event: ScriptEvent(sender: "mouse.clicked", environment: ["BUTTON": "left", "SID": String(display.id)]))
                                } else if let open = widget.open {
                                    OpenTarget(open)!.open()
                                }
                            }
                            .disabled(popup == nil && command == nil && widget.open == nil)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis").frame(width: 30, height: 24).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel("More widgets")
        .help("More widgets")
    }

    private func overflowTitle(_ widget: WidgetConfiguration) -> String {
        let text = store.label(for: widget).text
        return text.isEmpty ? widget.id : text
    }
}

private struct BarWidthPreference: PreferenceKey {
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
            BarUnitSurface(style: unit.style ?? WidgetStyle(), spacing: config.bar.spacing) {
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
    let spacing: Double
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: style.spacing ?? spacing, content: content)
            .padding(.leading, style.paddingLeading ?? style.paddingHorizontal ?? 0)
            .padding(.trailing, style.paddingTrailing ?? style.paddingHorizontal ?? 0)
            .padding(.top, style.paddingTop ?? style.paddingVertical ?? 0)
            .padding(.bottom, style.paddingBottom ?? style.paddingVertical ?? 0)
            .background(style.background?.shapeStyle ?? AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: style.cornerRadius ?? 0))
            .overlay {
                RoundedRectangle(cornerRadius: style.cornerRadius ?? 0)
                    .strokeBorder(style.borderColor?.color ?? .clear, lineWidth: style.borderWidth ?? 0)
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
    @Environment(\.measuringBarWidths) private var measuring
    @Environment(\.barUnitID) private var unitID
    @Environment(\.screenKind) private var screenKind

    private var resolution: ResolvedWidgetStyle {
        store.presentations[widget.id]?.style(on: screenKind) ?? ResolvedWidgetStyle(base: resolveStyle([defaults, widget.style]))
    }

    /// `tile` as a button for its click action, popup or link, or as it is while the bar is being
    /// edited, when it takes no clicks.
    @ViewBuilder private func clickable(_ tile: some View, output: ScriptOutput?) -> some View {
        if store.barEditing.isActive {
            tile.allowsHitTesting(false)
        } else if widget.id == PackageLibrary.updateWidgetID {
            HStack(spacing: 0) {
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
        } else if widget.hoverLayout != nil, let command = output?.onClick ?? widget.onClick {
            Button { runAction(command, sender: "mouse.clicked", button: "left") } label: { tile }
                .buttonStyle(.plain)
        } else if let popup = widgetPopup(widget, store: store) {
            Button {
                guard store.barEditing.allowsWidgetActions else { return }
                store.popup.toggle(popup, widget: widget, defaults: popupDefaults.inheriting(defaults), store: store, anchor: popupAnchor)
            } label: {
                if widget.id == AppUpdate.widgetID {
                    tile.accessibilityLabel(widget.tooltip!)
                } else {
                    tile
                }
            }
            .buttonStyle(.plain)
        } else if let command = output?.onClick ?? widget.onClick {
            Button { runAction(command, sender: "mouse.clicked", button: "left") } label: { tile }
                .buttonStyle(.plain)
        } else if let open = widget.open {
            Button { if store.barEditing.allowsWidgetActions { OpenTarget(open)!.open() } } label: { tile }
                .buttonStyle(.plain)
        } else {
            tile
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
        let style = resolution.style(hovered: hovered, open: isOpen)
        let appearance = WidgetAppearance(style, defaults: WidgetStyle())
        let animation = output?.animation ?? widget.animation ?? defaultAnimation
        let padding = EdgeInsets(top: style.paddingTop ?? appearance.paddingVertical, leading: 0,
                                 bottom: style.paddingBottom ?? appearance.paddingVertical, trailing: 0)
        // Workspace and menu buttons include vertical padding so their selection fills the tile.
        let hasCells = switch widget.content {
        case .workspaces, .appMenu, .appleMenu: widget.layout == nil
        default: false
        }
        let tile = Group {
            if let layout = widget.hoverLayout {
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
            .padding(.leading, style.paddingLeading ?? appearance.paddingHorizontal)
            .padding(.trailing, style.paddingTrailing ?? appearance.paddingHorizontal)
            .padding(.top, hasCells ? 0 : padding.top)
            .padding(.bottom, hasCells ? 0 : padding.bottom)
            .frame(width: appearance.width, height: style.height.map { CGFloat($0) })
            .frame(minWidth: style.minWidth.map { CGFloat($0) }, maxWidth: style.maxWidth.map { CGFloat($0) })
            .contentShape(Rectangle())
        clickable(tile, output: output)
        .font(appearance.font)
        .foregroundStyle(appearance.foreground)
        .modifier(GlassBackground(fill: style.background, glass: store.configuration?.bar(on: screenKind).glass ?? GlassSettings(), surface: \.widgets,
                                  shape: RoundedRectangle(cornerRadius: appearance.cornerRadius)))
        .overlay {
            RoundedRectangle(cornerRadius: appearance.cornerRadius)
                .strokeBorder(appearance.borderColor, lineWidth: appearance.borderWidth)
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
        .onHover { inside in
            guard store.barEditing.allowsWidgetActions else { return }
            hovered = inside
            if !inside {
                store.popup.hover(false, store: store, anchor: popupAnchor) {}
            } else if let popup = widgetPopup(widget, store: store), popup.openOnHover {
                store.popup.hover(inside, store: store, anchor: popupAnchor) {
                    store.popup.open(popup, widget: widget, defaults: popupDefaults.inheriting(defaults),
                                     store: store, anchor: popupAnchor, onHover: true)
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
        .animation(hoverAnimation(hovered, reduceMotion: reduceMotion), value: hovered)
        .animation(reduceMotion ? nil : animation.value, value: style)
        .animation(reduceMotion ? nil : animation.value, value: widget.content == .activeApp ? store.activeApp : nil)
        .accessibilityHint(tooltip ?? "")
        .accessibilityIdentifier(widget.id)
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
                          modeAliases: store.configuration?.look(on: screenKind).modeAliases ?? [:], widgetID: widget.id)
        case let .appMenu(expandOnHover) where widget.layout == nil:
            AppMenuView(appMenu: store.appMenu, items: store.appMenu.items, expandOnHover: expandOnHover, hovering: hovered,
                        expanded: store.presentations[widget.id]?.expandedDisplays.contains(monitor) == true,
                        appearance: WidgetAppearance(resolution.style(hovered: false, open: open), defaults: WidgetStyle()),
                        padding: padding, requestAccess: store.windowClearance.requestAccess) { expanded in
                if !measuring && expandOnHover {
                    store.presentations[widget.id]?.setExpanded(expanded, on: monitor, animation: reduceMotion ? nil : motion.animation)
                }
            }
        case .appleMenu where widget.layout == nil:
            AppMenuView(appMenu: store.appMenu, items: [store.appMenu.appleMenu].compactMap { $0 }, isAppleMenu: true,
                        appearance: WidgetAppearance(resolution.style(hovered: false, open: open), defaults: WidgetStyle()),
                        padding: padding, requestAccess: store.windowClearance.requestAccess)
        case .provider where widget.layout == nil && store.configuration?.providerType(of: widget) == DataSourceType.audio.name:
            SoundWidgetView(widget: widget, store: store, monitor: monitor,
                            style: resolution.layoutStyle(configured: false, hovered: hovered, open: open),
                            hovered: hovered, motion: motion, runAction: blockAction)
        case .spacer where widget.layout == nil:
            Spacer(minLength: resolution.base.minWidth ?? 0)
        default:
            timed { date in blocks(resolution, open: open, date: date) }
        }
    }

    /// `content` drawn for the time the widget shows: a clock's, redrawn on its schedule, otherwise now.
    @ViewBuilder
    private func timed<Content: View>(@ViewBuilder _ content: @escaping (Date) -> Content) -> some View {
        if case let .clock(format) = widget.content {
            TimelineView(clockSchedule(format)) { context in content(context.date) }
        } else {
            content(.now)
        }
    }

    private func blocks(_ resolution: ResolvedWidgetStyle, open: Bool, date: Date) -> some View {
        WidgetBlocks(widget: widget, store: store,
                     style: resolution.layoutStyle(configured: widget.layout != nil, hovered: hovered, open: open),
                     date: date, motion: motion, runAction: blockAction)
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
            let point = CGPoint(x: rect.width * Double(index) / 59,
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
    @Environment(\.measuringBarWidths) private var measuring
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @Namespace private var selection
    @State private var hoveredWorkspace: String?
    @State private var appIcons = WorkspaceAppIcons()

    var body: some View {
        let workspaces = workspaceStore.workspaces(on: monitor, showEmpty: configuration?.showEmpty == true)
        let indicator = configuration?.indicator ?? .background
        HStack(spacing: appearance.spacing) {
            ForEach(workspaces) { workspace in
                let mode = configuration?.usesModeStates == true
                    ? ModePresentation(mode: workspaceStore.mode, aliases: modeAliases) : ModePresentation()
                let styles = configuration?.cellStyle(WorkspaceState(workspace), mode: mode) ?? WorkspaceCellStyle()
                let hovered = hoveredWorkspace == workspace.name
                let style = styles.label(hovered: hovered)
                let glyph = styles.glyph(hovered: hovered)
                HStack(spacing: style.spacing ?? 4) {
                    Button { workspaceStore.select(workspace) } label: {
                        Text(workspace.label)
                    }
                    .help("Switch to workspace \(workspace.label)")
                    .accessibilityLabel("Workspace \(workspace.label)\(workspace.isFocused ? ", focused" : workspace.isVisible ? ", visible" : "")")
                    .accessibilityAddTraits(workspace.isFocused ? .isSelected : [])
                    if configuration?.showApps != false {
                        if configuration?.windows == true {
                            ForEach(workspace.windows) { window in
                                Button { workspaceStore.focus(window) } label: {
                                    HStack(spacing: style.spacing ?? 4) {
                                        appIcon(window.app, style: glyph)
                                        if let length = configuration?.titleLength, length > 0 {
                                            Text(String(window.title.prefix(length)))
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .help(window.title)
                                .accessibilityLabel("\(window.app.name): \(window.title)")
                            }
                        } else {
                            ForEach(workspace.apps) { app in
                                Button { workspaceStore.select(workspace) } label: {
                                    appIcon(app, style: glyph)
                                }
                                .help(app.name)
                            }
                        }
                    }
                }
                .font(WidgetAppearance(style, defaults: defaults).font)
                .foregroundStyle(style.foreground?.color ?? (workspace.isFocused ? appearance.accentText : appearance.foreground))
                .padding(.leading, style.paddingLeading ?? style.paddingHorizontal ?? 7)
                .padding(.trailing, style.paddingTrailing ?? style.paddingHorizontal ?? 7)
                .frame(width: style.width.map { CGFloat($0) }, height: style.height.map { CGFloat($0) })
                .overlay(alignment: .bottom) {
                    if indicator == .underline && workspace.isVisible && styles.underline.placement != .belowBar {
                        RoundedRectangle(cornerRadius: styles.underline.cornerRadius ?? 0)
                            .fill(styles.underline.background?.shapeStyle ?? AnyShapeStyle(appearance.accent))
                            .frame(width: styles.underline.width.map { CGFloat($0) }, height: styles.underline.height ?? 2)
                            .matchedGeometryEffect(id: "workspace-underline", in: selection)
                            .offset(x: styles.underline.offsetX ?? 0, y: styles.underline.offsetY ?? 0)
                    }
                }
                .padding(padding)
                .background {
                    Button { workspaceStore.select(workspace) } label: {
                        Color.clear.contentShape(Rectangle())
                    }
                    .accessibilityLabel("Switch to workspace \(workspace.label)")
                }
                .background {
                    if indicator == .background && workspace.isFocused {
                        RoundedRectangle(cornerRadius: styles.resting.cornerRadius ?? max(appearance.cornerRadius - 4, 0))
                            .fill(styles.resting.background?.shapeStyle ?? AnyShapeStyle(appearance.accent))
                            .matchedGeometryEffect(id: "focused-workspace", in: selection)
                    } else if indicator == .background && workspace.isVisible {
                        RoundedRectangle(cornerRadius: styles.resting.cornerRadius ?? max(appearance.cornerRadius - 4, 0))
                            .strokeBorder(styles.resting.borderColor?.color ?? appearance.accent, lineWidth: styles.resting.borderWidth ?? 1)
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
                .buttonStyle(.plain)
                .onHover { hoveredWorkspace = $0 ? workspace.name : nil }
                .animation(hoverAnimation(hovered, reduceMotion: reduceMotion), value: hovered)
            }
            if let error = workspaceStore.error {
                Image(systemName: "exclamationmark.triangle").padding(padding).help(error)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .animation(reduceMotion ? nil : animation.value, value: workspaces)
    }

    @ViewBuilder private func appIcon(_ app: WorkspaceApp, style: WidgetStyle) -> some View {
        if let glyphs = configuration?.appGlyphs, let text = appGlyph(for: app, in: glyphs) {
            Text(text)
                .font(WidgetAppearance(style, defaults: WidgetStyle()).font)
                .foregroundStyle(style.foreground?.color ?? appearance.foreground)
        } else if let image = appIcons.image(for: app.bundleID,
                                             size: NSSize(width: style.width ?? 14, height: style.height ?? 14),
                                             scale: displayScale) {
            Image(nsImage: image)
                .renderingMode(.original)
                .resizable()
                .interpolation(.high)
                .frame(width: style.width ?? 14, height: style.height ?? 14)
        }
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
    let requestAccess: () -> Void
    var expansionChanged: (Bool) -> Void = { _ in }
    @State private var hoveredItem: AppMenuItem?
    @State private var openTitle: Int?
    @State private var anchors: [Int: NSView] = [:]

    var body: some View {
        HStack(spacing: 0) {
            if !appMenu.isTrusted {
                Button(action: requestAccess) {
                    Image(systemName: "exclamationmark.triangle").padding(padding).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Allow StableBar in Privacy & Security → Accessibility to show the app's menus. Click to ask for access; later clicks open System Settings.")
            }
            ForEach(Array(items.prefix(expandOnHover && !expanded ? 1 : items.count).enumerated()), id: \.offset) { index, item in
                AppMenuTitle(item: item, index: index, isAppleMenu: isAppleMenu, appearance: appearance, padding: padding,
                             highlighted: openTitle.map { $0 == index } ?? (hoveredItem == item), anchors: $anchors) {
                    appMenu.open(index, of: items, at: items.indices.map { anchors[$0]! }) { openTitle = $0 }
                    openTitle = nil
                }
                .onHover { hoveredItem = $0 ? item : nil }
                .transition(.opacity)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .clipped()
        .onHover { if $0 { appMenu.refresh() } }
        .onChange(of: hovering || openTitle != nil, initial: true) { _, expanded in expansionChanged(expanded) }
        .onDisappear { expansionChanged(false) }
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
            .padding(.horizontal, 7)
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

private struct MenuAnchor: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

func appGlyph(for app: WorkspaceApp, in glyphs: [String: String]) -> String? {
    if let glyph = glyphs[app.bundleID] ?? glyphs[app.name] { return glyph }
    return glyphs.filter { $0.key.hasSuffix("*") && app.name.hasPrefix($0.key.dropLast()) }.max { $0.key.count < $1.key.count }?.value
}
