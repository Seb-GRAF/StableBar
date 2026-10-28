import AppKit
import SwiftUI

struct MenuBarItemsSettings: View {
    let store: BarStore
    let editor: ConfigurationEditor
    let widget: WidgetConfiguration
    let shown: [MenuBarItemReference]
    let hidden: [MenuBarItemReference]
    @State private var selection: String?
    @State private var target: String?

    var body: some View {
        let items = store.appMenu.menuBarItems
        let bar = cells(shown, items: items, source: MenuBarItemSource.shown)
        let row = items.filter { item in !(shown + hidden).contains { $0.matches(item) } }
            .map { MenuBarItemSettingsCell(item: $0, symbol: nil, source: .item($0)) }
        let hiddenCells = cells(hidden, items: items, source: MenuBarItemSource.hidden)
        let all = bar + row + hiddenCells
        VStack(alignment: .leading, spacing: 14) {
            Text(items.isEmpty ? "Allow StableBar in Privacy & Security → Accessibility to list the items in the menu bar."
                 : "Drag items to choose where they go, or right-click one. Select an item to change it.")
                .font(.caption).foregroundStyle(.secondary)
            tray("On the bar", hint: "Beside the grid symbol, in this order", placement: .bar, cells: bar, all: all) {
                Image(systemName: store.label(for: widget).icon!)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .help("The grid symbol lists the items in the row")
            }
            tray("In the row", hint: "Listed by the grid symbol, in menu bar order", placement: .row, cells: row, all: all) { EmptyView() }
            tray("Hidden", hint: "Left out of the bar and the row", placement: .hidden, cells: hiddenCells, all: all) { EmptyView() }
        }
        .groupRow()
        .task { _ = await store.appMenu.readMenuBarItems(requestingAccess: false) }
        if let cell = all.first(where: { $0.id == selection }) {
            details(cell)
        }
    }

    private func cells(_ references: [MenuBarItemReference], items: [MenuBarItem], source: (Int) -> MenuBarItemSource) -> [MenuBarItemSettingsCell] {
        references.indices.flatMap { index in
            let reference = references[index]
            let matches = items.filter(reference.matches)
            if matches.isEmpty {
                return [MenuBarItemSettingsCell(id: "\(reference.app) \(reference.item ?? "")", title: reference.item ?? reference.app,
                                                app: reference.app, icon: nil, symbol: reference.icon, source: source(index))]
            }
            return matches.map { MenuBarItemSettingsCell(item: $0, symbol: reference.icon, source: source(index)) }
        }
    }

    private func tray(_ title: String, hint: String, placement: MenuBarItemPlacement, cells: [MenuBarItemSettingsCell],
                      all: [MenuBarItemSettingsCell], @ViewBuilder trailing: () -> some View) -> some View {
        let id = trayID(placement)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 28, maximum: 28), spacing: 4)], alignment: .leading, spacing: 4) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                    cellView(cell, all: all)
                }
                trailing()
            }
            .padding(6)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .overlay {
                if cells.isEmpty && placement != .bar {
                    Text("Drag items here").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .background(SettingsPalette.control, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(target == id ? Color.accentColor : .clear, lineWidth: 2))
            .dropDestination(for: String.self) { ids, _ in
                drop(ids, all: all, to: placement, before: placement == .bar ? shown.count : nil)
            } isTargeted: { targeted in
                if targeted { target = id } else if target == id { target = nil }
            }
        }
    }

    private func cellView(_ cell: MenuBarItemSettingsCell, all: [MenuBarItemSettingsCell]) -> some View {
        let icon = Group {
            if let symbol = cell.symbol {
                Image(systemName: symbol).font(.system(size: 14))
            } else if let icon = cell.icon {
                Image(nsImage: icon).resizable().scaledToFit()
            } else {
                Image(systemName: "app.dashed").font(.system(size: 14))
            }
        }
        .frame(width: 22, height: 18)
        .opacity(cell.icon == nil ? 0.5 : 1)
        return icon
            .frame(width: 28, height: 28)
            .background(selection == cell.id ? Color.accentColor.opacity(0.3) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .leading) {
                if target == cell.id { Capsule().fill(Color.accentColor).frame(width: 3).offset(x: -3.5) }
            }
            .contentShape(Rectangle())
            .onTapGesture { selection = cell.id }
            .draggable(cell.id) { icon }
            .dropDestination(for: String.self) { ids, _ in
                if case let .shown(position) = cell.source { return drop(ids, all: all, to: .bar, before: position) }
                return drop(ids, all: all, to: cell.source.placement, before: nil)
            } isTargeted: { targeted in
                let id = cell.source.placement == .bar ? cell.id : trayID(cell.source.placement)
                if targeted { target = id } else if target == id { target = nil }
            }
            .help(cell.icon == nil ? "\(cell.title), not running" : cell.title)
            .contextMenu {
                MenuBarItemCommands(source: cell.source, shownCount: shown.count) { placement, index in
                    move(cell.source, to: placement, before: index)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(cell.title)
            .accessibilityAddTraits(selection == cell.id ? [.isButton, .isSelected] : .isButton)
    }

    private func details(_ cell: MenuBarItemSettingsCell) -> some View {
        Group {
            SettingRow(title: cell.title, hint: cell.icon == nil ? "\(cell.app), not running" : cell.app) {
                SettingsSegments(selection: Binding(get: { cell.source.placement }, set: { move(cell.source, to: $0, before: nil) }),
                                 options: MenuBarItemPlacement.allCases.map { ($0, $0.title) }, stretches: false)
                    .fixedSize()
            }
            if case let .shown(position) = cell.source {
                TextDraft(text: Binding(get: { shown[position].icon ?? "" }, set: { symbol in
                    var next = shown
                    next[position].icon = symbol.isEmpty ? nil : symbol
                    editor.set(["shown": .array(next.map(\.configurationValue))], for: widget.id)
                })) { symbol in
                    SettingRow(title: "Symbol", hint: "An SF Symbol in place of its icon") {
                        TextField("Symbol", text: symbol, prompt: Text("Its own icon")).labelsHidden().frame(width: 160)
                    }
                }
            }
        }
    }

    private func trayID(_ placement: MenuBarItemPlacement) -> String {
        "tray \(placement)"
    }

    private func drop(_ ids: [String], all: [MenuBarItemSettingsCell], to placement: MenuBarItemPlacement, before index: Int?) -> Bool {
        guard let cell = all.first(where: { $0.id == ids.first }) else { return false }
        move(cell.source, to: placement, before: index)
        return true
    }

    private func move(_ source: MenuBarItemSource, to placement: MenuBarItemPlacement, before index: Int?) {
        editor.set(menuBarItemsProperties(shown: shown, hidden: hidden, moving: source, to: placement, before: index,
                                          among: store.appMenu.menuBarItems), for: widget.id)
    }
}

private struct MenuBarItemSettingsCell {
    let id: String
    let title: String
    let app: String
    let icon: NSImage?
    let symbol: String?
    let source: MenuBarItemSource
}

extension MenuBarItemSettingsCell {
    init(item: MenuBarItem, symbol: String?, source: MenuBarItemSource) {
        self.init(id: "\(item.bundleID ?? item.appName) \(item.identifier ?? item.entry.title)", title: item.entry.title,
                  app: item.bundleID ?? item.appName, icon: item.entry.icon, symbol: symbol, source: source)
    }
}
