import SwiftUI

struct BarEditView: View {
    let store: BarStore
    let display: BarDisplay
    /// Each position's row as one line, from the measuring copy: what the layout gives room to.
    @State private var measuredSizes: [WidgetPosition: CGSize] = [:]
    /// Each tray's height at its width, once it has laid its widgets out on as many rows as they need.
    @State private var trayHeights: [WidgetPosition: CGFloat] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let config = store.configuration?.onScreen(ScreenKind(display)), let geometry = store.barEditing.geometry(for: display) {
            let entries = store.barEditing.entries(on: display)
            let scale = CGFloat(config.bar.scale(for: display))
            // Trays sit centered on the bar's line, as they do on one row; a tray that wraps grows down from there,
            // and the bar grows to the bottom of the lowest tray.
            let line: CGFloat = max(config.bar.height * scale - 2 * config.bar.margin,
                                    (measuredSizes.values.map(\.height).max() ?? 0) * scale) / scale
            let tops = Dictionary(uniqueKeysWithValues: WidgetPosition.allCases.map { position in
                (position, max(0, (line - (measuredSizes[position]?.height ?? line)) / 2))
            })
            let heights = Dictionary(uniqueKeysWithValues: WidgetPosition.allCases.map { position -> (WidgetPosition, CGFloat) in
                (position, max(trayHeights[position] ?? 0, measuredSizes[position]?.height ?? line))
            })
            let bottom = WidgetPosition.allCases.map { tops[$0]! + heights[$0]! }.max() ?? 0
            GeometryReader { proxy in
                let widths = measuredSizes.mapValues { $0.width * scale }
                let layout = BarEditLayout(width: proxy.size.width, display: display, bar: config.bar, preferredWidths: widths)
                ZStack(alignment: .topLeading) {
                    ForEach(WidgetPosition.allCases, id: \.self) { position in
                        if let section = layout.sections[position] {
                            BarEditSection(store: store, display: display, position: position, entries: entries, config: config,
                                           adding: store.barEditing.addPopover.displayID == display.id
                                               && store.barEditing.addPopover.position == position) { trayHeights[position] = $0 }
                            .frame(width: section.width / scale, height: heights[position]!)
                            .offset(x: section.x / scale, y: tops[position]!)
                        }
                    }
                }
                .animation(reduceMotion || store.barEditing.dragSession.active == nil ? nil : .reorder, value: measuredSizes)
                .overlay {
                    HStack(spacing: 0) {
                        ForEach(WidgetPosition.allCases, id: \.self) { position in
                            BarEditSectionRow(store: store, display: display, position: position, entries: entries, config: config,
                                              adding: false)
                            .fixedSize()
                            .background {
                                GeometryReader { measurement in
                                    Color.clear.preference(key: BarEditSizes.self, value: [position: measurement.size])
                                }
                            }
                        }
                    }
                    .fixedSize().hidden().allowsHitTesting(false).accessibilityHidden(true)
                    .modifier(MeasuringCopy())
                }
                .onPreferenceChange(BarEditSizes.self) { measuredSizes = $0 }
                .frame(width: proxy.size.width / scale, height: proxy.size.height / scale, alignment: .topLeading)
                .scaleEffect(scale, anchor: .topLeading)
            }
            .modifier(BarSurface(store: store, settings: config.bar, kind: ScreenKind(display)))
            .padding(config.bar.margin)
            .frame(height: geometry.layoutHeight)
            .alert("Couldn’t change widget", isPresented: Binding(get: {
                store.barEditing.error != nil && store.barEditing.errorDisplayID == display.id
            }, set: {
                if !$0 { store.barEditing.error = nil }
            })) {
                Button("OK") { store.barEditing.error = nil }
            } message: { Text(store.barEditing.error ?? "") }
            .onChange(of: Set(entries.map(\.id)), initial: true) { _, ids in
                store.setVisibleWidgets(ids: ids, displayID: display.id)
            }
            .onChange(of: bottom * scale, initial: true) { _, height in
                store.barEditing.measure(height: height, on: display.id)
            }
        }
    }
}

private struct BarEditSizes: PreferenceKey {
    static let defaultValue: [WidgetPosition: CGSize] = [:]
    static func reduce(value: inout [WidgetPosition: CGSize], nextValue: () -> [WidgetPosition: CGSize]) { value.merge(nextValue()) { $1 } }
}

private struct BarEditFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}

