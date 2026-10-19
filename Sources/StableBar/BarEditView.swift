import SwiftUI

struct BarEditView: View {
    let store: BarStore
    let display: BarDisplay
    @State private var setup: WidgetSetup
    @State private var adding = false
    @State private var addPosition = WidgetPosition.right
    @State private var measuredSizes: [WidgetPosition: CGSize] = [:]
    @State private var measuredContentWidths: [WidgetPosition: CGFloat] = [:]

    init(store: BarStore, display: BarDisplay) {
        self.store = store
        self.display = display
        _setup = State(initialValue: WidgetSetup(store: store))
    }

    var body: some View {
        if let config = store.configuration, let geometry = store.barEditing.geometry(for: display) {
            let entries = store.barEditing.entries(on: display)
            let scale = CGFloat(config.bar.scale(for: display))
            GeometryReader { proxy in
                let widths = measuredSizes.mapValues { $0.width * scale }
                let layout = BarEditLayout(width: proxy.size.width, display: display, bar: config.bar, preferredWidths: widths,
                                           contentWidths: measuredContentWidths.mapValues { $0 * scale })
                ZStack(alignment: .topLeading) {
                    ForEach(WidgetPosition.allCases, id: \.self) { position in
                        if let section = layout.sections[position] {
                            BarEditSection(store: store, display: display, position: position,
                                           entries: entries.filter { $0.widget.position == position }, config: config,
                                           scrolling: layout.scrolling.contains(position),
                                           contentWidth: measuredContentWidths[position] ?? 0, viewportWidth: section.width / scale) {
                                addPosition = position
                                adding = true
                            }
                            .frame(width: section.width / scale, height: proxy.size.height / scale)
                            .offset(x: section.x / scale)
                        }
                    }
                }
                .overlay {
                    HStack(spacing: 0) {
                        ForEach(WidgetPosition.allCases, id: \.self) { position in
                            VStack(spacing: 3) {
                                BarEditSectionHeader(position: position, add: {})
                                BarEditSectionRow(store: store, display: display.id,
                                                  entries: entries.filter { $0.widget.position == position }, config: config)
                                    .background {
                                        GeometryReader { measurement in
                                            Color.clear.preference(key: BarEditContentWidths.self, value: [position: measurement.size.width])
                                        }
                                    }
                            }
                            .padding(.vertical, 6)
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
                .onPreferenceChange(BarEditContentWidths.self) { measuredContentWidths = $0 }
                .frame(width: proxy.size.width / scale, height: proxy.size.height / scale, alignment: .topLeading)
                .scaleEffect(scale, anchor: .topLeading)
            }
            .padding(config.bar.margin)
            .frame(height: geometry.layoutHeight)
            .background(.regularMaterial)
            .sheet(isPresented: $adding) {
                WidgetAddView(setup: setup, store: store, position: addPosition) { id in
                    adding = false
                    if store.customizationHistory.notice != nil { store.barEditing.select(id) }
                }
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

private struct BarEditContentWidths: PreferenceKey {
    static let defaultValue: [WidgetPosition: CGFloat] = [:]
    static func reduce(value: inout [WidgetPosition: CGFloat], nextValue: () -> [WidgetPosition: CGFloat]) { value.merge(nextValue()) { $1 } }
}

private struct BarEditFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
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
    let add: () -> Void
    @State private var frames: [String: CGRect] = [:]
    private var editing: BarEditing { store.barEditing }

    var body: some View {
        BarEditDropTarget(editing: editing, displayID: display.id, position: position, frames: frames) {
            VStack(spacing: 3) {
                BarEditSectionHeader(position: position, add: add)
                ScrollView(.horizontal) {
                    BarEditSectionRow(store: store, display: display.id, entries: entries, config: config)
                        .overlay { BarEditScrollWheel(contentWidth: contentWidth, viewportWidth: viewportWidth).allowsHitTesting(scrolling) }
                }
                .scrollIndicators(.hidden)
                .scrollDisabled(!scrolling)
                .overlay(alignment: .leading) {
                    let overflow = BarEditOverflow(bounds: frames.values.reduce(CGRect.null) { $0.union($1) },
                                                   viewportWidth: viewportWidth)
                    HStack {
                        if overflow.leading { overflowEdge(.leading) }
                        Spacer(minLength: 0)
                        if overflow.trailing { overflowEdge(.trailing) }
                    }
                    .frame(width: viewportWidth).allowsHitTesting(false)
                }
                .help(scrolling ? "Scroll to see more widgets. Use the mouse wheel or swipe sideways." : "")
            }
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topLeading) {
                if editing.dragSession.active != nil, let target = editing.insertion,
                   target.displayID == display.id, target.position == position {
                    let bounds = frames.values.reduce(CGRect.null) { $0.union($1) }
                    Rectangle().fill(Color.accentColor).frame(width: 3, height: bounds.isNull ? 22 : bounds.height)
                        .offset(x: target.x, y: bounds.isNull ? 26 : bounds.minY).allowsHitTesting(false)
                }
            }
            .clipped()
            .coordinateSpace(name: "editSection")
            .onPreferenceChange(BarEditFrames.self) { frames = $0 }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(position.title)
    }

    private func overflowEdge(_ edge: HorizontalEdge) -> some View {
        LinearGradient(colors: [.clear, Color(nsColor: .windowBackgroundColor)],
                       startPoint: edge == .leading ? .trailing : .leading, endPoint: edge == .leading ? .leading : .trailing)
            .overlay {
                Image(systemName: edge == .leading ? "chevron.left" : "chevron.right")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            }
            .frame(width: 18)
            .accessibilityHidden(true)
    }
}

private struct BarEditSectionHeader: View {
    let position: WidgetPosition
    let add: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(position.title).font(.caption.weight(.medium)).lineLimit(1).help(position.title)
            Spacer(minLength: 0)
            Button(action: add) { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .help("Add a widget to \(position.title)")
                .accessibilityLabel("Add a widget to \(position.title)")
        }
        .padding(.horizontal, 6)
    }
}

private struct BarEditSectionRow: View {
    let store: BarStore
    let display: Int
    let entries: [BarEditWidget]
    let config: Configuration

    var body: some View {
        HStack(spacing: 3) {
            let units = BarUnit.make(widgets: entries.map(\.widget), groups: config.groups)
            ForEach(units) { unit in
                HStack(spacing: 3) {
                    ForEach(unit.widgets) { widget in
                        if let entry = entries.first(where: { $0.id == widget.id }) {
                            BarEditTile(store: store, display: display, entry: entry, config: config)
                                .background {
                                    GeometryReader { proxy in
                                        Color.clear.preference(key: BarEditFrames.self,
                                            value: [entry.id: proxy.frame(in: .named("editSection"))])
                                    }
                                }
                        }
                    }
                }
                .padding(unit.widgets.count > 1 ? 2 : 0)
                .background(unit.style != nil ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    if unit.style != nil { RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.3)) }
                }
            }
            if entries.isEmpty {
                Text("Drop here").font(.caption).foregroundStyle(.secondary).frame(minHeight: 22)
            }
        }
        .fixedSize()
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }
}

struct BarEditTile: View {
    let store: BarStore
    let display: Int
    let entry: BarEditWidget
    let config: Configuration
    @Environment(\.measuringBarWidths) private var measuring
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
        .overlay(alignment: .topTrailing) {
            Button { editing.remove(entry.id, on: display) } label: {
                Image(systemName: "minus.circle.fill").font(.system(size: 13))
                    .symbolRenderingMode(.palette).foregroundStyle(.primary, .background)
            }
                .buttonStyle(.borderless)
                .help("Remove \(entry.name)")
                .accessibilityLabel("Remove \(entry.name)")
                .offset(x: 4, y: -5)
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
        Button { editing.select(entry.id) } label: {
            Group {
                if entry.usesPlaceholder {
                    Label(entry.name, systemImage: entry.visibility.isHidden ? "eye.slash" : entry.widget.content.symbol)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .padding(.horizontal, 5).frame(minHeight: 22).frame(maxWidth: 120)
                } else {
                    WidgetView(widget: entry.widget, defaults: config.defaults, popupDefaults: config.popupDefaults,
                               store: store, monitor: display, animationDuration: config.bar.animationDuration)
                        .allowsHitTesting(false).accessibilityHidden(true).fixedSize()
                }
            }
            .padding(1)
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Edit \(title)")
    }
}
