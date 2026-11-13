import SwiftUI

/// Edit mode lays the bar out with the bar's own planner, each position in a zone that ends in its + slot. A side too
/// crowded for its widgets scrolls instead of moving any to More widgets. Starting to edit draws every widget where
/// it was, then opens the + slots.
struct BarEditView: View {
    let store: BarStore
    let display: BarDisplay
    /// Each unit's width, from the measuring copy.
    @State private var widths: [String: CGFloat]
    /// How far each crowded side has scrolled its widgets to the left, by the side's first position.
    @State private var shifts: [WidgetPosition: CGFloat] = [:]
    /// False until the bar is on screen, so the + slots open when editing starts.
    @State private var opened = false
    /// An arrow's scroll in progress. SwiftUI doesn't animate where the tiles' drag views sit, so it steps itself.
    @State private var glide: Task<Void, Never>?
    @State private var anchors = Dictionary(uniqueKeysWithValues: WidgetPosition.allCases.map { ($0, NSView()) })
    @State private var zoneAnchors = Dictionary(uniqueKeysWithValues: WidgetPosition.allCases.map { ($0, NSView()) })
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    private static let slot: CGFloat = 22
    private static let arrow: CGFloat = 24

    init(store: BarStore, display: BarDisplay, widths: [String: CGFloat]) {
        self.store = store
        self.display = display
        _widths = State(initialValue: widths)
    }