private struct BarEditAddSlotFrame: PreferenceKey {
    static let defaultValue = CGRect.null
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = value.union(nextValue()) }
}

private struct BarEditRowHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct BarEditSection: View {
    let store: BarStore
    let display: BarDisplay
    let position: WidgetPosition
    let entries: [BarEditWidget]
    let config: Configuration
    let adding: Bool
    /// Reports the tray's height at the width it was given.
    let measured: (CGFloat) -> Void
    @State private var frames: [String: CGRect] = [:]
    @State private var addSlot = CGRect.null
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var editing: BarEditing { store.barEditing }

    var body: some View {
        let state = editing.trayState(on: display.id, position: position)
        let surface = BarEditTraySurface(barStyle: store.barStyle(on: ScreenKind(display)), look: BarEditLook(config), colorScheme: colorScheme)
        let shape = RoundedRectangle(cornerRadius: 9)
        BarEditDropTarget(editing: editing, displayID: display.id, position: position, frames: frames, addSlot: addSlot) {
            BarEditSectionRow(store: store, display: display, position: position, entries: entries, config: config,
                              adding: adding)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: BarEditRowHeight.self, value: proxy.size.height)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
                .background(surface.tint, in: shape)
                .background(state.isTarget ? Color.accentColor.opacity(0.16) : .clear, in: shape)
                .background(surface.backing, in: shape)
                .overlay {
                    shape.strokeBorder(state.isTarget ? Color.accentColor : surface.hairline, lineWidth: state.isTarget ? 2 : 0.5)
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: state.isTarget)
                .coordinateSpace(name: "editSection")
                .onPreferenceChange(BarEditFrames.self) { frames = $0 }
                .onPreferenceChange(BarEditAddSlotFrame.self) { addSlot = $0 }
                .onPreferenceChange(BarEditRowHeight.self) { if $0 > 0 { measured($0) } }
        }
        .overlay(alignment: .topLeading) {
            Text(position.title).font(.system(size: 9, weight: .bold)).lineLimit(1)
                .foregroundStyle(state.isTarget ? Color.white : Color.primary)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(state.isTarget ? Color.accentColor : surface.tint, in: Capsule())
                .background(.regularMaterial, in: Capsule())
                .overlay { Capsule().strokeBorder(surface.neutral.opacity(0.15), lineWidth: 0.5) }
                .environment(\.colorScheme, surface.scheme)
                .padding(.leading, 5)
                .opacity(state.showsName ? 1 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: state.showsName)
                .allowsHitTesting(false)
                .accessibilityHidden(!state.showsName)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(position.title)
    }
}

/// Trays and their chrome follow the surface they sit on. A tray tints the theme's strip when the
/// strip's color is nearly opaque. A see-through strip, as tile themes such as Built-in leave it, would
/// put trays on the wallpaper, so each tray brings a backing that the widgets' text reads on.
private struct BarEditTraySurface {
    let isOwn: Bool
    /// The shade of the tray's surface: the strip's, or its own backing's.
    let scheme: ColorScheme
    /// Outlines and + use the widgets' text color when it reads on that surface.
    let ink: Color

    init(barStyle: WidgetStyle, look: BarEditLook, colorScheme: ColorScheme) {
        let resolve = { (color: HexColor) in colorScheme == .dark ? color.dark : color.light }
        // The strip's color as `BarSurface` paints it. Themes design their text for it, Liquid Glass or not.
        let strip = resolve((barStyle.background ?? look.background).firstColor)
        // Widgets draw the text color in `defaults`, not the bar style's.
        let text = look.defaults.foreground.map(resolve)
        isOwn = Double(strip & 0xff) / 255 < 0.85
        let scheme: ColorScheme = if isOwn {
            text.map { isLightText($0) ? .dark : .light } ?? colorScheme
        } else {
            // On a strip above a relative luminance of about 0.18, black ink contrasts more than white.
            luminance(strip) > 0.18 ? .light : .dark
        }
        self.scheme = scheme
        ink = text.flatMap { isLightText($0) == (scheme == .dark) ? HexColor($0).color : nil }
            ?? (scheme == .dark ? Color.white : .black).opacity(0.85)
    }

    var neutral: Color { scheme == .dark ? .white : .black }
    var tint: Color { neutral.opacity(scheme == .dark ? 0.07 : 0.05) }
    var hairline: Color { neutral.opacity(scheme == .dark ? 0.10 : 0.08) }
    var backing: Color { isOwn ? Color(white: scheme == .dark ? 0.17 : 0.97) : .clear }
}

