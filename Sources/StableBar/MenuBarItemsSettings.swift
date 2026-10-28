import AppKit
import SwiftUI

struct MenuBarItemsSettings: View {
    let store: BarStore
    let editor: ConfigurationEditor
    let widget: WidgetConfiguration
    let shown: [MenuBarItemsEntry]
    let hidden: [MenuBarItemsEntry]
    @State private var selection: String?
    @State private var target: String?

    var body: some View {
        let items = store.appMenu.menuBarItems
        let bar = cells(shown, items: items, source: MenuBarItemSource.shown)
        let row = items.filter { item in !(shown + hidden).references.contains { $0.matches(item) } }
            .map { MenuBarItemSettingsCell(item: $0, symbol: nil, source: .item($0)) }
        let hiddenCells = cells(hidden, items: items, source: MenuBarItemSource.hidden)
        let all = bar + row + hiddenCells
        VStack(alignment: .leading, spacing: 14) {
            Text(items.isEmpty ? "Allow StableBar in Privacy & Security → Accessibility to list the items in the menu bar."
                 : "Drag items to choose where they go, or right-click one. Select an item to change it.")
                .font(.caption).foregroundStyle(.secondary)
            tray("On the bar", hint: "In this order", placement: .bar, cells: bar, all: all)
            tray("In the row", hint: "Listed by the grid symbol, in menu bar order", placement: .row, cells: row, all: all)
            tray("Hidden", hint: "Left out of the bar and the row", placement: .hidden, cells: hiddenCells, all: all)
        }
        .groupRow()
        .task { _ = await store.appMenu.readMenuBarItems(requestingAccess: false) }
        if let cell = all.first(where: { $0.id == selection }) {
            details(cell)
        }
    }

    private func cells(_ entries: [MenuBarItemsEntry], items: [MenuBarItem], source: (Int) -> MenuBarItemSource) -> [MenuBarItemSettingsCell] {
        entries.indices.flatMap { index in
            guard case let .item(reference) = entries[index] else {
                return [MenuBarItemSettingsCell(id: "symbol", title: "Grid symbol", app: "Lists the items in the row", icon: nil,
                                                symbol: store.label(for: widget).icon, running: true, isSymbol: true, source: source(index))]
            }
            let matches = items.filter(reference.matches)
            if matches.isEmpty {
                return [MenuBarItemSettingsCell(id: "\(reference.app) \(reference.item ?? "")", title: reference.item ?? reference.app,
                                                app: reference.app, icon: nil, symbol: reference.icon, running: false, isSymbol: false,
                                                source: source(index))]
            }
            return matches.map { MenuBarItemSettingsCell(item: $0, symbol: reference.icon, source: source(index)) }
        }
    }

    private func tray(_ title: String, hint: String, placement: MenuBarItemPlacement, cells: [MenuBarItemSettingsCell],
                      all: [MenuBarItemSettingsCell]) -> some View {
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
            }
            .padding(6)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .overlay {
                if cells.isEmpty {
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
        .opacity(cell.running ? 1 : 0.5)
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
            .help(cell.running ? cell.title : "\(cell.title), not running")
            .contextMenu {
                MenuBarItemCommands(source: cell.source, shownCount: shown.count, isSymbol: cell.isSymbol) { placement, index in
                    move(cell.source, to: placement, before: index)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(cell.title)
            .accessibilityAddTraits(selection == cell.id ? [.isButton, .isSelected] : .isButton)
    }

    private func details(_ cell: MenuBarItemSettingsCell) -> some View {
        Group {
            SettingRow(title: cell.title, hint: cell.running ? cell.app : "\(cell.app), not running") {
                SettingsSegments(selection: Binding(get: { cell.source.placement }, set: { move(cell.source, to: $0, before: nil) }),
                                 options: MenuBarItemPlacement.allCases.filter { !cell.isSymbol || $0 != .row }.map { ($0, $0.title) },
                                 stretches: false)
                    .fixedSize()
            }
            if cell.isSymbol {
                TextDraft(text: Binding(get: { widget.icon ?? "" }, set: {
                    editor.set(["icon": $0.isEmpty ? .null : .string($0)], for: widget.id)
                })) { symbol in
                    SettingRow(title: "Symbol", hint: "Any SF Symbol name") {
                        TextField("Symbol", text: symbol, prompt: Text(widget.content.symbol)).labelsHidden().frame(width: 160)
                    }
                }
            } else if case let .shown(position) = cell.source, case var .item(reference) = shown[position] {
                TextDraft(text: Binding(get: { reference.icon ?? "" }, set: { symbol in
                    var next = shown
                    reference.icon = symbol.isEmpty ? nil : symbol
                    next[position] = .item(reference)
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
        guard let cell = all.first(where: { $0.id == ids.first }), !(cell.isSymbol && placement == .row) else { return false }
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
    let running: Bool
    let isSymbol: Bool
    let source: MenuBarItemSource
}

extension MenuBarItemSettingsCell {
    init(item: MenuBarItem, symbol: String?, source: MenuBarItemSource) {
        self.init(id: "\(item.bundleID ?? item.appName) \(item.identifier ?? item.entry.title)", title: item.entry.title,
                  app: item.bundleID ?? item.appName, icon: item.entry.icon, symbol: symbol, running: true, isSymbol: false, source: source)
    }
}