    var body: some View {
        if let config = store.configuration?.onScreen(ScreenKind(display)) {
            let editing = store.barEditing
            let entries = editing.entries(on: display)
            let scale = CGFloat(config.bar.scale(for: display))
            // A dragged widget is arranged in the position it would land in, before the configuration says so.
            let units = BarUnit.make(widgets: WidgetPosition.allCases.flatMap { position in
                editing.arranged(entries, on: display.id, position: position).map { entry in
                    var widget = entry.widget
                    widget.position = position
                    return widget
                }
            }, groups: config.groups)
            let dragging = editing.dragSession.active != nil
            let named = dragging && editing.insertion?.displayID == display.id ? editing.insertion?.position : nil
            let surface = BarEditSurface(barStyle: store.barStyle(on: ScreenKind(display)), look: BarEditLook(config), colorScheme: colorScheme)
            GeometryReader { proxy in
                let height = proxy.size.height / scale
                let layout = layout(units: units, width: proxy.size.width / scale, height: height, config: config)
                BarEditDropTarget(editing: editing, displayID: display.id, spans: layout.spans,
                                  frames: Dictionary(uniqueKeysWithValues: units.flatMap { unit in
                                      unit.widgets.map { ($0.id, layout.frames[unit.id]!) }
                                  }),
                                  scrolling: layout.scrolling, scroll: { scroll($0, by: $1, animated: false) }) {
                    ZStack(alignment: .topLeading) {
                        // Catches drags over a see-through bar too, which macOS otherwise passes to the windows below.
                        Color.black.opacity(0.01)
                        ForEach(WidgetPosition.allCases, id: \.self) { position in
                            let span = layout.spans[position]!
                            let target = dragging && editing.insertion?.displayID == display.id && editing.insertion?.position == position
                            let shape = RoundedRectangle(cornerRadius: 8)
                            shape.fill(.ultraThinMaterial)
                                .overlay { shape.fill(target ? Color.accentColor.opacity(0.16) : .clear) }
                                .overlay { shape.strokeBorder(target ? Color.accentColor : surface.ink.opacity(0.18), lineWidth: target ? 1.5 : 0.5) }
                                .environment(\.colorScheme, surface.scheme)
                                .frame(width: span.upperBound - span.lowerBound + 8, height: height - 4)
                                .background { BarEditAddAnchor(view: zoneAnchors[position]!) }
                                .modifier(BarEditClip(side: layout.sides[position]!, x: span.lowerBound - 4, height: height))
                                .help(position.title)
                                .offset(x: span.lowerBound - 4, y: 2)
                                .accessibilityHidden(true)
                        }
                        ForEach(units) { unit in
                            let frame = layout.frames[unit.id]!
                            let lifted = editing.opacity(for: unit.widgets[0].id) == 0
                            let shape = RoundedRectangle(cornerRadius: 6)
                            ZStack {
                                // Where the dragged widget lands.
                                shape.fill(Color.accentColor.opacity(0.22))
                                    .overlay { shape.strokeBorder(Color.accentColor, lineWidth: 1.5) }
                                    .frame(width: frame.width, height: Self.slot)
                                    .opacity(lifted ? 1 : 0)
                                BarUnitSurface(style: unit.style ?? WidgetStyle(), defaults: config.defaults, spacing: config.bar.spacing) {
                                    ForEach(unit.widgets) { widget in
                                        BarEditTile(store: store, display: display.id, kind: ScreenKind(display),
                                                    entry: entries.first { $0.id == widget.id }!, config: config)
                                    }
                                }
                                .fixedSize()
                                // A widget not measured yet grows in from nothing.
                                .scaleEffect(widths[unit.id] == nil ? 0 : 1)
                                .opacity(lifted ? 0 : 1)
                            }
                            .frame(width: frame.width, height: height)
                            .modifier(BarEditClip(side: layout.sides[unit.position]!, x: frame.minX, height: height))
                            .allowsHitTesting(layout.sides[unit.position]!.span.overlaps(frame.minX...frame.maxX))
                            .offset(x: frame.minX)
                        }
                        ForEach(WidgetPosition.allCases, id: \.self) { position in
                            let frame = layout.frames[Self.addID(position)]!
                            addButton(position, ink: surface.ink, shown: opened && !dragging)
                                .frame(width: frame.width, height: height)
                                .modifier(BarEditClip(side: layout.sides[position]!, x: frame.minX, height: height))
                                .offset(x: frame.minX)
                        }
                        ForEach(layout.scrolling, id: \.id) { side in
                            let page = 0.7 * (side.visible.upperBound - side.visible.lowerBound)
                            if side.fadesLeading {
                                arrow(leading: true, ink: surface.ink) { scroll(side, by: -page, animated: true) }
                                    .frame(height: height)
                                    .offset(x: side.visible.lowerBound + 2)
                            }
                            if side.fadesTrailing {
                                arrow(leading: false, ink: surface.ink) { scroll(side, by: page, animated: true) }
                                    .frame(height: height)
                                    .offset(x: side.visible.upperBound - Self.arrow - 2)
                            }
                        }
                    }
                    // The drop target hosts its content in a view of its own, which the transactions of this one don't
                    // reach, so its animations follow values instead.
                    .animation(reduceMotion ? nil : .reorder, value: units.map { [$0.position.rawValue, $0.id] })
                    .animation(reduceMotion ? nil : .reorder, value: opened)
                    // A widget the bar didn't show, or one just added, slides in.
                    .animation(reduceMotion ? nil : .reorder, value: Set(widths.keys))
                }
                .overlay {
                    HStack(spacing: 0) {
                        ForEach(units) { unit in
                            BarUnitSurface(style: unit.style ?? WidgetStyle(), defaults: config.defaults, spacing: config.bar.spacing) {
                                ForEach(unit.widgets) { widget in
                                    BarEditTile(store: store, display: display.id, kind: ScreenKind(display),
                                                entry: entries.first { $0.id == widget.id }!, config: config)
                                }
                            }
                            .fixedSize()
                            .background {
                                GeometryReader { measurement in
                                    Color.clear.preference(key: BarEditWidths.self, value: [unit.id: measurement.size.width])
                                }
                            }
                        }
                    }
                    .fixedSize().hidden().allowsHitTesting(false).accessibilityHidden(true)
                    .modifier(MeasuringCopy())
                }
                .onPreferenceChange(BarEditWidths.self) { widths = $0 }
                .frame(width: proxy.size.width / scale, height: height, alignment: .topLeading)
                .scaleEffect(scale, anchor: .topLeading)
            }
            .modifier(BarSurface(store: store, settings: config.bar, kind: ScreenKind(display)))
            .padding(config.bar.margin)
            .frame(height: config.barGeometry(for: display).layoutHeight)
            .onAppear { opened = true }
            // macOS shows no tooltips during a drag, so the zone under a dragged widget names itself.
            .onChange(of: named) { _, position in
                guard let position, let widget = config.widgets.first(where: { $0.id == editing.dragSession.active?.widgetID }) else {
                    store.popup.close()
                    return
                }
                store.popup.showTooltip(position.title, widget: widget, defaults: config.popupDefaults.inheriting(config.defaults),
                                        store: store, anchor: zoneAnchors[position]!)
            }
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
        }
    }