/// Above a relative luminance of about 0.24, text contrasts more with the dark tray backing than the light one.
private func isLightText(_ rgba: UInt32) -> Bool { luminance(rgba) > 0.24 }

/// WCAG relative luminance of an RGBA color.
private func luminance(_ rgba: UInt32) -> Double {
    let channels = [24, 16, 8].map { shift in
        let value = Double((rgba >> UInt32(shift)) & 0xff) / 255
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
}

struct BarEditSectionRow: View {
    let store: BarStore
    let display: BarDisplay
    let position: WidgetPosition
    let entries: [BarEditWidget]
    let config: Configuration
    let adding: Bool
    @State private var anchor = NSView()
    /// How wide the rows are, and each unit's own width: a unit wider than its row scrolls sideways in it.
    @State private var rowWidth = CGFloat.infinity
    @State private var unitWidths: [String: CGFloat] = [:]
    @Environment(\.measuringBarWidths) private var measuring
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let editing = store.barEditing
        let leadingSlot = position == .right || position == .notchLeft
        BarEditFlow(rowSpacing: BarEditTrayMetrics.rowSpacing) {
            if leadingSlot { addSlot }
            let units = BarUnit.make(widgets: editing.arranged(entries, on: display.id, position: position).map(\.widget),
                                     groups: config.groups)
            ForEach(units) { unit in
                let collapsed = editing.isCollapsed(unit.widgets[0].id, on: display.id, position: position)
                BarUnitSurface(style: unit.style ?? WidgetStyle(), defaults: config.defaults, spacing: config.bar.spacing) {
                    ForEach(unit.widgets) { widget in
                        if let entry = entries.first(where: { $0.id == widget.id }) {
                            BarEditTile(store: store, display: display.id, kind: ScreenKind(display), entry: entry, config: config)
                                .background {
                                    GeometryReader { proxy in
                                        Color.clear.preference(key: BarEditFrames.self,
                                            value: [entry.id: proxy.frame(in: .named("editSection"))])
                                    }
                                }
                        }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { unitWidths[unit.id] = $0 }
                .modifier(SidewaysScroll(scrolls: unitWidths[unit.id, default: 0] + config.bar.spacing > rowWidth))
                .opacity(collapsed ? 0 : editing.opacity(for: unit.widgets[0].id))
                .frame(width: collapsed ? 0 : nil)
                .padding(leadingSlot ? .leading : .trailing, collapsed ? 0 : config.bar.spacing)
            }
            if !leadingSlot { addSlot }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
        .animation(reduceMotion ? nil : .reorder, value: editing.insertion)
        .frame(minHeight: BarEditTrayMetrics.slot)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, BarEditTrayMetrics.horizontalPadding)
        .padding(.vertical, BarEditTrayMetrics.verticalPadding)
    }

    private var addSlot: some View {
        let ink = BarEditTraySurface(barStyle: store.barStyle(on: ScreenKind(display)), look: BarEditLook(config), colorScheme: colorScheme).ink
        return Button {
            store.barEditing.addPopover.show(store: store, displayID: display.id, position: position, anchor: anchor)
        } label: {
            Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                .frame(width: BarEditTrayMetrics.slot, height: BarEditTrayMetrics.slot)
                .foregroundStyle(adding ? Color.white : ink)
                .background(adding ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5).strokeBorder(ink.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(store.barEditing.trayState(on: display.id, position: position).showsAddSlot ? 1 : 0)
        .allowsHitTesting(store.barEditing.trayState(on: display.id, position: position).showsAddSlot)
        .accessibilityHidden(!store.barEditing.trayState(on: display.id, position: position).showsAddSlot)
        .background {
            if !measuring {
                BarEditAddAnchor(view: anchor)
                GeometryReader { proxy in
                    Color.clear.preference(key: BarEditAddSlotFrame.self, value: proxy.frame(in: .named("editSection")))
                }
            }
        }
        .help("Add a widget to \(position.title)")
        .accessibilityLabel("Add a widget to \(position.title)")
    }
}

struct BarEditTile: View {
    let store: BarStore
    let display: Int
    let kind: ScreenKind
    let entry: BarEditWidget
    /// Not the whole `Configuration`: a screen with its own layout rebuilds it on every update, SwiftUI then
    /// redraws the tile, and the redraw replaces the items of its open context menu, closing an open submenu.
    let look: BarEditLook
    @Environment(\.measuringBarWidths) private var measuring
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    private var editing: BarEditing { store.barEditing }
    private var title: String { entry.name + (entry.visibility.isHidden ? ", Hidden" : "") }

    init(store: BarStore, display: Int, kind: ScreenKind, entry: BarEditWidget, config: Configuration) {
        self.store = store
        self.display = display
        self.kind = kind
        self.entry = entry
        look = BarEditLook(config)
    }

    var body: some View {
        Group {
            if measuring {
                tile
            } else {
                BarEditDragSource(editing: editing, widgetID: entry.id, name: entry.name, select: { editing.select(entry.id) }) {
                    tile
                }
            }
        }
        .fixedSize()
        .accessibilityAction(named: Text("Move left")) { editing.move(entry.id, by: -1, on: display) }
        .accessibilityAction(named: Text("Move right")) { editing.move(entry.id, by: 1, on: display) }
        .overlay(alignment: .topLeading) {
            let showsBadges = editing.trayState(on: display, position: entry.widget.position).showsBadges
            Button { editing.remove(entry.id, on: display) } label: {
                Image(systemName: "minus").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white).frame(width: 14, height: 14)
                    .background(HexColor(0x6e6e73ff).color, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Remove \(entry.name)")
            .accessibilityLabel("Remove \(entry.name)")
            .offset(x: -5, y: -5)
            .opacity(showsBadges ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: showsBadges)
            .allowsHitTesting(showsBadges)
            .accessibilityHidden(!showsBadges)
        }
        .help("\(title). Click to change its settings, or drag to move it.")
        .contextMenu {
            Button("Edit Widget…") { editing.select(entry.id) }
            Button("Move Left") { editing.move(entry.id, by: -1, on: display) }
            Button("Move Right") { editing.move(entry.id, by: 1, on: display) }
            Menu("Move To") {
                ForEach(WidgetPlacement.destinations, id: \.self) { position in
                    Button(position.menuTitle) { editing.move(entry.id, to: position, on: display) }
                }
            }
            if let screen = NSScreen.screens.map(BarDisplay.init).first(where: { $0.id == display }) {
                Menu("Shows On") {
                    WidgetScreensMenu(store: store, widget: entry.widget, screen: ScreenKind(screen)) { editing.set(entry.id, $0, on: display) }
                }
            }
            Button("Remove Widget") { editing.remove(entry.id, on: display) }
            Divider()
            Button(editing.menuTitle, action: editing.end)
        }
    }

    private var tile: some View {
        let surface = BarEditTraySurface(barStyle: store.barStyle(on: kind), look: look, colorScheme: colorScheme)
        return Button { editing.select(entry.id) } label: {
            Group {
                if entry.usesPlaceholder {
                    Label(entry.name, systemImage: entry.visibility.isHidden ? "eye.slash" : entry.widget.content.symbol)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .padding(.horizontal, 5).frame(minHeight: 22).frame(maxWidth: 120)
                        .environment(\.colorScheme, surface.scheme)
                } else {
                    WidgetView(widget: entry.widget, defaults: look.defaults, popupDefaults: look.popupDefaults,
                               store: store, monitor: display, defaultAnimation: look.animation,
                               defaultTransition: look.transition)
                        .accessibilityHidden(true).fixedSize()
                }
            }
            .background {
                RoundedRectangle(cornerRadius: 5).fill(surface.ink.opacity(hovering ? 0.08 : 0)).padding(-2)
            }
            .animation(reduceMotion || hovering ? nil : .easeOut(duration: 0.1), value: hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("Edit \(title)")
    }
}

/// What the edit bar's tiles and trays draw with from a screen's configuration.
struct BarEditLook: Equatable {
    let defaults: WidgetStyle
    let popupDefaults: WidgetStyle
    let background: BackgroundFill
    let animation: WidgetAnimation
    let transition: WidgetTransition

    init(_ config: Configuration) {
        defaults = config.defaults
        popupDefaults = config.popupDefaults
        background = config.bar.background
        animation = config.bar.animation
        transition = config.bar.motion.transition
    }
}

private extension Animation {
    static let reorder = Animation.spring(duration: 0.3, bounce: 0.15)
}

/// Scrolls a unit wider than its row sideways, unclipped so the − badges that overhang the tiles' corners still show.
private struct SidewaysScroll: ViewModifier {
    let scrolls: Bool

    func body(content: Content) -> some View {
        if scrolls {
            ScrollView(.horizontal) { content }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
        } else {
            content
        }
    }
}
