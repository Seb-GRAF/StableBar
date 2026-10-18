import SwiftUI

struct BarEditView: View {
    let store: BarStore
    let display: BarDisplay
    @State private var setup: WidgetSetup
    @State private var adding = false
    @State private var addPosition = WidgetPosition.right

    init(store: BarStore, display: BarDisplay) {
        self.store = store
        self.display = display
        _setup = State(initialValue: WidgetSetup(store: store))
    }

    var body: some View {
        if let config = store.configuration, let geometry = store.barEditing.geometry(for: display) {
            let entries = store.barEditing.entries(on: display)
            GeometryReader { proxy in
                let widths = Dictionary(uniqueKeysWithValues: WidgetPosition.allCases.map { position in
                    (position, min(360, max(118, CGFloat(entries.filter { $0.widget.position == position }.count) * 156 + 16)))
                })
                let layout = BarEditLayout(width: proxy.size.width, display: display, bar: config.bar, preferredWidths: widths)
                ZStack(alignment: .topLeading) {
                    ForEach(WidgetPosition.allCases, id: \.self) { position in
                        if let section = layout.sections[position] {
                            BarEditSection(store: store, display: display, position: position,
                                           entries: entries.filter { $0.widget.position == position }, config: config) {
                                addPosition = position
                                adding = true
                            }
                            .frame(width: section.width, height: proxy.size.height)
                            .offset(x: section.x)
                        }
                    }
                    Button("Done", action: store.barEditing.end)
                        .accessibilityLabel("Finish editing the bar")
                        .help("Finish editing the bar (Esc)")
                        .frame(width: layout.done.width, height: proxy.size.height)
                        .offset(x: layout.done.x)
                }
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
        }
    }
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
    let add: () -> Void
    @State private var frames: [String: CGRect] = [:]
    private var editing: BarEditing { store.barEditing }

    var body: some View {
        BarEditDropTarget(editing: editing, displayID: display.id, position: position, frames: frames) {
            VStack(spacing: 3) {
                HStack(spacing: 4) {
                    Text(position.title).font(.caption.weight(.medium)).lineLimit(1).help(position.title)
                    Spacer(minLength: 0)
                    Button(action: add) { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("Add a widget to \(position.title)")
                        .accessibilityLabel("Add a widget to \(position.title)")
                }
                .padding(.horizontal, 6)
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        let units = BarUnit.make(widgets: entries.map(\.widget), groups: config.groups)
                        ForEach(units) { unit in
                            HStack(spacing: 3) {
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
                            .padding(unit.widgets.count > 1 ? 2 : 0)
                            .background(unit.widgets.count > 1 ? Color.primary.opacity(0.06) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                        }
                        if entries.isEmpty {
                            Text("Drop here").font(.caption).foregroundStyle(.secondary)
                                .frame(minWidth: 90, minHeight: 42)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.visible)
            }
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topLeading) {
                if editing.dragSession.active != nil, let target = editing.insertion,
                   target.displayID == display.id, target.position == position {
                    Rectangle().fill(Color.accentColor).frame(width: 3, height: 44)
                        .offset(x: target.x, y: 26).allowsHitTesting(false)
                }
            }
            .clipped()
            .coordinateSpace(name: "editSection")
            .onPreferenceChange(BarEditFrames.self) { frames = $0 }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(position.title)
    }
}

private struct BarEditTile: View {
    let store: BarStore
    let display: Int
    let entry: BarEditWidget
    let config: Configuration
    private var editing: BarEditing { store.barEditing }
    private var title: String { entry.name + (entry.visibility.isHidden ? ", Hidden" : "") }

    var body: some View {
        HStack(spacing: 2) {
            BarEditDragSource(editing: editing, widgetID: entry.id, name: entry.name, select: { editing.select(entry.id) }) {
                Button { editing.select(entry.id) } label: {
                    VStack(spacing: 2) {
                        Text(entry.name).font(.caption).lineLimit(1)
                        if entry.usesPlaceholder {
                            Label(entry.visibility.isHidden ? "Hidden" : entry.name,
                                  systemImage: entry.visibility.isHidden ? "eye.slash" : entry.widget.content.symbol)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        } else {
                            WidgetView(widget: entry.widget, defaults: config.defaults, popupDefaults: config.popupDefaults,
                                       store: store, monitor: display, animationDuration: config.bar.animationDuration)
                                .disabled(true).allowsHitTesting(false).accessibilityHidden(true)
                                .frame(maxWidth: 120, maxHeight: 24).clipped()
                        }
                    }
                    .frame(width: 120, height: 42)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit \(title)")
            }
            .frame(width: 120, height: 42)
            .accessibilityAction(named: Text("Move left")) { editing.move(entry.id, by: -1, on: display) }
            .accessibilityAction(named: Text("Move right")) { editing.move(entry.id, by: 1, on: display) }
            Button { editing.remove(entry.id, on: display) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("Remove \(entry.name)")
                .accessibilityLabel("Remove \(entry.name)")
        }
        .padding(.horizontal, 4)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
        .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.secondary.opacity(entry.visibility.isHidden ? 0.6 : 0.2)) }
        .help("\(title). Click to change its settings, or drag to move it.")
        .contextMenu {
            Button("Edit Widget…") { editing.select(entry.id) }
            Button("Move Left") { editing.move(entry.id, by: -1, on: display) }
            Button("Move Right") { editing.move(entry.id, by: 1, on: display) }
            Menu("Move To") {
                ForEach(WidgetPlacement.destinations, id: \.self) { position in
                    Button(position.title.capitalized) { editing.move(entry.id, to: position, on: display) }
                }
            }
            Button("Remove Widget") { editing.remove(entry.id, on: display) }
            Divider()
            Button(editing.menuTitle, action: editing.end)
        }
    }
}