    private static func addID(_ position: WidgetPosition) -> String { "add:\(position.rawValue)" }

    /// Where the edit bar draws each unit and + slot, and the span of each position, after a crowded side's scroll.
    private struct Layout {
        var frames: [String: CGRect] = [:]
        var spans: [WidgetPosition: ClosedRange<CGFloat>] = [:]
        /// The side of the bar each position is on.
        var sides: [WidgetPosition: BarEditSide] = [:]
        /// The sides too crowded for their widgets.
        var scrolling: [BarEditSide] = []
    }

    private func layout(units: [BarUnit], width: CGFloat, height: CGFloat, config: Configuration) -> Layout {
        // New widgets go where the + sits: first on the right and left of the notch, last elsewhere.
        let items = WidgetPosition.allCases.flatMap { position in
            let slot = BarLayoutItem(id: Self.addID(position), position: position, width: opened ? Self.slot : 0, canOverflow: false)
            let widgets = units.filter { $0.position == position }.map { unit in
                BarLayoutItem(id: unit.id, position: position, width: widths[unit.id] ?? 0, canOverflow: false, isSpacer: unit.isSpacer)
            }
            return [.right, .notchLeft].contains(position) ? [slot] + widgets : widgets + [slot]
        }
        let notch = config.bar.layoutNotch(on: display)
        let plan = AdaptiveBarPlanner(inset: config.bar.inset, spacing: config.bar.spacing, notchSpacing: config.bar.notchSpacing,
                                      notch: notch, scrolls: true, positionSpacing: 10)
            .plan(width: width, items: items)
        var layout = Layout()
        for segment in plan.segments {
            // A theme's notch spacing can reach into the notch, where nothing shows.
            let visible = notch.map { notch in
                segment.atEnd ? segment.span.lowerBound...min(segment.span.upperBound, notch.lowerBound)
                    : max(segment.span.lowerBound, notch.upperBound)...segment.span.upperBound
            } ?? segment.span
            // At rest, a side shows the end that its More widgets button would leave in place.
            let rest = segment.atEnd ? 0 : segment.overflow
            let side = BarEditSide(id: segment.positions[0], span: segment.span, visible: visible, overflow: segment.overflow,
                                   shift: min(max(shifts[segment.positions[0]] ?? rest, 0), segment.overflow))
            let shift = side.shift
            if side.scrolls { layout.scrolling.append(side) }
            for position in segment.positions {
                layout.sides[position] = side
                let frames = items.filter { $0.position == position }.map { item in
                    let placement = plan.placements[item.id]!
                    return CGRect(x: placement.x - shift, y: 0, width: placement.width, height: height)
                }
                for (item, frame) in zip(items.filter { $0.position == position }, frames) { layout.frames[item.id] = frame }
                layout.spans[position] = frames.map(\.minX).min()!...frames.map(\.maxX).max()!
            }
        }
        return layout
    }

