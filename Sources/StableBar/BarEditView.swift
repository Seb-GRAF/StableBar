import SwiftUI

struct BarEditView: View {
    let store: BarStore
    let display: BarDisplay
    @State private var measuredSizes: [WidgetPosition: CGSize] = [:]

    var body: some View {
        if let config = store.configuration, let geometry = store.barEditing.geometry(for: display) {
            let entries = store.barEditing.entries(on: display)
            let scale = CGFloat(config.bar.scale(for: display))
            GeometryReader { proxy in
                let widths = measuredSizes.mapValues { $0.width * scale }
                let layout = BarEditLayout(width: proxy.size.width, display: display, bar: config.bar, preferredWidths: widths,
                                           isDragging: store.barEditing.dragSession.active != nil)
                ZStack(alignment: .topLeading) {
                    ForEach(WidgetPosition.allCases, id: \.self) { position in
                        if let section = layout.sections[position] {
                            let height = min(proxy.size.height / scale, measuredSizes[position]?.height ?? proxy.size.height / scale)
                            BarEditSection(store: store, display: display, position: position,
                                           entries: entries.filter { $0.widget.position == position }, config: config,
                                           scrolling: layout.scrolling.contains(position),
                                           contentWidth: measuredSizes[position]?.width ?? 0, viewportWidth: section.width / scale,
                                           adding: store.barEditing.addPopover.displayID == display.id
                                               && store.barEditing.addPopover.position == position)
                            .frame(width: section.width / scale, height: height)
                            .offset(x: section.x / scale, y: (proxy.size.height / scale - height) / 2)
                        }
                    }
                }
                .overlay {
                    HStack(spacing: 0) {
                        ForEach(WidgetPosition.allCases, id: \.self) { position in
                            BarEditSectionRow(store: store, display: display, position: position,
                                              entries: entries.filter { $0.widget.position == position }, config: config,
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
            .modifier(BarSurface(store: store, settings: config.bar))
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
            .onChange(of: (measuredSizes.values.map(\.height).max() ?? 0) * scale, initial: true) { _, height in
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

private struct BarEditRowBounds: PreferenceKey {
    static let defaultValue = CGRect.null
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

private struct BarEditSection: View {
    let store: BarStore
    let display: BarDisplay
    let position: WidgetPosition
    let entries: [BarEditWidget]
    let config: Configuration
    let scrolling: Bool
    let contentWidth: CGFloat
    let viewportWidth: CGFloat
    let adding: Bool
    @State private var frames: [String: CGRect] = [:]
    @State private var rowBounds = CGRect.null
    @Environment(\.colorScheme) private var colorScheme
    private var editing: BarEditing { store.barEditing }

    var body: some View {
        let state = editing.trayState(on: display.id, position: position)
        let overflow = BarEditOverflow(bounds: rowBounds, viewportWidth: viewportWidth)
        let surface = BarEditTraySurface(store: store, config: config, colorScheme: colorScheme)
        let shape = RoundedRectangle(cornerRadius: 9)
        BarEditDropTarget(editing: editing, displayID: display.id, position: position, frames: frames) {
            ScrollView(.horizontal) {
                BarEditSectionRow(store: store, display: display, position: position, entries: entries, config: config,
                                  adding: adding)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: BarEditRowBounds.self, value: proxy.frame(in: .named("editSection")))
                        }
                    }
                    .overlay { BarEditScrollWheel(contentWidth: contentWidth, viewportWidth: viewportWidth).allowsHitTesting(scrolling) }
            }
            .scrollIndicators(.hidden)
            .scrollDisabled(!scrolling)
            .mask {
                HStack(spacing: 0) {
                    if overflow.leading {
                        LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 18)
                    }
                    Rectangle().fill(.black)
                    if overflow.trailing {
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 18)
                    }
                }
            }
            .overlay {
                HStack {
                    if overflow.leading { overflowEdge(.leading) }
                    Spacer(minLength: 0)
                    if overflow.trailing { overflowEdge(.trailing) }
                }
                .environment(\.colorScheme, surface.scheme)
                .allowsHitTesting(false)
            }
            .help(scrolling ? "Scroll to see more widgets. Use the mouse wheel or swipe sideways." : "")
            .background(surface.tint, in: shape)
            .background(state.isTarget ? Color.accentColor.opacity(0.16) : .clear, in: shape)
            .background(surface.backing, in: shape)
            .overlay {
                shape.strokeBorder(state.isTarget ? Color.accentColor : surface.hairline, lineWidth: state.isTarget ? 2 : 0.5)
            }
            .overlay(alignment: .topLeading) {
                if state.isTarget, let target = editing.insertion {
                    let bounds = frames.values.reduce(CGRect.null) { $0.union($1) }
                    Rectangle().fill(Color.accentColor).frame(width: 3, height: bounds.isNull ? 22 : bounds.height)
                        .offset(x: target.x, y: bounds.isNull ? 6 : bounds.minY).allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: "editSection")
            .onPreferenceChange(BarEditFrames.self) { frames = $0 }
            .onPreferenceChange(BarEditRowBounds.self) { rowBounds = $0 }
        }
        .overlay(alignment: .topLeading) {
            if state.showsName {
                Text(position.title).font(.system(size: 9, weight: .bold)).lineLimit(1)
                    .foregroundStyle(state.isTarget ? Color.white : Color.primary)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(state.isTarget ? Color.accentColor : surface.tint, in: Capsule())
                    .background(.regularMaterial, in: Capsule())
                    .overlay { Capsule().strokeBorder(surface.neutral.opacity(0.15), lineWidth: 0.5) }
                    .environment(\.colorScheme, surface.scheme)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(position.title)
    }

    private func overflowEdge(_ edge: HorizontalEdge) -> some View {
        Image(systemName: edge == .leading ? "chevron.left" : "chevron.right")
            .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            .frame(width: 18)
            .accessibilityHidden(true)
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

    @MainActor init(store: BarStore, config: Configuration, colorScheme: ColorScheme) {
        let resolve = { (color: HexColor) in colorScheme == .dark ? color.dark : color.light }
        // The strip's color as `BarSurface` paints it. Themes design their text for it, Liquid Glass or not.
        let strip = resolve(store.barStyle.background ?? config.bar.background)
        // Widgets draw the text color in `defaults`, not the bar style's.
        let text = config.defaults.foreground.map(resolve)
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
    @Environment(\.measuringBarWidths) private var measuring
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: config.bar.spacing) {
            if position == .right || position == .notchLeft { addSlot }
            let units = BarUnit.make(widgets: entries.map(\.widget), groups: config.groups)
            ForEach(units) { unit in
                BarUnitSurface(style: unit.style ?? WidgetStyle(), spacing: config.bar.spacing) {
                    ForEach(unit.widgets) { widget in
                        if let entry = entries.first(where: { $0.id == widget.id }) {
                            BarEditTile(store: store, display: display.id, entry: entry, config: config)
                                .background {
                                    GeometryReader { proxy in
                                        Color.clear.preference(key: BarEditFrames.self,
                                            value: [entry.id: proxy.frame(in: .named("editSection"))])
                                    }
                                }
                        }
                    }
                }
                .opacity(store.barEditing.opacity(for: unit.widgets[0].id))
            }
            if position != .right && position != .notchLeft { addSlot }
        }
        .frame(minHeight: BarEditTrayMetrics.slot)
        .fixedSize()
        .padding(.horizontal, BarEditTrayMetrics.horizontalPadding)
        .padding(.vertical, BarEditTrayMetrics.verticalPadding)
    }

    private var addSlot: some View {
        let ink = BarEditTraySurface(store: store, config: config, colorScheme: colorScheme).ink
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
        .background { if !measuring { BarEditAddAnchor(view: anchor) } }
        .help("Add a widget to \(position.title)")
        .accessibilityLabel("Add a widget to \(position.title)")
    }
}

struct BarEditTile: View {
    let store: BarStore
    let display: Int
    let entry: BarEditWidget
    let config: Configuration
    @Environment(\.measuringBarWidths) private var measuring
    @Environment(\.colorScheme) private var colorScheme
    private var editing: BarEditing { store.barEditing }
    private var title: String { entry.name + (entry.visibility.isHidden ? ", Hidden" : "") }

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
            if editing.trayState(on: display, position: entry.widget.position).showsBadges {
                Button { editing.remove(entry.id, on: display) } label: {
                    Image(systemName: "minus").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white).frame(width: 14, height: 14)
                        .background(HexColor(0x6e6e73ff).color, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Remove \(entry.name)")
                .accessibilityLabel("Remove \(entry.name)")
                .offset(x: -5, y: -5)
            }
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
            Button("Remove Widget") { editing.remove(entry.id, on: display) }
            Divider()
            Button(editing.menuTitle, action: editing.end)
        }
    }

    private var tile: some View {
        let surface = BarEditTraySurface(store: store, config: config, colorScheme: colorScheme)
        return Button { editing.select(entry.id) } label: {
            Group {
                if entry.usesPlaceholder {
                    Label(entry.name, systemImage: entry.visibility.isHidden ? "eye.slash" : entry.widget.content.symbol)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .padding(.horizontal, 5).frame(minHeight: 22).frame(maxWidth: 120)
                        .environment(\.colorScheme, surface.scheme)
                } else {
                    WidgetView(widget: entry.widget, defaults: config.defaults, popupDefaults: config.popupDefaults,
                               store: store, monitor: display, animationDuration: config.bar.animationDuration)
                        .allowsHitTesting(false).accessibilityHidden(true).fixedSize()
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(surface.ink.opacity(0.58), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                    .padding(-2)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Edit \(title)")
    }
}