    private func scroll(_ side: BarEditSide, by delta: CGFloat, animated: Bool) {
        glide?.cancel()
        let start = shifts[side.id] ?? side.shift
        let end = min(max(start + delta, 0), side.overflow)
        guard animated, !reduceMotion else { shifts[side.id] = end; return }
        glide = Task {
            let began = ContinuousClock.now
            while !Task.isCancelled {
                let progress = min((ContinuousClock.now - began) / .milliseconds(450), 1)
                shifts[side.id] = start + (end - start) * (1 - pow(1 - progress, 3))
                if progress == 1 { return }
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
    }

    private func addButton(_ position: WidgetPosition, ink: Color, shown: Bool) -> some View {
        let addPopover = store.barEditing.addPopover
        let adding = addPopover.displayID == display.id && addPopover.position == position
        return Button {
            addPopover.show(store: store, displayID: display.id, position: position, anchor: anchors[position]!)
        } label: {
            Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                .frame(width: Self.slot, height: Self.slot)
                .foregroundStyle(adding ? Color.white : ink)
                .background(adding ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5).strokeBorder(ink.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
        .background { BarEditAddAnchor(view: anchors[position]!) }
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .accessibilityHidden(!shown)
        .help("Add a widget to \(position.title)")
        .accessibilityLabel("Add a widget to \(position.title)")
    }

    private func arrow(leading: Bool, ink: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: leading ? "chevron.left" : "chevron.right").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ink)
                .frame(width: Self.arrow, height: Self.arrow)
                .background(.regularMaterial, in: Circle())
                .overlay { Circle().strokeBorder(ink.opacity(0.2), lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
        .help(leading ? "Show the widgets to the left" : "Show the widgets to the right")
        .accessibilityLabel(leading ? "Scroll left" : "Scroll right")
    }
}

/// The part of the bar on one side of the notch, or all of it, and how far a side too crowded for its widgets scrolls.
struct BarEditSide {
    /// The side's first position, which names it.
    let id: WidgetPosition
    /// Where its widgets go, as on the bar.
    let span: ClosedRange<CGFloat>
    /// The part of `span` clear of the notch, where a side that scrolls fades and shows its arrows.
    let visible: ClosedRange<CGFloat>
    let overflow: CGFloat
    /// How far its widgets have moved left.
    let shift: CGFloat
    var scrolls: Bool { overflow > 0 }
    var fadesLeading: Bool { shift > 0 }
    var fadesTrailing: Bool { shift < overflow }
}

/// Clips what a crowded side scrolls past its edges, which fade where more widgets lie beyond, clear under the arrow.
/// An edge with nothing beyond leaves `reach` for zones and − badges that overhang it.
private struct BarEditClip: ViewModifier {
    let side: BarEditSide
    /// Where the clipped view sits on the bar.
    let x: CGFloat
    let height: CGFloat
    private let reach: CGFloat = 6
    private let clear: CGFloat = 28
    private let fade: CGFloat = 72

    func body(content: Content) -> some View {
        let start = side.fadesLeading ? side.visible.lowerBound : side.span.lowerBound - reach
        let width = (side.fadesTrailing ? side.visible.upperBound : side.span.upperBound + reach) - start
        content.mask(alignment: .topLeading) {
            LinearGradient(stops: [
                .init(color: side.fadesLeading ? .clear : .black, location: 0),
                .init(color: side.fadesLeading ? .clear : .black, location: side.fadesLeading ? clear / width : 0),
                .init(color: .black, location: side.fadesLeading ? fade / width : 0),
                .init(color: .black, location: side.fadesTrailing ? 1 - fade / width : 1),
                .init(color: side.fadesTrailing ? .clear : .black, location: side.fadesTrailing ? 1 - clear / width : 1),
                .init(color: side.fadesTrailing ? .clear : .black, location: 1)
            ], startPoint: .leading, endPoint: .trailing)
            .frame(width: width, height: height + 2 * reach)
            .offset(x: start - x, y: -reach)
        }
    }
}

private struct BarEditWidths: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) { value.merge(nextValue()) { $1 } }
}

/// Edit marks follow the surface they sit on: a strip whose color is nearly opaque, or, on a see-through strip,
/// as tile themes such as Built-in leave it, the wallpaper that the widgets' own text color is made to read on.
private struct BarEditSurface {
    /// The shade of the surface.
    let scheme: ColorScheme
    /// Outlines and slots use the widgets' text color when it reads on that surface.
    let ink: Color

    init(barStyle: WidgetStyle, look: BarEditLook, colorScheme: ColorScheme) {
        let resolve = { (color: HexColor) in colorScheme == .dark ? color.dark : color.light }
        // The strip's color as `BarSurface` paints it. Themes design their text for it, Liquid Glass or not.
        let strip = resolve((barStyle.background ?? look.background).firstColor)
        // Widgets draw the text color in `defaults`, not the bar style's.
        let text = look.defaults.foreground.map(resolve)
        let scheme: ColorScheme = if Double(strip & 0xff) / 255 < 0.85 {
            text.map { isLightText($0) ? .dark : .light } ?? colorScheme
        } else {
            // On a strip above a relative luminance of about 0.18, black ink contrasts more than white.
            luminance(strip) > 0.18 ? .light : .dark
        }
        self.scheme = scheme
        ink = text.flatMap { isLightText($0) == (scheme == .dark) ? HexColor($0).color : nil }
            ?? (scheme == .dark ? Color.white : .black).opacity(0.85)
    }
}

/// Above a relative luminance of about 0.24, text contrasts more with a dark surface than a light one.
private func isLightText(_ rgba: UInt32) -> Bool { luminance(rgba) > 0.24 }

/// WCAG relative luminance of an RGBA color.
private func luminance(_ rgba: UInt32) -> Double {
    let channels = [24, 16, 8].map { shift in
        let value = Double((rgba >> UInt32(shift)) & 0xff) / 255
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
}

struct BarEditTile: View {
    let store: BarStore
    let display: Int
    let kind: ScreenKind
    let entry: BarEditWidget
    /// Only what the tile draws with, so it redraws only when that changes. SwiftUI counts a rebuilt
    /// `Configuration` as changed, and each redraw replaces the items of the tile's open context menu.
    let look: BarEditLook
    @Environment(\.measuringBarWidths) private var measuring
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    /// False until the tile is on screen, so its − badge pops in when editing starts.
    @State private var appeared = false
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
            let showsBadges = appeared && editing.dragSession.active == nil
            Button { editing.remove(entry.id, on: display) } label: {
                Image(systemName: "minus").font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white).frame(width: 12, height: 12)
                    .background(HexColor(0x6e6e73ff).color, in: Circle())
            }
            .buttonStyle(.plain)
            .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
            .help("Remove \(entry.name)")
            .accessibilityLabel("Remove \(entry.name)")
            .scaleEffect(showsBadges ? 1 : 0.4)
            // Stays inside a bar barely taller than its widgets, which clips what overhangs it.
            .offset(x: -4, y: -3)
            .opacity(showsBadges ? 1 : 0)
            .animation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0.3), value: showsBadges)
            .allowsHitTesting(showsBadges)
            .accessibilityHidden(!showsBadges)
        }
        .onAppear { appeared = true }
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
        let surface = BarEditSurface(barStyle: store.barStyle(on: kind), look: look, colorScheme: colorScheme)
        return Button { editing.select(entry.id) } label: {
            Group {
                if entry.usesPlaceholder {
                    Label(entry.name, systemImage: entry.visibility.isHidden ? "eye.slash" : entry.widget.content.symbol)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .padding(.horizontal, 6).frame(height: 22).frame(maxWidth: 140)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                        .environment(\.colorScheme, surface.scheme)
                } else {
                    // The widget itself stays still while editing: no hover looks, expansions or tooltips of its own.
                    WidgetView(widget: entry.widget, defaults: look.defaults, popupDefaults: look.popupDefaults,
                               store: store, monitor: display, defaultAnimation: look.animation,
                               defaultTransition: look.transition)
                        .accessibilityHidden(true).fixedSize()
                        .allowsHitTesting(false)
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

/// What the edit bar's tiles draw with from a screen's configuration.
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
